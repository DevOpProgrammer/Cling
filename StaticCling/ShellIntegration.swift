import Foundation
import Lowtech
import System

let CLING_FISH = Bundle.main.path(forResource: "cling", ofType: "fish")!.existingFilePath!
let CLING_ZSH = Bundle.main.path(forResource: "cling", ofType: "zsh")!.existingFilePath!

enum Shell: String {
    case fish
    case zsh
    case bash
}

class ShellIntegration {
    static func installSHIntegration(configPath: FilePath) -> String {
        do {
            guard configPath.exists else {
                try CLING_ZSH.copy(to: configPath)
                log.info("\(configPath) created and cling.zsh contents added")
                return "The `cling` function has been added to \(configPath.shellString)"
            }

            let clingZshContents = try String(contentsOfFile: CLING_ZSH.string)
            let configContents = try String(contentsOfFile: configPath.string)

            if !configContents.contains(clingZshContents) {
                let mergedContents = configContents + "\n" + clingZshContents
                try mergedContents.write(to: configPath.url, atomically: true, encoding: .utf8)
                log.info("cling.zsh contents added to \(configPath)")
                return "The `cling` function has been added to \(configPath.shellString)"
            } else {
                log.info("cling.zsh contents already present in \(configPath)")
                return "The `cling` function is already present in \(configPath.shellString)"
            }
        } catch {
            log.error("Error handling cling.zsh: \(error)")
            return "Error installing shell integration into \(configPath.shellString).\n\n\(error)"
        }
    }

    static func installFishIntegration() -> String {
        let fishFunctionsPath = HOME / ".config/fish/functions"
        let destinationPath = fishFunctionsPath / "cling.fish"

        do {
            fishFunctionsPath.mkdir(withIntermediateDirectories: true)
            try CLING_FISH.copy(to: destinationPath)
            log.info("\(CLING_FISH) copied to \(destinationPath)")
            return "cling.fish copied to \(destinationPath.shellString)\n\nYou can now use the `cling` function in fish."
        } catch {
            log.error("Error copying \(CLING_FISH): \(error)")
            return "Error installing fish shell integration: \(error)"
        }
    }

    static func addClingFunction() -> String {
        guard let shell = ProcessInfo.processInfo.environment["SHELL"] else {
            log.error("SHELL environment variable not found.")
            return "SHELL environment variable not found."
        }

        guard let shell = Shell(rawValue: shell.filePath?.stem ?? shell) else {
            log.error("Shell not supported: \(shell)")
            return "Shell not supported: \(shell)"
        }

        switch shell {
        case .fish:
            return installFishIntegration()
        case .zsh:
            return installSHIntegration(configPath: HOME / ".zshrc")
        case .bash:
            return installSHIntegration(configPath: HOME / ".bashrc")
        }

    }
}
