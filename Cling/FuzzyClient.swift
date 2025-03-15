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
let RG_BINARY = Bundle.main.url(forResource: "rg", withExtension: nil)!.existingFilePath!

let FS_IGNORE = Bundle.main.url(forResource: "fsignore", withExtension: nil)!.existingFilePath!
let FS_IGNORE_RECENTS = Bundle.main.url(forResource: "fsignore-recents", withExtension: nil)!.existingFilePath!

let FZF_API_KEY = UUID().uuidString
let FZF_SERVER_PORT = 27272

let fsignore: FilePath = HOME / ".fsignore"
let fsignoreString = (HOME / ".fsignore").string
let fsignoreRecents: FilePath = HOME / ".fsignore-recents"
let fsignoreRecentsString = (HOME / ".fsignore-recents").string

let indexFolder: FilePath =
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("com.lowtechguys.Cling", isDirectory: true).filePath ?? "/tmp/cling-\(NSUserName())".filePath!
let homeIndex: FilePath = indexFolder / "home.index"
let libraryIndex: FilePath = indexFolder / "library.index"
let rootIndex: FilePath = indexFolder / "root.index"
let liveIndex: FilePath = indexFolder / "live.index"

let PIDFILE = "/tmp/cling-\(NSUserName().safeFilename).pid".filePath!
let HARD_IGNORED: Set<String> = [
    PIDFILE.string,
    homeIndex.string,
    libraryIndex.string,
    rootIndex.string,
    liveIndex.string,
]

let FAST_SHELL = [
    "/bin/dash", "/bin/sh", "/bin/zsh", "/bin/bash",
].first { $0.filePath?.exists ?? false } ?? "/bin/sh"

enum SortField: String, CaseIterable, Identifiable {
    case score
    case name
    case path
    case size
    case date
    case kind

    var id: String { rawValue }
}

@Observable @MainActor
class FuzzyClient {
    static let UNESCAPED_SHELL_CHARS = /([^\\])?(['${>&*#;?<`])/
    static let initialVolumes = getVolumes()

    static let RG_COMMAND = "'\(RG_BINARY.string)' --color=never --no-line-number --no-filename --mmap"

    @ObservationIgnored var terminal: FZFTerminal!
    @ObservationIgnored var childHandle: FileHandle?
    @ObservationIgnored var indexProcesses: [Process] = []

    var clopIsAvailable = false
    var removedFiles: Set<String> = []
    var results: [FilePath] = []
    var seenPaths: Set<String> = []
    var operation = " "
    var scoredResults: [FilePath] = []
    var recents: [FilePath] = []
    var sortedRecents: [FilePath] = []
    var commonOpenWithApps: [URL] = []
    var openWithAppShortcuts: [URL: Character] = [:]
    var noQuery = true
    var backgroundIndexing = false
    var hasFullDiskAccess: Bool = FullDiskAccess.isGranted

    @ObservationIgnored @Setting(.fasterSearchLessOptimalResults) var fasterSearchLessOptimalResults: Bool

    var disabledVolumes: [FilePath] = Defaults[.disabledVolumes]
    var enabledVolumes: [FilePath] = initialVolumes.filter { !Defaults[.disabledVolumes].contains($0) }
    var externalIndexes: [FilePath] = initialVolumes
        .filter { !Defaults[.disabledVolumes].contains($0) }
        .map { volume in
            indexFolder / "\(volume.name.string.replacingOccurrences(of: " ", with: "-")).index"
        }

    var readOnlyVolumes: [FilePath] = initialVolumes.filter(\.url.volumeIsReadOnly)
    var quickFilter: QuickFilter?

    var externalVolumes: [FilePath] = initialVolumes { didSet {
        enabledVolumes = externalVolumes.filter { !disabledVolumes.contains($0) }
        readOnlyVolumes = externalVolumes.filter(\.url.volumeIsReadOnly)
        externalIndexes = getExternalIndexes()

        indexStaleExternalVolumes()
    }}

    var volumeFilter: FilePath? {
        didSet {
            guard volumeFilter != oldValue else {
                return
            }
            restartServer()
        }
    }
    var folderFilter: FolderFilter? {
        didSet {
            guard folderFilter != oldValue, let folderFilter else {
                return
            }
            if let volumeFilter, !folderFilter.folders.allSatisfy({ $0.starts(with: volumeFilter) }) {
                self.volumeFilter = nil
            }
            restartServer()
        }
    }

    var sortField: SortField = .score {
        didSet {
            guard sortField != oldValue else {
                return
            }
            results = sortedResults()
            sortedRecents = sortedResults(results: recents)
        }
    }
    var reverseSort = true {
        didSet {
            guard reverseSort != oldValue else {
                return
            }
            results = sortedResults()
            sortedRecents = sortedResults(results: recents)
        }
    }

    var query = "" {
        didSet {
            if fasterSearchLessOptimalResults {
                sendQuery(query)
            } else {
                querySendTask = mainAsyncAfter(ms: 70) { [self] in
                    sendQuery(query)
                }
            }
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
        ].compactMap { $0 } + externalIndexes
    }

    @ObservationIgnored var limitedSearchScopeIndexes: [FilePath]? {
        if let volumeFilter, !volumeFilter.url.isRootVolume {
            let index = indexFolder / "\(volumeFilter.name.string).index"
            if index.exists {
                return [index]
            }
        }

        if let folderFilter {
            let library = HOME / "Library"
            if folderFilter.folders.allSatisfy({ $0.starts(with: library) && !$0.isOnExternalVolume }) {
                return [libraryIndex]
            } else if folderFilter.folders.allSatisfy({ $0.starts(with: HOME) && !$0.isOnExternalVolume }) {
                return [homeIndex]
            } else if folderFilter.folders.allSatisfy({ !$0.starts(with: HOME) && !$0.isOnExternalVolume }) {
                return [rootIndex]
            } else if let volumeFilter = enabledVolumes.first(where: { v in folderFilter.folders.allSatisfy { $0.starts(with: v) } }) {
                return [indexFolder / "\(volumeFilter.name.string.replacingOccurrences(of: " ", with: "-")).index"]
            }
        } else if let volumeFilter, volumeFilter.url.isRootVolume {
            let indexes = [
                Defaults[.searchScopes].contains(.home) ? homeIndex : nil,
                Defaults[.searchScopes].contains(.library) ? libraryIndex : nil,
                Defaults[.searchScopes].contains(.root) ? rootIndex : nil,
            ].compactMap { $0 }
            return indexes.isEmpty ? nil : indexes
        }

        return nil
    }

    @ObservationIgnored var emptyQuery: Bool { query.isEmpty && folderFilter == nil && quickFilter == nil }

    static func forceStopFZF() {
        log.debug("Force stopping FZF server")
        _ = shell("/usr/bin/pkill", args: ["-KILL", "-f", "Cling.app/Contents/Resources/fzf"], wait: true)
    }

    // Methods
    func start() {
        asyncNow {
            let clopIsAvailable = ClopSDK.shared.getClopAppURL() != nil
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
            log.debug("FZF exited with code: \(exitCode ?? 0)")
            guard exitCode != SIGTERM, exitCode != SIGKILL else {
                return
            }
            guard exitCode != 512 else {
                Self.forceStopFZF()
                return
            }
            guard exitCode != 256 else {
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

        pub(.disabledVolumes)
            .debounce(for: 2.0, scheduler: RunLoop.main)
            .sink { [self] volumes in
                disabledVolumes = volumes.newValue
                enabledVolumes = externalVolumes.filter { !disabledVolumes.contains($0) }
                externalIndexes = getExternalIndexes()

                restartServer()
            }.store(in: &observers)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didMountNotification)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification))
            .sink { _ in
                self.externalVolumes = Self.getVolumes()
                self.restartServer()
            }
            .store(in: &observers)

        indexFolder.mkdir(withIntermediateDirectories: true, permissions: 0o700)
        externalIndexes = getExternalIndexes()

        if FullDiskAccess.isGranted {
            hasFullDiskAccess = true
            startIndex()
        } else {
            fullDiskAccessChecker = Repeater(every: 1) {
                guard FullDiskAccess.isGranted else { return }
                self.hasFullDiskAccess = true
                self.fullDiskAccessChecker = nil
                self.startIndex()
            }
        }
    }

    func reloadResults() {
        scoredResults = scoredResults
        results = sortedResults()
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

        if !indexExists {
            indexFiles(pauseSearch: true) { [self] in
                watchFiles()
                restartServer()
                indexStaleExternalVolumes()
            }
        } else if indexIsStale, batteryLevel() > 0.3 {
            startServer()
            indexFiles(pauseSearch: false) { [self] in
                watchFiles()
                restartServer()
                indexStaleExternalVolumes()
            }
        } else {
            consolidateLiveIndex()
            watchFiles()
            startServer()
            indexStaleExternalVolumes()
        }

        indexChecker = Repeater(every: 60 * 60, name: "Index Checker", tolerance: 60 * 60) { [self] in
            guard batteryLevel() > 0.3 else {
                return
            }
            refresh(pauseSearch: false)
        }
    }

    func refresh(pauseSearch: Bool = true) {
        guard !indexing, FullDiskAccess.isGranted else {
            return
        }

        if pauseSearch {
            indexing = true
            operation = "Reindexing filesystem"
            fetchTask?.cancel()
            queryTask?.cancel()
        }

        stopWatchingFiles()
        indexFiles(pauseSearch: pauseSearch) { [self] in
            watchFiles()
            restartServer()
            indexStaleExternalVolumes()
        }
    }

    func appendToIndex(_ indexFile: FilePath, paths: [String]) {
        guard !paths.isEmpty, let scope = scopeForIndex(indexFile), Defaults[.searchScopes].contains(scope) else {
            return
        }

        do {
            if !indexFile.exists {
                FileManager.default.createFile(atPath: indexFile.string, contents: nil, attributes: nil)
            }
            let fileHandle = try FileHandle(forUpdating: indexFile.url)
            fileHandle.seekToEndOfFile()
            let content = paths.joined(separator: "\n") + "\n"
            if let data = content.data(using: .utf8) {
                fileHandle.write(data)
            }
            try fileHandle.close()
        } catch {
            log.error("Failed to append to index \(indexFile.string): \(error)")
        }
    }

    func scopeForIndex(_ indexFile: FilePath) -> SearchScope? {
        switch indexFile {
        case homeIndex:
            .home
        case libraryIndex:
            .library
        case rootIndex:
            .root
        default:
            nil
        }
    }

    func consolidateLiveIndex() {
        guard liveIndex.exists else {
            return
        }

        do {
            let liveContent = try String(contentsOf: liveIndex.url)
            let paths = liveContent.components(separatedBy: .newlines).filter { !$0.isEmpty }
            let uniquePaths = (NSOrderedSet(array: paths).array as! [String]).filter {
                FileManager.default.fileExists(atPath: $0)
            }

            var homePathsToAdd = [String]()
            var libraryPathsToAdd = [String]()
            var rootPathsToAdd = [String]()

            let home = HOME.string
            let library = "\(HOME.string)/Library"

            for path in uniquePaths {
                if path.starts(with: home) {
                    if path.starts(with: library) {
                        libraryPathsToAdd.append(path)
                    } else {
                        homePathsToAdd.append(path)
                    }
                } else {
                    rootPathsToAdd.append(path)
                }
            }

            appendToIndex(homeIndex, paths: homePathsToAdd)
            appendToIndex(libraryIndex, paths: libraryPathsToAdd)
            appendToIndex(rootIndex, paths: rootPathsToAdd)
        } catch {
            log.error("Failed to consolidate live index: \(error)")
        }
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
                    mainActor { self.indexProcesses.removeAll { $0 == process } }

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

    func rgCommand(_ filter: FolderFilter, args: [String] = [], files: [FilePath] = []) -> String {
        let folderPattern = filter.folders.map { "^\($0.string)/" }.joined(separator: "|")
        let files = files.map { "$'\($0.string)'" }.joined(separator: " ")
        return Self.RG_COMMAND + " \(args.joined(separator: " ")) " + "$'\(folderPattern)' " + files
    }

    func startServer(indexes: [FilePath]? = nil) {
        let indexes: [FilePath] = (indexes ?? limitedSearchScopeIndexes ?? searchScopeIndexes).filter(\.exists)

        let liveIndexIsRelevant = indexes.contains { f in scopeForIndex(f).map { scope in Defaults[.searchScopes].contains(scope) } ?? false }
        let liveIndexCommand = liveIndexIsRelevant
            ? "; tail -f \"\(liveIndex.string)\"" + (folderFilter.map { " | \(rgCommand($0, args: ["--line-buffered"]))" } ?? "")
            : ""

        let printIndexCommand = if let filter = folderFilter {
            rgCommand(filter, files: indexes)
        } else {
            "/bin/cat \(indexes.map { "\"\($0.string)\"" }.joined(separator: " "))"
        }

        let query = constructQuery(query).trimmed.replacing(Self.UNESCAPED_SHELL_CHARS, with: { m in "\(m.1 ?? "")\\\(m.2)" })
        let command =
            "{ \(printIndexCommand) \(liveIndexCommand) } | \(FZF_BINARY) --algo=\(Defaults[.fasterSearchLessOptimalResults] ? "v1" : "v2") --height=20 --border=none --no-info --no-hscroll --no-unicode --no-mouse --no-separator --no-scrollbar --no-color --no-bold --no-clear --scheme=path --bind 'result:execute-silent:echo -n _ | nc -w 1 localhost \(SERVER_PORT)' --listen=localhost:\(FZF_SERVER_PORT)"
                + (query.isEmpty ? "" : " --query=$'\(query)'")
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color") + [
            "FZF_API_KEY=\(FZF_API_KEY)",
            "FZF_COLUMNS=80",
            "FZF_LINES=20",
            "SHELL=\(FAST_SHELL)",
        ]

        log.verbose("Starting fzf server with command:\n\(command)")

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

    func restartServer(indexes: [FilePath]? = nil) {
        stopServer()
        startServer(indexes: indexes)
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

        if emptyQuery, volumeFilter == nil {
            scoredResults = []
            results = []
            noQuery = true
            return
        }

        var request = URLRequest(url: FZF_URL)
        request.addValue(FZF_API_KEY, forHTTPHeaderField: "x-api-key")

        fetchTask = URLSession.shared.dataTask(with: request) { [self] data, response, error in
            if let error {
                log.error("Main server request error: \(error)")
                return
            }

            guard let data else {
                log.error("No data received from main server")
                return
            }

            processSearchResults(data: data)
        }
        fetchTask!.resume()
    }

    nonisolated func processSearchResults(data: Data) {
        let response: FzfResponse
        do {
            response = try JSONDecoder().decode(FzfResponse.self, from: data)
        } catch {
            log.error("JSON decode error: \(error)")
            return
        }

        mainActor {
            var indexedResults = response.matches.map(\.text)

            // Filter results based on search scopes if needed
            if !Defaults[.searchScopes].contains(.library) {
                let library = "\(HOME.string)/Library"
                indexedResults.removeAll { $0.starts(with: library) }
            }
            if !Defaults[.searchScopes].contains(.home) {
                let home = HOME.string
                let library = "\(HOME.string)/Library"
                indexedResults.removeAll { $0.starts(with: home) && !$0.starts(with: library) }
            }
            if !Defaults[.searchScopes].contains(.root) {
                indexedResults.removeAll { !$0.starts(with: HOME.string) }
            }

            let results = NSMutableOrderedSet(array: indexedResults.prefix(Defaults[.maxResultsCount]).arr)

            results.minusSet(HARD_IGNORED)
            if !self.removedFiles.isEmpty {
                results.minusSet(self.removedFiles)
            }
            self.scoredResults = (results.array as! [String]).compactMap {
                guard let path = $0.filePath else {
                    return nil
                }
                path.cache($0.hasSuffix("/"), forKey: \.isDir)
                return path
            }.filter {
                $0.memoz.isOnExternalVolume ? true : $0.exists
            }
            self.results = self.sortedResults()
            if !self.emptyQuery {
                self.noQuery = false
            }
        }
    }

    func excludeFromIndex(paths: Set<FilePath>) {
        let fileList = paths.map(\.string).joined(separator: "\n")
        do {
            let fileHandle = try FileHandle(forUpdating: fsignore.url)
            fileHandle.seekToEndOfFile()
            if let data = "\n\(fileList)".data(using: .utf8) {
                fileHandle.write(data)
            }
            fileHandle.closeFile()
        } catch {
            log.error("Failed to write to fsignore: \(error.localizedDescription)")
        }

        removedFiles.formUnion(paths.map(\.string))
        results = results.without(paths)
        scoredResults = scoredResults.without(paths)
        recents = recents.without(paths)
        sortedRecents = sortedRecents.without(paths)

        fetchResults()
    }

    func sortedResults(results: [FilePath]? = nil) -> [FilePath] {
        guard sortField != .score else {
            return results ?? scoredResults
        }
        return (results ?? scoredResults).sorted { a, b in
            switch sortField {
            case .name:
                return reverseSort ? (a.name.string.lowercased() > b.name.string.lowercased()) : (a.name.string.lowercased() < b.name.string.lowercased())
            case .path:
                return reverseSort ? (a.dir.string.lowercased() > b.dir.string.lowercased()) : (a.dir.string.lowercased() < b.dir.string.lowercased())
            case .size:
                let aSize = a.memoz.size
                let bSize = b.memoz.size
                return reverseSort ? (aSize > bSize) : (aSize < bSize)
            case .date:
                let aDate = a.memoz.date
                let bDate = b.memoz.date
                return reverseSort ? (aDate > bDate) : (aDate < bDate)
            case .kind:
                let aKind = ((a.memoz.isDir ? "\0" : "") + (a.extension ?? "") + (a.stem ?? "")).lowercased()
                let bKind = ((b.memoz.isDir ? "\0" : "") + (b.extension ?? "") + (b.stem ?? "")).lowercased()
                return reverseSort ? (aKind > bKind) : (aKind < bKind)
            default:
                return true
            }
        }

    }

    func constructQuery(_ query: String) -> String {
        var query = query

        if let quickFilter {
            query = "\(query) \(quickFilter.query)"
        }
        if query.contains("~/") {
            query = query.replacingOccurrences(of: "~/", with: "\(HOME.string)/")
        }
        return query
    }

    func sendQuery(_ query: String) {
        queryTask?.cancel()

        if query.isEmpty, quickFilter == nil {
            noQuery = true
            scoredResults = []
            results = []
            return
        }

        guard !indexing else {
            return
        }

        let query = constructQuery(query)

        // Send to main server
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
                    let running = terminal.running
                    if !running {
                        restartServer()
                    }
                }
                return
            }
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

let FZF_URL = URL(string: "http://127.0.0.1:\(FZF_SERVER_PORT)")!

@MainActor let FUZZY = FuzzyClient()
