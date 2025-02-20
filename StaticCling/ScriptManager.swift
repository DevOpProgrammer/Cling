import Defaults
import Foundation
import Lowtech
import System

let scriptsFolder: FilePath =
    FileManager.default.urls(for: .applicationScriptsDirectory, in: .userDomainMask).first?
        .appendingPathComponent("StaticCling", isDirectory: true).filePath ?? "~/.local/cling-scripts".filePath!

@Observable
class ScriptManager {
    init() {
        asyncNow {
            self.loadShellEnv()
        }

        scriptsFolder.mkdir(withIntermediateDirectories: true)
        fetchScripts()
        startScriptsWatcher()
    }

    var scriptShortcuts: [URL: Character] = [:]
    var scriptURLs: [URL] = []
    var lastScript: URL?
    var lastOutputFile: FilePath?
    var lastErrorFile: FilePath?
    @ObservationIgnored var shellEnv: [String: String]? = nil

    @ObservationIgnored lazy var combinedOutputFile: FilePath? = createCombinedOutputFile()

    var process: Process? {
        didSet {
            guard let process else {
                return
            }
            combinedOutputFile = nil
            lastOutputFile = process.stdoutFilePath?.existingFilePath
            lastErrorFile = process.stderrFilePath?.existingFilePath
            process.terminationHandler = { [self] process in
                mainActor {
                    log.verbose("Script \(self.lastScript?.lastPathComponent ?? "unknown") terminated with status \(process.terminationStatus)")
                    self.process = nil
                    clearLastProcessTask = mainAsyncAfter(30) {
                        self.clearLastProcess()
                    }
                }
            }
        }
    }

    func clearLastProcess() {
        process = nil
        lastScript = nil
        lastOutputFile = nil
        lastErrorFile = nil
        combinedOutputFile = nil
    }

    func createCombinedOutputFile() -> FilePath? {
        guard let output = lastOutputFile, let error = lastErrorFile else {
            return nil
        }
        let combined = output.withExtension("combined")
        _ = try? output.copy(to: combined)
        if let handle = try? FileHandle(forUpdating: combined.url) {
            handle.seekToEndOfFile()
            handle.write("\n\n--------\n\nSTDERR:\n\n".data(using: .utf8)!)
            try? handle.write(Data(contentsOf: error.url))
            handle.closeFile()
        }
        return combined
    }

    func fetchScripts() {
        do {
            // Fetch only executable files
            let files = try FileManager.default.contentsOfDirectory(at: scriptsFolder.url, includingPropertiesForKeys: [.isExecutableKey], options: .skipsHiddenFiles)
            scriptURLs = files.filter {
                (try? $0.resourceValues(forKeys: [.isExecutableKey]).isExecutable) ?? false
            }
            scriptShortcuts = computeShortcuts(for: scriptURLs)
        } catch {
            scriptURLs = []
            scriptShortcuts = [:]
            log.error("Failed to fetch scripts: \(error)")
        }
    }

    func startScriptsWatcher() {
        do {
            try LowtechFSEvents.startWatching(paths: [scriptsFolder.string], for: ObjectIdentifier(self), latency: 3) { event in
                mainActor { [self] in
                    guard let flags = event.flag,
                          flags.hasElements(from: [
                              .itemCreated, .itemRemoved, .itemRenamed, .itemModified, .itemChangeOwner,
                          ])
                    else {
                        log.verbose("Ignoring script event \(event)")
                        return
                    }
                    log.verbose("Handling script event \(event)")
                    fetchScripts()
                }
            }
        } catch {
            log.error("Failed to watch scripts folder \(scriptsFolder.shellString): \(error)")
        }
    }

    @ObservationIgnored private var clearLastProcessTask: DispatchWorkItem? {
        didSet {
            oldValue?.cancel()
        }
    }

    private func loadShellEnv() {
        guard let userShell = ProcessInfo.processInfo.environment["SHELL"] else {
            log.error("SHELL environment variable not found")
            return
        }
        guard let envOutput = shell(userShell, args: ["-l", "-c", "/usr/bin/printenv"]).o, envOutput.isNotEmpty else {
            log.error("Failed to get environment variables from shell")
            return
        }
        let env = envOutput.split(separator: "\n").reduce(into: [String: String]()) { dict, line in
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                dict[String(parts[0])] = String(parts[1])
            }
        }

        mainAsync {
            self.shellEnv = env
        }
    }
}

let SM = ScriptManager()
