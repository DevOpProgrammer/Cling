import AppKit
import Lowtech
import SwiftUI
import System

struct RightClickMenu: View {
    @Binding var selectedResults: Set<FilePath>

    var body: some View {
        Menu("Export results list") {
            Button("as CSV") { exportAs(type: .csv) }
            Button("as TSV") { exportAs(type: .tsv) }
            Button("as JSON") { exportAs(type: .json) }
            Button("as plaintext") { exportAs(type: .plaintext) }
        }

        Button("Copy files to...") {
            performFileOperation(.copy)
        }

        Button("Move files to...") {
            performFileOperation(.move)
        }
    }

    private enum ExportType {
        case csv, tsv, json, plaintext
    }

    private enum FileOperation {
        case copy, move
    }

    private func exportAs(type: ExportType) {
        let panel = NSSavePanel()
        panel.allowsOtherFileTypes = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = switch type {
        case .csv: [.commaSeparatedText]
        case .tsv: [.tabSeparatedText]
        case .json: [.json]
        case .plaintext: [.plainText]
        }
        panel.nameFieldStringValue = switch type {
        case .csv: "cling-files.csv"
        case .tsv: "cling-files.tsv"
        case .json: "cling-files.json"
        case .plaintext: "cling-files.txt"
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                switch type {
                case .csv:
                    try exportCSV(to: url)
                case .tsv:
                    try exportTSV(to: url)
                case .json:
                    try exportJSON(to: url)
                case .plaintext:
                    try exportPlaintext(to: url)
                }
            } catch {
                log.error("Failed to write to \(url.path): \(error.localizedDescription)")
            }
        }
    }

    private func exportCSV(to url: URL) throws {
        let header = "Path,Size,Date"
        let fileContents = selectedResults.map { path in
            let size = path.fileSize() ?? 0
            let date = (path.memoz.modificationDate ?? Date()).iso8601String
            return "\(path.string),\(size),\(date)"
        }.joined(separator: "\n")
        let csvContent = "\(header)\n\(fileContents)"
        try csvContent.write(to: url, atomically: true, encoding: .utf8)
    }

    private func exportTSV(to url: URL) throws {
        let header = "Path\tSize\tDate"
        let fileContents = selectedResults.map { path in
            let size = path.fileSize() ?? 0
            let date = (path.memoz.modificationDate ?? Date()).iso8601String
            return "\(path.string)\t\(size)\t\(date)"
        }.joined(separator: "\n")
        let tsvContent = "\(header)\n\(fileContents)"
        try tsvContent.write(to: url, atomically: true, encoding: .utf8)
    }

    private func exportJSON(to url: URL) throws {
        let fileContents = selectedResults.map { path in
            let size = path.fileSize() ?? 0
            let date = (path.memoz.modificationDate ?? Date()).iso8601String
            return [
                "path": path.string,
                "size": size,
                "date": date,
            ]
        }
        let jsonData = try JSONSerialization.data(withJSONObject: fileContents, options: .prettyPrinted)
        try jsonData.write(to: url)
    }

    private func exportPlaintext(to url: URL) throws {
        let fileContents = selectedResults.map(\.string).joined(separator: "\n")
        try fileContents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func performFileOperation(_ operation: FileOperation) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let dir = panel.url?.existingFilePath else { return }
            for file in selectedResults {
                do {
                    switch operation {
                    case .copy:
                        try file.copy(to: dir)
                    case .move:
                        try file.move(to: dir)
                    }
                } catch {
                    let operationName = operation == .copy ? "copy" : "move"
                    log.error("Failed to \(operationName) \(file.shellString) to \(dir.shellString): \(error.localizedDescription)")
                }
            }
        }
    }
}

extension Date {
    var iso8601String: String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: self)
    }
}
