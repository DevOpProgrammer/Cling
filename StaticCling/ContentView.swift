//
//  ContentView.swift
//  StaticCling
//
//  Created by Alin Panaitiu on 03.02.2025.
//

import Defaults
import Lowtech
import SwiftUI
import System

extension Int {
    var humanSize: String {
        switch self {
        case 0 ..< 1000:
            return "\(self)  B"
        case 0 ..< 1_000_000:
            let num = self / 1000
            return "\(num) KB"
        case 0 ..< 1_000_000_000:
            let num = d / 1_000_000
            return "\(num < 10 ? num.str(decimals: 1) : num.intround.s) MB"
        default:
            let num = d / 1_000_000_000
            return "\(num < 10 ? num.str(decimals: 1) : num.intround.s) GB"
        }
    }
}

let dateFormat = Date.FormatStyle.dateTime.year(.padded(4)).month().day(.twoDigits).hour(
    .twoDigits(amPM: .abbreviated)
).minute(.twoDigits)

struct ContentView: View {
    enum FocusedField {
        case search, list, openWith, executeScript
    }

    @Environment(\.dismiss) var dismiss

    var searchSection: some View {
        HStack {
            ZStack(alignment: .trailing) {
                searchBar
                HStack {
                    Text("press / to focus")
                        .round(10)
                        .foregroundStyle(.secondary)
                    xButton
                }.offset(x: -10)
            }
        }
    }
    var searchBar: some View {
        TextField("Search", text: $query)
            .textFieldStyle(.roundedBorder)
            .padding(.vertical)
            .onChange(of: query) { _, newValue in
                fuzzy.querySendTask = mainAsyncAfter(ms: 50) {
                    fuzzy.sendQuery(newValue)
                }
                fuzzy.lastQuerySendTask = mainAsyncAfter(ms: 500) {
                    fuzzy.sendQuery(newValue)
                }
            }
            .focused($focused, equals: .search)
            .onKeyPress(.downArrow) {
                focused = .list
                return .handled
            }
            .onKeyPress(.tab) {
                focused = .list
                return .handled
            }
    }

    var xButton: some View {
        Button(action: {
            if query.isEmpty {
                dismiss()
                appManager.lastFrontmostApp?.activate()
            } else {
                query = ""
            }
        }) {
            Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .keyboardShortcut(.cancelAction)
        .focusable(false)

    }

    var header: some View {
        HStack(spacing: 20) {
            HStack {
                Text("Name").fontWeight(fuzzy.sortField == .name ? .bold : .medium)
                sortButton(.name, defaultReverse: false)
            }
            .frame(width: 250 + 32, alignment: .leading)
            HStack {
                Text("Path").fontWeight(fuzzy.sortField == .path ? .bold : .medium)
                sortButton(.path, defaultReverse: false)
            }
            .frame(width: 300, alignment: .leading)
            HStack {
                Text("Size").fontWeight(fuzzy.sortField == .size ? .bold : .medium)
                sortButton(.size, defaultReverse: true)
            }
            .frame(width: 80, alignment: .trailing)
            HStack {
                Text("Date Modified").fontWeight(fuzzy.sortField == .date ? .bold : .medium)
                sortButton(.date, defaultReverse: true)
            }
            .frame(width: 160, alignment: .leading)

            Button(action: {
                fuzzy.sortField = .score
                fuzzy.reverseSort = true
            }) {
                Image(systemName: "flag.pattern.checkered.circle" + (fuzzy.sortField == .score ? ".fill" : ""))
                    .font(.system(size: 20))
                    .opacity(fuzzy.sortField == .score ? 1 : 0.5)
                    .help("Sort by score")
            }
            .buttonStyle(TextButton(borderColor: .clear))

        }.hfill(.leading)
    }

    @ViewBuilder
    var resultsList: some View {
        header.frame(height: 20, alignment: .leading).padding(.leading, 16)
        List(selection: $selectedResults) {
            ForEach(fuzzy.results, id: \.self) { filepath in
                row(filepath).tag(filepath.string)
            }
        }
        .onChange(of: fuzzy.results) {
            selectFirstResult()
        }
        .onChange(of: selectedResults) {
            fuzzy.computeOpenWithApps(for: selectedResults.map(\.url))
        }
        .focused($focused, equals: .list)
    }

    @ViewBuilder
    var actionButtons: some View {
        let inTerminal = appManager.frontmostAppIsTerminal

        HStack {
            openButton(inTerminal: inTerminal)
            showInFinderButton
            pasteToFrontmostAppButton(inTerminal: inTerminal)
            openInTerminalButton
            Spacer()
            openWithPickerButton
            Spacer()
            copyFilesButton.disabled(focused != .list)
            copyPathsButton
            trashButton.disabled(focused != .list)
            quicklookButton
            renameButton
        }
        .font(.system(size: 10))
        .buttonStyle(TextButton(color: .fg.warm.opacity(0.7)))
        .lineLimit(1)

    }

    @ViewBuilder
    var scriptActionButtons: some View {
        HStack {
            runThroughScriptButton
                .frame(width: 110, alignment: .leading)

            Divider().frame(height: 16)

            if scriptManager.scriptShortcuts.isEmpty {
                Text("Script hotkeys will appear here")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
            } else {
                Text("⌘⌃  +").foregroundColor(.fg.warm)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(scriptManager.scriptShortcuts.sorted(by: \.key.lastPathComponent), id: \.0.path) { script, key in
                            Button(action: {
                                _ = shellProcOut(script.path, args: selectedResults.map(\.string), env: scriptManager.shellEnv)
                            }) {
                                Text("\(key.uppercased()) ").mono(10, weight: .bold).foregroundColor(.fg.warm) + Text(script.lastPathComponent.ns.deletingPathExtension)
                            }
                        }
                    }.buttonStyle(BorderlessTextButton(color: .fg.warm.opacity(0.6)))
                }
            }
        }
        .font(.system(size: 10))
        .buttonStyle(TextButton(color: .fg.warm.opacity(0.7)))
        .lineLimit(1)
    }

    @ViewBuilder
    var openWithActionButtons: some View {
        HStack {
            openWithMenuButton
                .frame(width: 110, alignment: .leading)

            Divider().frame(height: 16)

            if fuzzy.openWithAppShortcuts.isEmpty {
                Text("Open with app hotkeys will appear here")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
            } else {
                Text("⌘⌥  +").foregroundColor(.fg.warm)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(fuzzy.openWithAppShortcuts.sorted(by: \.key.lastPathComponent), id: \.0.path) { app, key in
                            Button(action: {
                                NSWorkspace.shared.open(selectedResults.map(\.url), withApplicationAt: app, configuration: .init(), completionHandler: { _, _ in })
                            }) {
                                Text("\(key.uppercased()) ").mono(10, weight: .bold).foregroundColor(.fg.warm) + Text(app.lastPathComponent.ns.deletingPathExtension)
                            }
                        }
                    }.buttonStyle(BorderlessTextButton(color: .fg.warm.opacity(0.6)))
                }
            }
        }
        .font(.system(size: 10))
        .buttonStyle(TextButton(color: .fg.warm.opacity(0.7)))
        .lineLimit(1)
    }

    var runThroughScriptButton: some View {
        Button("⌘E Execute script") {
            focused = .executeScript
            isPresentingScriptPicker = true
        }
        .keyboardShortcut("e", modifiers: [.command])
        .help("Run the selected files through a script")
        .sheet(isPresented: $isPresentingScriptPicker) {
            ScriptPickerView(fileURLs: selectedResults.map(\.url))
                .font(.medium(13))
                .focused($focused, equals: .executeScript)
        }
    }

    var body: some View {
        VStack {
            searchSection

            resultsList
                .onKeyPress("/") {
                    focused = .search
                    return .handled
                }
                .onKeyPress(.space) {
                    guard focused == .list else {
                        return .ignored
                    }
                    quicklook()
                    return .handled
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            actionButtons
                .hfill(.leading)
                .padding(.bottom, 4)

            openWithActionButtons
                .hfill(.leading)
            scriptActionButtons
                .hfill(.leading)

            StatusBarView().hfill(.leading)
        }
        .padding()
        .onAppear {
            focused = .search
        }
        .onKeyPress(keys: Set(scriptManager.scriptShortcuts.values.map { KeyEquivalent($0) }), phases: [.down]) { keyPress in
            guard keyPress.modifiers == [.command, .control] else { return .ignored }

            guard let script = scriptManager.scriptShortcuts.first(where: { $0.value == keyPress.key.character })?.key else {
                return .ignored
            }

            _ = shellProcOut(script.path, args: selectedResults.map(\.string), env: scriptManager.shellEnv)
            return .handled
        }
        .onKeyPress(keys: Set(fuzzy.openWithAppShortcuts.values.map { KeyEquivalent($0) }), phases: [.down]) { keyPress in
            guard keyPress.modifiers == [.command, .option] else { return .ignored }

            guard let app = fuzzy.openWithAppShortcuts.first(where: { $0.value == keyPress.key.character })?.key else {
                return .ignored
            }

            NSWorkspace.shared.open(
                selectedResults.map(\.url), withApplicationAt: app, configuration: .init(),
                completionHandler: { _, _ in }
            )
            return .handled
        }
        .disabled(fuzzy.indexing)
        .if(fuzzy.indexing) { view in
            view.overlay(
                VStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                    Text(fuzzy.operation)
                        .foregroundStyle(.secondary)
                        .medium(20)
                }
                .fill()
                .background(.ultraThinMaterial)
            )
        }
    }

    func sortButton(_ sorter: SortField, defaultReverse: Bool) -> some View {
        Button(action: {
            if fuzzy.sortField == sorter {
                fuzzy.reverseSort.toggle()
            } else {
                fuzzy.sortField = sorter
                fuzzy.reverseSort = defaultReverse
            }
        }) {
            Image(systemName: "arrow.up.arrow.down")
                .symbolRenderingMode(fuzzy.sortField == sorter ? .hierarchical : .monochrome)
                .rotationEffect(.degrees(fuzzy.sortField == sorter && fuzzy.reverseSort ? 180 : 0))
                .opacity(fuzzy.sortField == sorter ? 1 : 0.5)
        }
        .buttonStyle(TextButton(borderColor: .clear))

    }

    func pasteToFrontmostApp(inTerminal: Bool) {
        if inTerminal {
            appManager.pasteToFrontmostApp(paths: selectedResults.arr, separator: " ", quoted: true)
        } else {
            appManager.pasteToFrontmostApp(
                paths: selectedResults.arr, separator: "\n", quoted: false
            )
        }
    }

    func renameFiles() {
        NSApp.mainWindow?.becomeKey()
        focus()

        guard let renamedPaths else { return }
        do {
            let renamed = try performRenameOperation(
                originalPaths: selectedResults.arr, renamedPaths: renamedPaths
            )
            fuzzy.results = fuzzy.results.map { renamed[$0] ?? $0 }
            selectedResults = selectedResults.map { renamed[$0] ?? $0 }.set
        } catch {
            log.error("Error renaming files: \(error)")
        }
        self.renamedPaths = nil
    }

    @State private var appManager = APP_MANAGER

    @State private var isPresentingRenameView = false
    @State private var renamedPaths: [FilePath]? = nil
    @State private var isPresentingScriptPicker = false

    @FocusState private var focused: FocusedField?
    @State private var isPresentingOpenWithPicker = false
    @State private var isPresentingConfirm = false
    @State private var fuzzy: FuzzyClient = FUZZY
    @State private var scriptManager: ScriptManager = SM
    @State private var query = ""
    @State private var selectedResults = Set<FilePath>()

    @Default(.suppressTrashConfirm) private var suppressTrashConfirm: Bool
    @Default(.terminalApp) private var terminalApp

    private var showInFinderButton: some View {
        Button("⌘⏎ Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(selectedResults.map(\.url))
        }
        .keyboardShortcut(.return, modifiers: [.command])
        .help("Show the selected files in Finder")
    }

    @ViewBuilder
    private var openInTerminalButton: some View {
        if let terminal = terminalApp.existingFilePath?.url {
            Button("⌘T Open in \(terminalApp.filePath?.stem ?? "Terminal")") {
                let dirs = selectedResults.map { $0.isDir ? $0.url : $0.dir.url }.uniqued
                NSWorkspace.shared.open(
                    dirs, withApplicationAt: terminal, configuration: .init(),
                    completionHandler: { _, _ in }
                )
            }
            .keyboardShortcut("t", modifiers: [.command])
            .help("Open the selected files in Terminal")
        }
    }

    private var copyFilesButton: some View {
        Button(action: copyFiles) {
            Text("⌘C Copy")
        }
        .keyboardShortcut("c", modifiers: [.command])
        .help("Copy the selected files")
    }

    private var copyPathsButton: some View {
        Button(action: copyPaths) {
            Text("⌘⇧C Copy paths")
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .help("Copy the paths of the selected files")
    }

    private var openWithMenuButton: some View {
        OpenWithMenuView(fileURLs: selectedResults.map(\.url))
            .help("Open the selected files with a specific app")
    }

    private var openWithPickerButton: some View {
        Button("") {
            focused = .openWith
            isPresentingOpenWithPicker = true
        }
        .keyboardShortcut("o", modifiers: [.command])
        .opacity(0)
        .frame(width: 0)
        .sheet(isPresented: $isPresentingOpenWithPicker) {
            OpenWithPickerView(fileURLs: selectedResults.map(\.url))
                .font(.medium(13))
                .focused($focused, equals: .openWith)
        }
    }

    private var trashButton: some View {
        Button("⌘⌫ Trash", role: .destructive) {
            if suppressTrashConfirm {
                moveToTrash()
            } else {
                isPresentingConfirm = true
            }
        }
        .keyboardShortcut(.delete, modifiers: [.command])
        .help("Move the selected files to the trash")
        .confirmationDialog(
            "Are you sure?",
            isPresented: $isPresentingConfirm
        ) {
            Button("Move to trash") {
                moveToTrash()
            }.keyboardShortcut(.defaultAction)
        }
        .dialogIcon(Image(systemName: "trash.circle.fill"))
        .dialogSuppressionToggle(isSuppressed: $suppressTrashConfirm)
    }

    private var quicklookButton: some View {
        Button(action: quicklook) {
            Text("⌘Y Quicklook")
        }
        .keyboardShortcut("y", modifiers: [.command])
        .help("Preview the selected files")
    }

    private var renameButton: some View {
        Button("⌘R Rename") {
            isPresentingRenameView = true
        }
        .sheet(isPresented: $isPresentingRenameView, onDismiss: renameFiles) {
            RenameView(originalPaths: selectedResults.arr, renamedPaths: $renamedPaths)
        }
        .keyboardShortcut("r", modifiers: [.command])
        .help("Rename the selected files")
    }

    private func openButton(inTerminal: Bool) -> some View {
        Button(action: openSelectedResults) {
            Text(inTerminal ? "⌘⇧⏎" : "⏎") + Text(" Open")
        }
        .keyboardShortcut(.return, modifiers: inTerminal ? [.command, .shift] : [])
        .help("Open the selected files with their default app")
    }

    private func pasteToFrontmostAppButton(inTerminal: Bool) -> some View {
        Button(action: { pasteToFrontmostApp(inTerminal: inTerminal) }) {
            Text(inTerminal ? "⏎" : "⌘⇧⏎")
                + Text(" Paste to \(appManager.lastFrontmostApp?.name ?? "frontmost app")")
        }
        .keyboardShortcut(.return, modifiers: inTerminal ? [] : [.command, .shift])
        .help("Paste the paths of the selected files to the frontmost app")
    }

    private func row(_ path: FilePath) -> some View {
        HStack(spacing: 20) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path.string))
                .resizable()
                .frame(width: 16, height: 16)
            Text(path.name.string)
                .frame(width: 250, alignment: .leading)
            Text(path.dir.shellString)
                .frame(width: 300, alignment: .leading)
            Text((path.fileSize() ?? 0).humanSize)
                .monospaced()
                .frame(width: 80, alignment: .trailing)
            Text((path.modificationDate ?? Date()).formatted(dateFormat))
                .monospaced()
                .frame(width: 200, alignment: .leading)
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private func selectFirstResult() {
        if let firstResult = fuzzy.results.first {
            selectedResults = [firstResult]
        } else {
            selectedResults.removeAll()
        }
    }

    private func openSelectedResults() {
        for url in selectedResults.map(\.url) {
            NSWorkspace.shared.open(url)
        }
    }

    private func copyFiles() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(selectedResults.map(\.url) as [NSPasteboardWriting])
    }

    private func copyPaths() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            appManager.frontmostAppIsTerminal
                ? selectedResults.map { $0.shellString.replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: " ")
                : selectedResults.map(\.string).joined(separator: "\n"), forType: .string
        )
    }

    private func moveToTrash() {
        var removed = Set<FilePath>()
        for path in selectedResults {
            log.info("Trashing \(path.shellString)")
            do {
                try FileManager.default.trashItem(at: path.url, resultingItemURL: nil)
                removed.insert(path)
            } catch {
                log.error("Error trashing \(path.shellString): \(error)")
            }
        }

        selectedResults.subtract(removed)
        fuzzy.results = fuzzy.results.filter { !removed.contains($0) && $0.exists }
    }

    private func quicklook() {
        QuickLooker.quicklook(urls: selectedResults.map(\.url))
    }
}

// #Preview {
//     ContentView()
// }
