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
        .appendingPathComponent("StaticCling", isDirectory: true).filePath ?? "/tmp/cling-\(NSUserName())".filePath!
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
    var commonOpenWithApps: [URL] = []
    var openWithAppShortcuts: [URL: Character] = [:]
    // Ignored properties
    @ObservationIgnored var queryTask: URLSessionTask?
    @ObservationIgnored var fetchTask: URLSessionTask?

    var fullDiskAccessChecker: Repeater?

    @ObservationIgnored var indexChecker: Repeater?

    var folderFilter: FolderFilter?

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
    var indexIsStale: Bool {
        let indexFiles = [homeIndex, libraryIndex, rootIndex]
        return indexFiles.contains {
            !$0.exists
                || ($0.timestamp ?? 0) < Date().addingTimeInterval(-3600).timeIntervalSince1970
        }
    }

    @ObservationIgnored var computeOpenWithTask: DispatchWorkItem? {
        didSet { oldValue?.cancel() }
    }

    // Methods
    func start() {
        asyncNow {
            let clopIsAvailable = ClopSDK.shared.waitForClopToBeAvailable()
            mainActor { self.clopIsAvailable = clopIsAvailable }
        }

        FullDiskAccess.promptIfNotGranted(
            title: "Enable Full Disk Access for StaticCling",
            message: "StaticCling requires Full Disk Access to index the files on the whole disk.",
            settingsButtonTitle: "Open Settings",
            skipButtonTitle: "Quit",
            canBeSuppressed: false,
            icon: nil
        )
        FUZZY_SERVER.start()

        terminal = FZFTerminal { exitCode in
            log.debug("Terminal exited with code: \(exitCode ?? 0)")
            guard exitCode != SIGTERM, exitCode != SIGKILL else {
                return
            }
            self.startServer()
        }

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
            let earliestModificationDate = [homeIndex, libraryIndex, rootIndex]
                .compactMap(\.modificationDate)
                .min()
            indexFiles(changedWithin: earliestModificationDate) { [self] in
                watchFiles()
                startServer()
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

        let earliestModificationDate = fullReindex ? nil : [homeIndex, libraryIndex, rootIndex]
            .compactMap(\.modificationDate)
            .min()

        stopWatchingFiles()
        indexFiles(changedWithin: earliestModificationDate) { [self] in
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

    func indexFiles(wait: Bool = false, changedWithin: Date? = nil, onFinish: (@MainActor () -> Void)? = nil) {
        indexing = true
        stopIndexers()

        let fdThreads = max(1, ProcessInfo.processInfo.activeProcessorCount / 3)
        log.debug("Indexing files with \(fdThreads) threads")

        let changedWithinArg = changedWithin.map { ["--changed-within", "@\($0.timeIntervalSince1970.intround)"] } ?? []
        let commonArgs = ["-uu", "-j", "\(fdThreads)", "--one-file-system"] + changedWithinArg + ["--ignore-file", "\(HOME.string)/.fsignore"]
        let commands = [
            (
                arguments: commonArgs + [
                    "--exclude", "\(HOME.string)/Library/*", ".", HOME.string,
                ].filter(!\.isEmpty), output: homeIndex
            ),
            (
                arguments: commonArgs + [
                    ".", "\(HOME.string)/Library",
                ].filter(!\.isEmpty), output: libraryIndex
            ),
            (
                arguments: commonArgs + [
                    "--exclude", "\(HOME.string)/*", ".", "/",
                ].filter(!\.isEmpty), output: rootIndex
            ),
        ]

        let group = DispatchGroup()
        for command in commands {
            let file: FileHandle
            if changedWithin == nil || !command.output.exists {
                FileManager.default.createFile(atPath: command.output.string, contents: nil, attributes: nil)
                do {
                    file = try FileHandle(forWritingTo: command.output.url)
                } catch {
                    log.error("Failed to open file \(command.output.string): \(error)")
                    continue
                }
            } else {
                do {
                    file = try FileHandle(forUpdating: command.output.url)
                    try file.seekToEnd()
                } catch {
                    log.error("Failed to open file \(command.output.string): \(error)")
                    continue
                }
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

                    // Remove trailing slashes
//                    shellProcDevNull("/usr/bin/sed", args: ["-i", "", "s|/$||g", command.output.string])?.waitUntilExit()
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
        } else if let onFinish {
            let block = {
                onFinish()
                self.indexing = false
            }
            group.notify(queue: .main, work: DispatchWorkItem(block: block))
        }
    }

    func startServer() {
        let indexFiles = [homeIndex, libraryIndex, rootIndex, storedIndex]
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
        mainAsyncAfter(1.0) { self.fetchResults() }
    }

    func stopServer() {
        guard let serverProcess else {
            return
        }

        serverProcess.terminate()

        for _ in 0 ..< Int(100) {
            if kill(serverProcess.shellPid, 0) == 0 {
                usleep(10000)
            } else {
                break
            }
        }

        if kill(serverProcess.shellPid, 0) == 0 {
            kill(serverProcess.shellPid, SIGKILL)
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
                    let results = NSMutableOrderedSet(array: response.matches.prefix(30).map(\.text))

                    results.minusSet(HARD_IGNORED)
                    if !self.removedFiles.isEmpty {
                        results.minusSet(self.removedFiles)
                    }
                    self.scoredResults = (results.array as! [String]).compactMap(\.filePath).filter(\.exists)
                    self.results = self.sortedResults()
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
        guard !indexing else {
            return
        }

        var query = query
        if let filter = folderFilter {
            let folders = filter.folders.map { "^\($0.string)" }.joined(separator: " | ")
            query = "\(folders) \(query)"
        }
        if query.contains("~/") {
            query = query.replacingOccurrences(of: "~/", with: "\(HOME.string)/")
        }

        var request = URLRequest(url: FZF_URL)
        request.httpMethod = "POST"
        request.addValue(FZF_API_KEY, forHTTPHeaderField: "x-api-key")
        request.httpBody = "change-query:\(query)".data(using: .utf8)

        queryTask = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                log.error("Request error: \(error)")
                mainActor { [self] in
                    if !terminal.running {
                        startServer()
                    }
                }
                return
            }

            log.debug("Sent query \(query)")
        }
        queryTask!.resume()
    }

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

func commonApplications(for urls: [URL]) -> [URL] {
    let appSets = urls.map { Set(NSWorkspace.shared.urlsForApplications(toOpen: $0)) }
    guard let first = appSets.first else {
        return []
    }

    let commonApps = appSets.dropFirst().reduce(first) { $0.intersection($1) }
    let commonAppsDict: [String: [URL]] = commonApps.group(by: \.bundleIdentifier)
    let uniqueAppsByShortestPath = commonAppsDict.values.compactMap { $0.min(by: \.path.count) }
    return uniqueAppsByShortestPath
}

struct FzfResponse: Decodable { let matches: [Match] }

let FZF_URL = URL(string: "http://127.0.0.1:7272")!

@MainActor let FUZZY = FuzzyClient()
