import ClopSDK
import Defaults
import Lowtech
import SwiftUI
import System
import UniformTypeIdentifiers

struct ScriptPickerView: View {
    let fileURLs: [URL]
    @Environment(\.dismiss) var dismiss
    @State private var isShowingAddScript = false
    @State private var scriptName = ""
    @State private var selectedRunner: ScriptRunner? = .zsh
    @State private var scriptManager = SM

    func scriptButton(_ script: URL) -> some View {
        HStack {
            Button(action: {
                scriptManager.run(script: script, args: fileURLs.map(\.path))
                dismiss()
            }) {
                HStack {
                    Image(nsImage: icon(for: script))
                    Text(script.lastPathComponent.ns.deletingPathExtension)

                    if let shortcut = scriptManager.scriptShortcuts[script] {
                        Spacer()
                        Text(String(shortcut).uppercased()).monospaced().bold().foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(FlatButton(color: .bg.primary.opacity(0.4), textColor: .primary))
            .ifLet(scriptManager.scriptShortcuts[script]) {
                $0.keyboardShortcut(KeyEquivalent($1), modifiers: [])
            }

            Button(action: {
                openInEditor(script)
            }) {
                Image(systemName: "pencil")
            }
            .buttonStyle(FlatButton(color: .bg.primary.opacity(0.4), textColor: .primary))
            .ifLet(scriptManager.scriptShortcuts[script]) {
                $0.keyboardShortcut(KeyEquivalent($1), modifiers: [.command, .shift])
                    .help("Edit script in \(Defaults[.editorApp].filePath?.stem ?? "TextEdit") (⌘⇧\($1)")
            }
        }
    }

    @ViewBuilder
    var scriptList: some View {
        ForEach(scriptManager.scriptURLs.sorted(by: \.lastPathComponent), id: \.path) { script in
            scriptButton(script)
        }.focusable(false)
    }

    var body: some View {
        VStack {
            if !scriptManager.scriptURLs.isEmpty {
                scriptList
            } else {
                Text("No scripts found in")
                Button("\(scriptsFolder.shellString)") {
                    NSWorkspace.shared.open(scriptsFolder.url)
                }
                .buttonStyle(TextButton())
                .font(.mono(10))
                .padding(.top, 2)
                .focusable(false)
            }

            HStack {
                Button("⌘N Create Script") { isShowingAddScript = true }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("⌘O Open script folder") {
                    NSWorkspace.shared.open(scriptsFolder.url)
                    NSApp.deactivate()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            .padding(.top)
        }
        .padding()
        .sheet(isPresented: $isShowingAddScript, onDismiss: createNewScript) {
            AddScriptView(name: $scriptName, selectedRunner: $selectedRunner)
        }
    }

    func createNewScript() {
        guard !scriptName.isEmpty else { return }
        let ext = selectedRunner?.fileExtension ?? "sh"
        let newScript = scriptsFolder / "\(scriptName.safeFilename).\(ext)"

        do {
            let shebang = selectedRunner?.shebang ?? "#!/bin/zsh"
            try "\(shebang)\n".write(to: newScript.url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newScript.string)
            newScript.edit()
        } catch {
            log.error("Failed to create script: \(error.localizedDescription)")
        }

        scriptName = ""
        selectedRunner = nil
        scriptManager.fetchScripts() // Update scripts and shortcuts
    }
}

struct ScriptActionButtons: View {
    let selectedResults: Set<FilePath>
    var focused: FocusState<FocusedField?>.Binding

    var body: some View {
        HStack {
            runThroughScriptButton
                .frame(width: 110, alignment: .leading)
                .disabled(selectedResults.isEmpty || scriptManager.process != nil)

            Divider().frame(height: 16)

            if commonScripts.isEmpty {
                Text("Script hotkeys will appear here")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
                Spacer()
            } else {
                HStack(spacing: 1) {
                    Text("⌘").roundbg(color: .bg.primary.opacity(0.2))
                    Text("⌃").roundbg(color: .bg.primary.opacity(0.2))
                    Text(" +")
                }.foregroundColor(.fg.warm)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        scriptList
                    }.buttonStyle(BorderlessTextButton(color: .fg.warm.opacity(0.8)))
                }.disabled(selectedResults.isEmpty || scriptManager.process != nil)
            }

            runningProcessButton
            clopButton
        }
        .font(.system(size: 10))
        .buttonStyle(TextButton(color: .fg.warm.opacity(0.9)))
        .lineLimit(1)
        .onAppear {
            let extensions = selectedResults.compactMap(\.extension).uniqued
            commonScripts = scriptManager.commonScripts(for: extensions).sorted(by: \.lastPathComponent)
        }
        .onChange(of: selectedResults) {
            let extensions = selectedResults.compactMap(\.extension).uniqued
            commonScripts = scriptManager.commonScripts(for: extensions).sorted(by: \.lastPathComponent)
        }
    }

    @ViewBuilder
    var scriptList: some View {
        ForEach(commonScripts, id: \.path) { script in
            if let key = scriptManager.scriptShortcuts[script] {
                scriptButton(script, key: key)
            }
        }
    }

    func outputView(output: String?, error: String?, path: FilePath?) -> some View {
        VStack(spacing: 5) {
            HStack {
                Button(action: { showOutput = false }) {
                    Image(systemName: "xmark")
                        .font(.heavy(7))
                        .foregroundColor(.bg.warm)
                }
                .buttonStyle(FlatButton(color: .fg.warm.opacity(0.6), circle: true, horizontalPadding: 5, verticalPadding: 5))
                .padding(.top, 8).padding(.leading, 8)
                Spacer()
            }

            if let output, output.isNotEmpty {
                ScrollView {
                    VStack(alignment: .leading) {
                        Text("OUTPUT")
                            .font(.bold(10))
                            .foregroundColor(.secondary)
                        Text(output)
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .monospaced()
                            .fill(.topLeading)
                    }.frame(maxWidth: .infinity)
                }
                .roundbg(radius: 12, color: .bg.primary.opacity(0.1))
                .padding(.bottom).padding(.horizontal, 25)
            }

            if let error, error.isNotEmpty {
                ScrollView {
                    VStack(alignment: .leading) {
                        Text("ERRORS")
                            .font(.bold(10))
                            .foregroundColor(.secondary)
                        Text(error)
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .monospaced()
                            .fill(.topLeading)
                    }.frame(maxWidth: .infinity)
                }
                .roundbg(radius: 12, color: .bg.primary.opacity(0.1))
                .padding(.bottom).padding(.horizontal, 25)
            }

            if let path {
                Button("Open in editor") {
                    path.edit()
                }
                .padding(4)
            }
        }.frame(width: 600, height: 300, alignment: .topLeading)
    }

    @State private var commonScripts: [URL] = []

    @State private var showOutput = false

    @State private var scriptManager = SM
    @State private var fuzzy = FUZZY
    @State private var isPresentingScriptPicker = false

    @ViewBuilder
    private var runningProcessButton: some View {
        HStack(spacing: 0) {
            if let script = scriptManager.lastScript, let outputFile = scriptManager.lastOutputFile, let errorFile = scriptManager.lastErrorFile {
                Button(action: {
                    if let process = scriptManager.process {
                        process.terminate()
                    } else {
                        scriptManager.clearLastProcess()
                    }
                }) {
                    Image(systemName: "xmark").font(.heavy(10))
                }
                .buttonStyle(BorderlessTextButton(color: .fg.warm.opacity(0.8)))
                .help(scriptManager.process != nil ? "Terminate script" : "Clear process output")

                Button(action: {
                    let outSize = outputFile.fileSize() ?? 0
                    let errSize = errorFile.fileSize() ?? 0

                    guard outSize + errSize > 0 else {
                        return
                    }

                    if outSize + errSize < 100 * 1024 {
                        showOutput = true
                    } else {
                        scriptManager.combinedOutputFile?.edit()
                    }
                }) {
                    HStack(spacing: 1) {
                        if scriptManager.process != nil {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.mini)
                                .padding(.trailing, 5)

                        }
                        Text(script.lastPathComponent.ns.deletingPathExtension)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .buttonStyle(TextButton(color: .fg.warm.opacity(0.8)))
                .sheet(isPresented: $showOutput) {
                    let output = (try? String(contentsOf: outputFile.url))?.trimmed
                    let error = (try? String(contentsOf: errorFile.url))?.trimmed

                    if let output, let error {
                        outputView(output: output, error: error, path: scriptManager.combinedOutputFile)
                    } else {
                        Text("No output").padding()
                    }
                }
                .help("View script output and errors")
            }
        }
    }

    @ViewBuilder
    private var clopButton: some View {
        if fuzzy.clopIsAvailable {
            let clopCandidates = selectedResults.filter(\.exists).map(\.url).filter(\.memoz.canBeOptimisedByClop)
            if clopCandidates.isNotEmpty {
                let oKeyAvailable = !scriptManager.scriptShortcuts.values.contains("o")
                Button(action: {
                    _ = try? ClopSDK.shared.optimise(
                        paths: clopCandidates.map(\.path),
                        aggressive: NSEvent.modifierFlags.contains(.option),
                        inTheBackground: true
                    )
                }) {
                    if oKeyAvailable {
                        Text("⌘⌃O").mono(10, weight: .bold).foregroundColor(.fg.warm.opacity(0.8)) + Text(" Optimise with Clop")
                    } else {
                        Text("Optimise with Clop")
                    }
                }
                .buttonStyle(TextButton(color: .fg.warm.opacity(0.8)))
                .if(oKeyAvailable) {
                    $0.keyboardShortcut("o", modifiers: [.command, .control])
                }
            }
        }

    }

    private var runThroughScriptButton: some View {
        Button("⌘E Execute script") {
            focused.wrappedValue = .executeScript
            isPresentingScriptPicker = true
        }
        .keyboardShortcut("x", modifiers: [.command])
        .help("Run the selected files through a script")
        .sheet(isPresented: $isPresentingScriptPicker) {
            ScriptPickerView(fileURLs: selectedResults.map(\.url))
                .font(.medium(13))
                .focused(focused, equals: .executeScript)
        }
    }

    private func scriptButton(_ script: URL, key: Character) -> some View {
        Button(action: {
            scriptManager.run(script: script, args: selectedResults.map(\.string))
        }) {
            HStack(spacing: 0) {
                Text("\(key.uppercased())").mono(10, weight: .bold).foregroundColor(.fg.warm).roundbg(color: .bg.primary.opacity(0.2))
                Text(" \(script.lastPathComponent.ns.deletingPathExtension)")
            }
        }
    }

}

func openInEditor(_ file: URL) {
    NSWorkspace.shared.open(
        [file],
        withApplicationAt: Defaults[.editorApp].fileURL ?? URL(fileURLWithPath: "/Applications/TextEdit.app"),
        configuration: NSWorkspace.OpenConfiguration()
    )

}

extension FilePath {
    func edit() {
        openInEditor(url)
    }
}

extension URL {
    var fileExists: Bool {
        filePath?.exists ?? false
    }
}

struct AddScriptView: View {
    @Binding var name: String
    @Binding var selectedRunner: ScriptRunner?

    var body: some View {
        VStack {
            VStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        dismiss()
                        NSApp.deactivate()
                    }
                Picker("Script runner", selection: $selectedRunner) {
                    ForEach(ScriptRunner.allCases, id: \.self) { runner in
                        Text("\(runner.name) (\(runner.path))").tag(runner as ScriptRunner?)
                    }
                    Divider()
                    Text("Custom").tag(nil as ScriptRunner?)
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            .padding()
            HStack {
                Button {
                    cancel()
                } label: {
                    Label("Cancel", systemImage: "escape")
                }
                Button {
                    dismiss()
                    NSApp.deactivate()
                } label: {
                    Text("⌘S Save")
                }
                .keyboardShortcut("s")
            }
        }
        .onExitCommand {
            cancel()
        }
        .padding()
    }

    func cancel() {
        name = ""
        selectedRunner = nil
        dismiss()
    }

    @Environment(\.dismiss) private var dismiss
}

enum ScriptRunner: String, CaseIterable {
    case sh
    case zsh
    case fish
    case python3
    case ruby
    case perl
    case swift
    case osascript
    case node

    init?(fromShebang shebang: String) {
        let path = shebang.replacingOccurrences(of: "#!", with: "").replacingOccurrences(of: "/usr/bin/env ", with: "").trimmingCharacters(in: .whitespaces)
        guard let runner = ScriptRunner.allCases.first(where: { $0.path == path }) ?? ScriptRunner.allCases.first(where: { $0.path.contains(path) }) else {
            return nil
        }
        self = runner
    }

    init?(fromExtension ext: String) {
        guard let runner = ScriptRunner.allCases.first(where: { $0.fileExtension == ext }) else {
            return nil
        }
        self = runner
    }

    var fileExtension: String {
        switch self {
        case .sh: "sh"
        case .zsh: "zsh"
        case .fish: "fish"
        case .python3: "py"
        case .ruby: "rb"
        case .perl: "pl"
        case .swift: "swift"
        case .osascript: "scpt"
        case .node: "js"
        }
    }

    var shebang: String {
        "#!\(path)"
    }

    var utType: UTType? {
        if let utType = UTType(filenameExtension: fileExtension) {
            return utType
        }

        switch self {
        case .sh: return .shellScript
        case .zsh: return .shellScript
        case .fish: return .shellScript
        case .python3: return .pythonScript
        case .ruby: return .rubyScript
        case .perl: return .perlScript
        case .swift: return .swiftSource
        case .osascript: return .appleScript
        case .node: return .javaScript
        }
    }

    var name: String {
        switch self {
        case .sh: "Bash"
        case .zsh: "Zsh"
        case .fish: "Fish"
        case .python3: "Python 3"
        case .ruby: "Ruby"
        case .perl: "Perl"
        case .swift: "Swift"
        case .osascript: "AppleScript"
        case .node: "Node.js"
        }
    }

    var path: String {
        switch self {
        case .sh: "/bin/sh"
        case .zsh: "/bin/zsh"
        case .fish: "/usr/local/bin/fish"
        case .python3: "/usr/bin/python3"
        case .ruby: "/usr/bin/ruby"
        case .perl: "/usr/bin/perl"
        case .swift: "/usr/bin/swift"
        case .osascript: "/usr/bin/osascript"
        case .node: "/usr/local/bin/node"
        }
    }
}
