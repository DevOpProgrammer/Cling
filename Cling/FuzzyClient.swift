import ClopSDK
import Cocoa
import Combine
import Foundation
import FullDiskAccess
import Ignore
import Lowtech
import SwiftTerm
import System

let FD_BINARY = Bundle.main.url(forResource: "fd", withExtension: nil)!.existingFilePath!
let FZF_BINARY = Bundle.main.url(forResource: "fzf", withExtension: nil)!.existingFilePath!
let FS_IGNORE = Bundle.main.url(forResource: "fsignore", withExtension: nil)!.existingFilePath!
let FS_IGNORE_RECENTS = Bundle.main.url(forResource: "fsignore-recents", withExtension: nil)!.existingFilePath!

let FZF_API_KEY = UUID().uuidString

let fsignore: FilePath = HOME / ".fsignore"
let fsignoreString = (HOME / ".fsignore").string
let fsignoreRecents: FilePath = HOME / ".fsignore-recents"
let fsignoreRecentsString = (HOME / ".fsignore-recents").string

let indexFolder: FilePath =
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Cling", isDirectory: true).filePath ?? "/tmp/cling-\(NSUserName())".filePath!
let homeIndex: FilePath = indexFolder / "home.index"
let libraryIndex: FilePath = indexFolder / "library.index"
let rootIndex: FilePath = indexFolder / "root.index"
let storedIndex: FilePath = indexFolder / "stored.index"
let liveIndex: FilePath = indexFolder / "live.index"

let PIDFILE = "/tmp/cling-\(NSUserName().safeFilename).pid".filePath!
let HARD_IGNORED: Set<String> = [
    PIDFILE.string,
    homeIndex.string,
    libraryIndex.string,
    rootIndex.string,
    storedIndex.string,
    liveIndex.string,
]

enum SortField: String, CaseIterable, Identifiable {
    case score
    case name
    case path
    case size
    case date

    var id: String { rawValue }
    var key: Character {
        switch self {
        case .score: "s"
        case .name: "n"
        case .path: "p"
        case .size: "z"
        case .date: "d"
        }
    }
}

@Observable @MainActor
class FuzzyClient {
    var clopIsAvailable = false
    var terminal: FZFTerminal!
    var removedFiles: Set<String> = []
    var results: [FilePath] = []
    var seenPaths: Set<String> = []
    var childHandle: FileHandle?
    var indexProcesses: [Process] = []
    var operation = " "
    var scoredResults: [FilePath] = []
    var recents: [FilePath] = []
    var commonOpenWithApps: [URL] = []
    var openWithAppShortcuts: [URL: Character] = [:]
    var folderFilter: FolderFilter?
    var quickFilter: QuickFilter?

    var noQuery = true

    var backgroundIndexing = false

    var sortField: SortField = .score {
        didSet {
            guard sortField != oldValue else {
                return
            }
            results = sortedResults()
        }
    }
    var reverseSort = true {
        didSet {
            guard reverseSort != oldValue else {
                return
            }
            results = sortedResults()
        }
    }
    var query = "" {
        didSet {
            sendQuery(query)
        }
    }
    var indexing = false {
        didSet {
            if !indexing {
                operation = " "
            } else {
                operation = "Indexing files"
            }
        }
    }

    @ObservationIgnored var lastQuerySendTask: DispatchWorkItem? { didSet { oldValue?.cancel() } }
    @ObservationIgnored var querySendTask: DispatchWorkItem? { didSet {
        lastQuerySendTask?.cancel()
        lastQuerySendTask = nil
        oldValue?.cancel()
    } }
    @ObservationIgnored var indexConsolidationTask: DispatchWorkItem? {
        didSet {
            oldValue?.cancel()
        }
    }

    var serverProcess: LocalProcess? { terminal.running ? terminal.process : nil }
    var indexExists: Bool { searchScopeIndexes.contains(where: \.exists) }
    var indexIsStale: Bool {
        searchScopeIndexes.contains {
            !$0.exists
                || ($0.timestamp ?? 0) < Date().addingTimeInterval(-3600 * 72).timeIntervalSince1970
        }
    }

    @ObservationIgnored var computeOpenWithTask: DispatchWorkItem? {
        didSet { oldValue?.cancel() }
    }

    var suspended = false {
        didSet {
            guard oldValue != suspended, terminal.running else {
                return
            }
            kill(-terminal.process.shellPid, suspended ? SIGSTOP : SIGCONT)
        }
    }

    @ObservationIgnored var searchScopeIndexes: [FilePath] {
        [
            Defaults[.searchScopes].contains(.home) ? homeIndex : nil,
            Defaults[.searchScopes].contains(.library) ? libraryIndex : nil,
            Defaults[.searchScopes].contains(.root) ? rootIndex : nil,
        ].compactMap { $0 }
    }

    static func forceStopFZF() {
        _ = shell("/usr/bin/pkill", args: ["-KILL", "-f", "Cling.app/Contents/Resources/fzf"], wait: true)
    }

    // Methods
    func start() {
        asyncNow {
            let clopIsAvailable = ClopSDK.shared.waitForClopToBeAvailable()
            mainActor { self.clopIsAvailable = clopIsAvailable }
        }

        FullDiskAccess.promptIfNotGranted(
            title: "Enable Full Disk Access for Cling",
            message: "Cling requires Full Disk Access to index the files on the whole disk.",
            settingsButtonTitle: "Open Settings",
            skipButtonTitle: "Quit",
            canBeSuppressed: false,
            icon: nil
        )
        FUZZY_SERVER.start()
        Self.forceStopFZF()

        terminal = FZFTerminal { exitCode in
            log.debug("Terminal exited with code: \(exitCode ?? 0)")
            guard exitCode != SIGTERM, exitCode != SIGKILL else {
                return
            }
            guard exitCode != 512 else {
                Self.forceStopFZF()
                return
            }
            self.startServer()
        }

        pub(.maxResultsCount)
            .debounce(for: 0.5, scheduler: RunLoop.main)
            .sink { [self] count in
                fetchResults()
                if let recentsQuery {
                    stopRecentsQuery(recentsQuery)
                    self.recentsQuery = queryRecents()
                }
            }.store(in: &observers)
        pub(.searchScopes)
            .debounce(for: 2.0, scheduler: RunLoop.main)
            .sink { [self] _ in
                restartServer()
            }.store(in: &observers)

        indexFolder.mkdir(withIntermediateDirectories: true, permissions: 0o700)
        if FullDiskAccess.isGranted {
            startIndex()
        } else {
            fullDiskAccessChecker = Repeater(every: 1) {
                guard FullDiskAccess.isGranted else { return }
                self.fullDiskAccessChecker = nil
                self.startIndex()
            }
        }
    }

    func writeFSIgnoreRecents() {
        do {
            let fsignoreContent = try String(contentsOf: FS_IGNORE.url)
            let fsignoreRecentsContent = try String(contentsOf: FS_IGNORE_RECENTS.url)
            let combinedContent = fsignoreContent + "\n" + fsignoreRecentsContent
            try combinedContent.write(to: fsignoreRecents.url, atomically: true, encoding: .utf8)
        } catch {
            log.error("Failed to concatenate ignore files: \(error)")
        }
    }

    func startIndex() {
        if !fsignoreRecents.exists {
            writeFSIgnoreRecents()
        }
        if !fsignore.exists {
            do {
                try FS_IGNORE.copy(to: fsignore)
            } catch {
                log.error("Failed to copy \(FS_IGNORE.string) to \(fsignore.string): \(error)")
            }
        }

        if indexIsStale {
            let earliestModificationDate = searchScopeIndexes
                .compactMap(\.modificationDate)
                .min()
            if indexExists {
                startServer()
            }
            indexFiles(changedWithin: earliestModificationDate, pauseSearch: !indexExists) { [self] in
                watchFiles()
                restartServer()
            }
        } else {
            consolidateLiveIndex()
            watchFiles()
            startServer()
        }

        indexChecker = Repeater(every: 60 * 60, name: "Index Checker", tolerance: 60 * 60) { [self] in
            refresh(fullReindex: false, pauseSearch: false)
        }
    }

    func refresh(fullReindex: Bool = false, pauseSearch: Bool = true) {
        guard !indexing, FullDiskAccess.isGranted else {
            return
        }

        if pauseSearch {
            indexing = true
            operation = fullReindex ? "Reindexing all files" : "Reindexing changed files"
            fetchTask?.cancel()
            queryTask?.cancel()
        }

        let earliestModificationDate = fullReindex ? nil : searchScopeIndexes.compactMap(\.modificationDate).min()

        stopWatchingFiles()
        indexFiles(changedWithin: earliestModificationDate, pauseSearch: pauseSearch) { [self] in
            if !fullReindex {
                consolidateLiveIndex()
            }
            watchFiles()
            stopServer()
            startServer()
        }
    }

    func consolidateStoredIndex() {
        indexConsolidationTask = asyncNow {
            guard storedIndex.exists, let string = try? String(contentsOf: storedIndex.url) else {
                return
            }

            let paths = string.components(separatedBy: .newlines).filter { !$0.isEmpty }
            let uniquePaths = (NSOrderedSet(array: paths).array as! [String]).filter {
                FileManager.default.fileExists(atPath: $0)
            }
            FileManager.default.createFile(atPath: storedIndex.string, contents: uniquePaths.joined(separator: "\n").data(using: .utf8), attributes: nil)
        }
    }

    func consolidateLiveIndex() {
        guard liveIndex.exists else {
            return
        }

        do {
            if !storedIndex.exists {
                try liveIndex.copy(to: storedIndex)
            } else {
                let live = try String(contentsOf: liveIndex.url)
                let file = try FileHandle(forUpdating: storedIndex.url)
                file.seekToEndOfFile()
                file.write(live.data(using: .utf8)!)
                try file.close()
            }
        } catch {
            log.error("Failed to consolidate live index: \(error)")
        }
        consolidateStoredIndex()
    }

    func stopWatchingFiles() {
        LowtechFSEvents.stopWatching(for: ObjectIdentifier(self))
    }

    func watchFiles() {
        removedFiles.removeAll()
        seenPaths.removeAll()
        LowtechFSEvents.stopWatching(for: ObjectIdentifier(self))
        do {
            try liveIndex.delete()
        } catch {
            log.error("Failed to delete live index file: \(error)")
        }

        if !liveIndex.exists {
            FileManager.default.createFile(atPath: liveIndex.string, contents: nil, attributes: nil)
        }
        guard let liveIndexFile = FileHandle(forUpdatingAtPath: liveIndex.string) else {
            log.error("Failed to open live index file: \(liveIndex.string)")
            return
        }
        liveIndexFile.seekToEndOfFile()

        do {
            try LowtechFSEvents.startWatching(
                paths: ["/Users", "/usr/local", "/opt", "/Applications", "/tmp"],
                for: ObjectIdentifier(self), latency: 1
            ) { event in
                mainActor { [self] in
                    guard let flags = event.flag,
                          flags.hasElements(from: [
                              .itemCreated, .itemRemoved, .itemRenamed, .itemModified,
                          ]), !seenPaths.contains(event.path),
                          let path = event.path.filePath
                    else {
                        return
                    }

                    if path.starts(with: HOME), event.path.isIgnored(in: fsignoreString) {
                        return
                    }

                    if path.exists, let data = "\(path.string)\n".data(using: .utf8) {
                        seenPaths.insert(path.string)
                        liveIndexFile.write(data)
                    } else {
                        removedFiles.insert(path.string)
                        if let index = scoredResults.firstIndex(of: path) {
                            scoredResults.remove(at: index)
                            results = sortedResults()
                        }
                    }
                }
            }
        } catch {
            log.error("Failed to watch files: \(error)")
        }
    }

    func stopIndexers() {
        for process in indexProcesses {
            kill(process.processIdentifier, SIGKILL)
        }
        indexProcesses.removeAll()
    }

    func indexFiles(wait: Bool = false, changedWithin: Date? = nil, pauseSearch: Bool = true, onFinish: (@MainActor () -> Void)? = nil) {
        backgroundIndexing = true
        if pauseSearch {
            indexing = true
        }
        stopIndexers()

        let fdThreads = max(1, ProcessInfo.processInfo.activeProcessorCount / 3)
        log.debug("Indexing files with \(fdThreads) threads")

        // let changedWithinArg = changedWithin.map { ["--changed-within", "@\($0.timeIntervalSince1970.intround)"] } ?? []
//        let commonArgs = ["-uu", "-j", "\(fdThreads)", "--one-file-system"] + changedWithinArg + ["--ignore-file", "\(HOME.string)/.fsignore"]
        let commonArgs = ["-uu", "-j", "\(fdThreads)", "--one-file-system"] + ["--ignore-file", "\(HOME.string)/.fsignore"]
        let commands = [
            Defaults[.searchScopes].contains(.home)
                ? (
                    arguments: commonArgs + [
                        "--exclude", "\(HOME.string)/Library/*", ".", HOME.string,
                    ].filter(!\.isEmpty), output: homeIndex
                )
                : nil,
            Defaults[.searchScopes].contains(.library) ? (
                arguments: commonArgs + [
                    ".", "\(HOME.string)/Library",
                ].filter(!\.isEmpty), output: libraryIndex
            ) : nil,
            Defaults[.searchScopes].contains(.root) ? (
                arguments: commonArgs + [
                    "--exclude", "\(HOME.string)/*", ".", "/",
                ].filter(!\.isEmpty), output: rootIndex
            ) : nil,
        ].compactMap { $0 }

        guard !commands.isEmpty else {
            log.debug("No folders to index")
            onFinish?()
            indexing = false
            return
        }

        let group = DispatchGroup()
        for command in commands {
            let tempFile = FilePath.dir("/tmp/cling") / "\(UUID().uuidString).index"
            FileManager.default.createFile(atPath: tempFile.string, contents: nil, attributes: [FileAttributeKey.posixPermissions: 0o600])
            guard let file = try? FileHandle(forWritingTo: tempFile.url) else {
                log.error("Failed to open temp file \(tempFile.string)")
                continue
            }

            group.enter()
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = FD_BINARY.url
                process.arguments = command.arguments
                process.standardOutput = file
                do {
                    try process.run()
                    mainActor { self.indexProcesses.append(process) }

                    process.waitUntilExit()
                    file.closeFile()

                    _ = try? tempFile.move(to: command.output, force: true)
                } catch {
                    log.error("Failed to run process: \(error)")
                }
                group.leave()

                let folder = command.output.stem!.capitalized
                mainActor { self.operation = "Indexed \(folder) folder" }
                log.debug("Indexed \(folder)")
            }
        }
        if wait {
            group.wait()
            onFinish?()
            indexing = false
            backgroundIndexing = false
        } else if let onFinish {
            let block = {
                onFinish()
                self.indexing = false
                self.backgroundIndexing = false
            }
            group.notify(queue: .main, work: DispatchWorkItem(block: block))
        }
    }

    func startServer() {
        let indexFiles = (searchScopeIndexes + [storedIndex])
            .filter(\.exists)
            .map { "\"\($0.string)\"" }
            .joined(separator: " ")
        let command =
            "{ /bin/cat \(indexFiles) ; tail -f \"\(liveIndex.string)\" } | \(FZF_BINARY) --height=20 --border=none --no-info --no-hscroll --no-unicode --no-mouse --no-separator --no-scrollbar --no-color --no-bold --no-clear --scheme=path --bind 'result:execute-silent(echo -n '' | nc -w 1 localhost \(SERVER_PORT))' --listen=localhost:7272"
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color") + [
            "FZF_API_KEY=\(FZF_API_KEY)",
            "FZF_COLUMNS=80",
            "FZF_LINES=20",
        ]

        terminal.process.startProcess(executable: "/bin/zsh", args: ["-c", command], environment: env)
        guard terminal.running else {
            log.error("Failed to start fzf server")
            return
        }

        log.debug("FZF server started with PID: \(terminal.process.shellPid)")
        FileManager.default.createFile(atPath: PIDFILE.string, contents: terminal.process.shellPid.s.data(using: .utf8), attributes: nil)
    }

    func stopServer() {
        kill(-terminal.process.shellPid, SIGKILL)
        Self.forceStopFZF()

        for _ in 0 ..< Int(100) {
            if kill(terminal.process.shellPid, 0) == 0 {
                usleep(10000)
            } else {
                break
            }
        }
    }

    func restartServer() {
        stopServer()
        startServer()
    }

    func cleanup() {
        LowtechFSEvents.stopWatching(for: ObjectIdentifier(self))
        stopServer()
        stopIndexers()
    }

    func computeOpenWithApps(for urls: [URL]) {
        computeOpenWithTask = mainAsyncAfter(ms: 100) { [self] in
            commonOpenWithApps = commonApplications(for: urls).sorted(by: \.lastPathComponent)
            openWithAppShortcuts = computeShortcuts(for: commonOpenWithApps)
        }
    }

    func fetchResults() {
        fetchTask?.cancel()
        guard !indexing else {
            log.debug("Indexing files, skipping fetch")
            return
        }

        var request = URLRequest(url: FZF_URL)
        request.addValue(FZF_API_KEY, forHTTPHeaderField: "x-api-key")

        fetchTask = URLSession.shared.dataTask(with: request) { [self] data, response, error in
            if let error {
                log.error("Request error: \(error)")
                return
            }

            guard let data else {
                log.error("No data received")
                return
            }

            do {
                let response = try JSONDecoder().decode(FzfResponse.self, from: data)
                mainActor {
                    let results = NSMutableOrderedSet(array: response.matches.prefix(Defaults[.maxResultsCount]).map(\.text))

                    results.minusSet(HARD_IGNORED)
                    if !self.removedFiles.isEmpty {
                        results.minusSet(self.removedFiles)
                    }
                    self.scoredResults = (results.array as! [String]).compactMap(\.filePath).filter(\.exists)
                    self.results = self.sortedResults()
                    if !self.query.isEmpty || self.folderFilter != nil || self.quickFilter != nil {
                        self.noQuery = false
                    }
                }
            } catch {
                log.error("JSON decode error: \(error)")
            }
        }
        fetchTask!.resume()
    }
    func sortedResults() -> [FilePath] {
        guard sortField != .score else {
            return scoredResults
        }
        return scoredResults.sorted { a, b in
            switch sortField {
            case .name:
                return reverseSort ? (a.name.string > b.name.string) : (a.name.string < b.name.string)
            case .path:
                return reverseSort ? (a.dir.string > b.dir.string) : (a.dir.string < b.dir.string)
            case .size:
                let aSize = a.fileSize() ?? 0
                let bSize = b.fileSize() ?? 0
                return reverseSort ? (aSize > bSize) : (aSize < bSize)
            case .date:
                let aDate = a.modificationDate ?? .distantPast
                let bDate = b.modificationDate ?? .distantPast
                return reverseSort ? (aDate > bDate) : (aDate < bDate)
            default:
                return true
            }
        }

    }

    func sendQuery(_ query: String) {
        queryTask?.cancel()
        if query.isEmpty, folderFilter == nil, quickFilter == nil {
            noQuery = true
            scoredResults = []
            results = []
            return
        }

        guard !indexing else {
            return
        }

        var query = query
        if let filter = folderFilter {
            let folders = filter.folders.map { "^\($0.string)" }.joined(separator: " | ")
            query = "\(folders) \(query)"
        }
        if let quickFilter {
            query = "\(quickFilter.query) \(query)"
        }
        if query.contains("~/") {
            query = query.replacingOccurrences(of: "~/", with: "\(HOME.string)/")
        }

        var request = URLRequest(url: FZF_URL)
        request.httpMethod = "POST"
        request.addValue(FZF_API_KEY, forHTTPHeaderField: "x-api-key")
        request.httpBody = "change-query:\(query)".data(using: .utf8)

        queryTask = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error as NSError?, error.code == 24 {
                mainActor {
                    self.restartServer()
                }
            }

            if let error {
                log.error("Request error: \(error)")
                mainActor { [self] in
                    if !terminal.running {
                        stopServer()
                        startServer()
                    }
                }
                return
            }

            log.debug("Sent query \(query)")
        }
        queryTask!.resume()
    }

    @ObservationIgnored private var observers: Set<AnyCancellable> = []

    // Ignored properties
    @ObservationIgnored private var queryTask: URLSessionTask?
    @ObservationIgnored private var fetchTask: URLSessionTask?
    @ObservationIgnored private var recentsQuery: MDQuery? = queryRecents()
    @ObservationIgnored private var fullDiskAccessChecker: Repeater?
    @ObservationIgnored private var indexChecker: Repeater?

}

struct Match: Decodable, Hashable {
    let text: String

    static func == (lhs: Match, rhs: Match) -> Bool {
        lhs.text == rhs.text
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(text)
    }

}

func computeShortcuts(for urls: [URL]) -> [URL: Character] {
    var usedShortcuts = Set<Character>()
    var shortcuts = [URL: Character]()

    for url in urls {
        let name = url.lastPathComponent.ns.deletingPathExtension
        var shortcut: Character?
        for char in name.lowercased() {
            if !usedShortcuts.contains(char) {
                shortcut = char
                break
            }
        }
        if shortcut == nil {
            for i in 1 ... 9 {
                let candidate = i.s.first!
                if !usedShortcuts.contains(candidate) {
                    shortcut = candidate
                    break
                }
            }
        }
        if let shortcut {
            usedShortcuts.insert(shortcut)
            shortcuts[url] = shortcut
        }
    }
    return shortcuts
}

import Defaults

func commonApplications(for urls: [URL]) -> [URL] {
    let appSets = urls.map { Set(NSWorkspace.shared.urlsForApplications(toOpen: $0)) }
    guard let first = appSets.first else {
        return []
    }

    var commonApps = appSets.dropFirst().reduce(first) { $0.intersection($1) }
    if let terminal = Defaults[.terminalApp].fileURL, let editor = Defaults[.editorApp].fileURL {
        commonApps = commonApps.filter { $0 != terminal && $0 != editor }
    }
    let commonAppsDict: [String: [URL]] = commonApps.group(by: \.bundleIdentifier)
    let uniqueAppsByShortestPath = commonAppsDict.values.compactMap { $0.min(by: \.path.count) }
    return uniqueAppsByShortestPath
}

struct FzfResponse: Decodable { let matches: [Match] }

let FZF_URL = URL(string: "http://127.0.0.1:7272")!

@MainActor let FUZZY = FuzzyClient()
