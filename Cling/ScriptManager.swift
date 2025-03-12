import Defaults
import Foundation
import Lowtech
import System

let DEFAULT_SCRIPTS = [
    Bundle.main.url(forResource: "Copy to temporary folder", withExtension: "zsh")!.filePath!,
    Bundle.main.url(forResource: "List archive contents", withExtension: "zsh")!.filePath!,
    Bundle.main.url(forResource: "Archive", withExtension: "zsh")!.filePath!,
]
let scriptsFolder: FilePath =
    FileManager.default.urls(for: .applicationScriptsDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Cling", isDirectory: true).filePath ?? "~/.local/cling-scripts".filePath!
let defaultScriptsMarker = scriptsFolder / ".default-scripts-installed"
let SEVEN_ZIP = Bundle.main.url(forResource: "7zz", withExtension: nil)!.filePath!

@Observable
class ScriptManager {
    init() {
        asyncNow {
            self.loadShellEnv()
        }

        if !scriptsFolder.exists {
            scriptsFolder.mkdir(withIntermediateDirectories: true)
        }
        if !defaultScriptsMarker.exists {
            for script in DEFAULT_SCRIPTS {
                _ = try? script.copy(to: scriptsFolder)
            }
            FileManager.default.createFile(atPath: defaultScriptsMarker.string, contents: nil, attributes: nil)
        }
        fetchScripts()
        startScriptsWatcher()
    }

    // reads the script
    // finds the line that starts with symbols, whitespace and then extensions: and returns the extensions
    // the line can start with any symbol like #, //, --, etc
    // the extensions can be separated by commas or spaces

    static let EXTENSIONS_REGEX: Regex<(Substring, Substring)> = try! Regex(#"^[^a-z0-9\n]+extensions:\s*([a-z0-9\-\., \t]*)"#).anchorsMatchLineEndings().ignoresCase()
    static let SHOW_OUTPUT_REGEX: Regex<(Substring, Substring)> = try! Regex(#"^[^a-z0-9\n]+showOutput:\s*(true|yes|1|on|enable)"#).anchorsMatchLineEndings().ignoresCase()

    var scriptShortcuts: [URL: Character] = [:]
    var scriptURLs: [URL] = []
    var scriptsByExtension: [String: [URL]] = [:]
    var scriptsWithOutput: Set<URL> = []
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
                    self.clearLastProcessTask = mainAsyncAfter(30) {
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

    func getScriptExtensions(_ script: URL, contents: String) {
        guard let match = try? Self.EXTENSIONS_REGEX.firstMatch(in: contents) else {
            scriptsByExtension["ALL"] = (scriptsByExtension["ALL"] ?? []) + [script]
            return
        }
        let extensions = match.1
            .split(separator: ",").flatMap { $0.split(separator: " ") }
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)) }

        for ext in extensions {
            scriptsByExtension[String(ext)] = (scriptsByExtension[String(ext)] ?? []) + [script]
        }
    }

    func run(script: URL, args: [String]) {
        guard script.fileExists else {
            log.error("Script not found: \(script)")
            return
        }
        lastScript = script
        var env = shellEnv ?? [:]
        env["CLING_SEVEN_ZIP"] = SEVEN_ZIP.string
        env["CLING_FZF"] = FZF_BINARY.string
        env["CLING_FD"] = FD_BINARY.string
        process = shellProc(script.path, args: args, env: env)
    }

    func commonScripts(for exts: [String]) -> [URL] {
        let scriptSets = exts.compactMap { scriptsByExtension[$0]?.set }
        guard let first = scriptSets.first else {
            return scriptsByExtension["ALL"] ?? []
        }

        return scriptSets.dropFirst().reduce(first) { $0.intersection($1) }.union(scriptsByExtension["ALL"] ?? []).arr
    }

    func fetchScripts() {
        do {
            // Fetch only executable files
            let files = try FileManager.default.contentsOfDirectory(at: scriptsFolder.url, includingPropertiesForKeys: [.isExecutableKey], options: .skipsHiddenFiles)
            scriptURLs = files.filter {
                (try? $0.resourceValues(forKeys: [.isExecutableKey]).isExecutable) ?? false
            }

            scriptsByExtension = [:]
            scriptsWithOutput = []
            for script in scriptURLs {
                guard let scriptContents = try? String(contentsOf: script) else {
                    continue
                }
                getScriptExtensions(script, contents: scriptContents)
                if scriptContents.contains(Self.SHOW_OUTPUT_REGEX) {
                    scriptsWithOutput.insert(script)
                }
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
