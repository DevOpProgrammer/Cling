import Cocoa
import Combine
import Defaults
import Foundation
import Lowtech
import SwiftTerm
import System

let DEFAULT_VOLUME_REINDEX_INTERVAL: TimeInterval = 60 * 60 * 24 * 7 // 1 week

extension FuzzyClient {
    var staleExternalVolumes: [FilePath] {
        enabledVolumes.filter { volume in
            guard volume.exists else {
                return false
            }
            let index = indexFolder / "\(volume.name.string.replacingOccurrences(of: " ", with: "-")).index"
            let interval = Defaults[.reindexTimeIntervalPerVolume][volume] ?? DEFAULT_VOLUME_REINDEX_INTERVAL
            return !index.exists || (index.timestamp ?? 0) < Date().addingTimeInterval(-interval).timeIntervalSince1970
        }
    }

    static func getVolumes() -> [FilePath] {
        let mountedVolumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.isVolumeKey, .volumeIsRootFileSystemKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        return mountedVolumes.filter(\.isVolume).compactMap(\.filePath).uniqued.sorted()
    }

    func indexStaleExternalVolumes() {
        let externalVolumes = staleExternalVolumes
        guard !externalVolumes.isEmpty else {
            return
        }

        indexVolumes(externalVolumes) {
            self.restartServer()
        }
    }

    func getExternalIndexes() -> [FilePath] {
        enabledVolumes
            .map { volume in
                indexFolder / "\(volume.name.string.replacingOccurrences(of: " ", with: "-")).index"
            }
    }

    func indexVolumes(_ volumes: [FilePath], onFinish: (@MainActor () -> Void)? = nil) {
        let volumes = volumes.filter(\.exists)
        guard !volumes.isEmpty else {
            return
        }

        backgroundIndexing = true
        let group = DispatchGroup()

        for volume in volumes {
            let volumeName = volume.name.string
            let indexFile = indexFolder / "\(volumeName.replacingOccurrences(of: " ", with: "-")).index"
            let fdThreads = max(1, ProcessInfo.processInfo.activeProcessorCount / volumes.count)
            let tempFile = FilePath.dir("/tmp/cling") / "\(UUID().uuidString).index"
            FileManager.default.createFile(atPath: tempFile.string, contents: nil, attributes: [FileAttributeKey.posixPermissions: 0o600])

            guard let file = try? FileHandle(forWritingTo: tempFile.url) else {
                log.error("Failed to open temp file \(tempFile.string)")
                continue
            }

            mainActor { self.operation = "Indexing volume: \(volumeName)" }

            group.enter()
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = FD_BINARY.url
                process.arguments = [
                    "-uu",
                    "-j",
                    "\(fdThreads)",
                    "--one-file-system",
                    "--ignore-file",
                    "\(HOME.string)/.fsignore",
                    ".",
                    volume.string,
                ]
                process.standardOutput = file

                do {
                    try process.run()
                    mainActor { self.indexProcesses.append(process) }

                    process.waitUntilExit()
                    mainActor { self.indexProcesses.removeAll { $0 == process } }

                    file.closeFile()
                    _ = try? tempFile.move(to: indexFile, force: true)

                    mainActor { self.operation = "Indexed volume: \(volumeName)" }
                } catch {
                    log.error("Failed to index volume \(volume.string): \(error)")
                    mainActor { self.operation = "Failed to index volume: \(volumeName)" }
                }

                group.leave()
            }
        }

        group.notify(queue: .main) {
            onFinish?()
            self.backgroundIndexing = false
        }
    }

    func indexVolume(_ volume: FilePath) {
        indexVolumes([volume]) {
            self.restartServer()
        }
    }

}
