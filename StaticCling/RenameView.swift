import Foundation
import Lowtech
import SwiftUI
import System

struct RenameView: View {
    init(originalPaths: [FilePath], renamedPaths: Binding<[FilePath]?>) {
        let sorted = originalPaths.sorted { $0.string < $1.string }
        self.originalPaths = sorted
        _renamedPaths = renamedPaths
        _text = State(initialValue: sorted.map(\.string).joined(separator: "\n"))
    }

    @Binding var renamedPaths: [FilePath]?
    @Environment(\.dismiss) var dismiss

    let originalPaths: [FilePath]

    var body: some View {
        VStack {
            ZStack {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .padding()
            }
            .scrollContentBackground(.hidden)
            .roundbg(radius: 12, verticalPadding: 2, horizontalPadding: 2, color: .gray.opacity(0.1))

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer()
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .fixedSize()
                    Spacer()
                }
                Button("Rename") {
                    let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
                    if lines.count != originalPaths.count {
                        errorMessage = "File count mismatch: expected \(originalPaths.count) lines, got \(lines.count)."
                    } else {
                        renamedPaths = lines.map { FilePath($0) }
                        errorMessage = nil
                        dismiss()
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding()
    }

    @State private var text: String
    @State private var errorMessage: String? = nil

}

func performRenameOperation(originalPaths: [FilePath], renamedPaths: [FilePath]) throws -> [FilePath: FilePath] {
    guard !renamedPaths.isEmpty, originalPaths.count == renamedPaths.count else {
        throw NSError(domain: "RenameError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mismatched file count."])
    }

    let onlyChanged = zip(originalPaths.sorted(by: \.string), renamedPaths).filter { $0.0 != $0.1 }
    guard !onlyChanged.isEmpty else {
        return [:]
    }

    // Directory to hold temporary replacement files
    let tempDir = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: onlyChanged[0].0.url, create: true)
    guard let replacementDir = tempDir.filePath, replacementDir.mkdir(withIntermediateDirectories: true) else {
        throw NSError(domain: "RenameError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create temporary directory."])
    }

    let tempMapping = onlyChanged.dict { (UUID().uuidString, $0) }
    for (tempName, (originalFile, _)) in tempMapping {
        try originalFile.copy(to: replacementDir / tempName)
    }

    for (tempName, (_, newFile)) in tempMapping {
        try (replacementDir / tempName).move(to: newFile)
    }
    return Dictionary(uniqueKeysWithValues: onlyChanged)
}
