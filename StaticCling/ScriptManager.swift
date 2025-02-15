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
    @ObservationIgnored var shellEnv: [String: String]? = nil

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
