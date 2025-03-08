//
//  ContentView.swift
//  Cling
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

let dateFormat = Date.FormatStyle
    .dateTime.year(.padded(4)).month().day(.twoDigits)
    .hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits)

enum FocusedField {
    case search, list, openWith, executeScript
}

struct ContentView: View {
    @Environment(\.dismiss) var dismiss
    @State var wm = WM

    var pinButton: some View {
        Button(action: {
            wm.pinned.toggle()
        }) {
            Image(systemName: wm.pinned ? "pin.circle.fill" : "pin.circle")
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .keyboardShortcut(".")
        .focusable(false)
        .help(wm.pinned ? "Unpin window (⌘.)" : "Pin window to keep it on top of other windows (⌘.)")
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            pinButton.offset(x: -10, y: 5)
            content
                .onAppear {
                    focused = .search
                    mainAsyncAfter(ms: 100) {
                        focused = .search
                    }
                }
                .disabled(!wm.mainWindowActive)
        }
    }

    var content: some View {
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
                    QuickLooker.quicklook(
                        urls: selectedResults.count > 1 ? selectedResults.map(\.url) : results.map(\.url),
                        selectedItemIndex: selectedResults.count == 1 ? (results.firstIndex(of: selectedResults.first!) ?? 0) : 0
                    )
                    return .handled
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contextMenu {
                    RightClickMenu(selectedResults: $selectedResults)
                }

            if wm.mainWindowActive {
                ActionButtons(selectedResults: $selectedResults, focused: $focused)
                    .hfill(.leading)
                    .padding(.bottom, 4)

                OpenWithActionButtons(selectedResults: selectedResults)
                    .hfill(.leading)
                ScriptActionButtons(selectedResults: selectedResults, focused: $focused)
                    .hfill(.leading)

                StatusBarView().hfill(.leading).padding(.top, 10)
            }
        }
        .padding([.top, .leading, .trailing])
        .padding(.bottom, 4)
        .onKeyPress(keys: Set(scriptManager.scriptShortcuts.values.map { KeyEquivalent($0) }), phases: [.down]) { keyPress in
            guard scriptManager.process == nil, keyPress.modifiers == [.command, .control] else { return .ignored }

            guard let script = scriptManager.scriptShortcuts.first(where: { $0.value == keyPress.key.character })?.key else {
                return .ignored
            }
            scriptManager.run(script: script, args: selectedResults.map(\.string))

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

    @FocusState private var focused: FocusedField?

    @State private var appManager = APP_MANAGER
    @State private var renamedPaths: [FilePath]? = nil
    @State private var fuzzy: FuzzyClient = FUZZY
    @State private var scriptManager: ScriptManager = SM
    @State private var selectedResults = Set<FilePath>()

    @Default(.folderFilters) private var folderFilters
    @Default(.quickFilters) private var quickFilters

    private var folderFilterPicker: some View {
        Picker(selection: $fuzzy.folderFilter) {
            ForEach(folderFilters, id: \.self) { filter in
                (
                    Text("\(filter.id)\n") +
                        Text(filter.folders.map(\.shellString).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                )
                .tag(filter as FolderFilter?)
                .help("Searches in \(filter.folders.map(\.shellString).joined(separator: ", "))")
                .ifLet(filter.key) { view, key in
                    view.keyboardShortcut(KeyEquivalent(key), modifiers: [.option])
                }
                .truncationMode(.tail)
            }

            if let filter = fuzzy.folderFilter, !folderFilters.contains(filter) {
                Divider()
                (
                    Text("\(filter.id)\n") +
                        Text(filter.folders.map(\.shellString).joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                )
                .tag(filter as FolderFilter?)
                .help("Searches in \(filter.folders.map(\.shellString).joined(separator: ", "))")
                .truncationMode(.tail)
            }
        } label: { Text("Folder filter") }
            .labelsHidden()
            .pickerStyle(.inline)
    }
    private var quickFilterPicker: some View {
        Picker(selection: $fuzzy.quickFilter) {
            ForEach(quickFilters, id: \.self) { filter in
                (
                    Text("\(filter.id)\n") +
                        Text(filter.query)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                )
                .tag(filter as QuickFilter?)
                .help("Searches with query: \(filter.query)")
                .ifLet(filter.key) { view, key in
                    view.keyboardShortcut(KeyEquivalent(key), modifiers: [.option])
                }
                .truncationMode(.tail)
            }

            if let filter = fuzzy.quickFilter, !quickFilters.contains(filter) {
                Divider()
                (
                    Text("\(filter.id)\n") +
                        Text(filter.query)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                )
                .tag(filter as QuickFilter?)
                .help("Searches with query: \(filter.query)")
                .truncationMode(.tail)
            }
        } label: { Text("Quick filter") }
            .labelsHidden()
            .pickerStyle(.inline)
    }
    private var filterPicker: some View {
        Menu {
            Section(header: Text("Folder filter")) {
                folderFilterPicker
            }
            Section(header: Text("Quick filter")) {
                quickFilterPicker
            }
            Button("All files") {
                fuzzy.folderFilter = nil
                fuzzy.quickFilter = nil
            }
            .help("Searches all indexed files without any filters")
            .keyboardShortcut(.escape, modifiers: [.option])
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "folder.fill")
                if let filter = fuzzy.quickFilter {
                    Text(filter.id)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let filter = fuzzy.folderFilter {
                    Text(" in ")
                        .foregroundStyle(.secondary)
                    Text(filter.id)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(BorderlessTextButton())
        .fixedSize()
        .onChange(of: fuzzy.folderFilter) {
            fuzzy.sendQuery(fuzzy.query)
        }
        .onChange(of: fuzzy.quickFilter) {
            fuzzy.sendQuery(fuzzy.query)
        }
    }

    private func handleFilterKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard keyPress.modifiers == [.option] else { return .ignored }
        guard keyPress.key != .escape else {
            fuzzy.folderFilter = nil
            fuzzy.quickFilter = nil
            return .handled
        }

        if let filter = folderFilters.first(where: { $0.keyEquivalent == keyPress.key }) {
            fuzzy.folderFilter = filter
            return .handled
        }
        if let filter = quickFilters.first(where: { $0.keyEquivalent == keyPress.key }) {
            fuzzy.quickFilter = filter
            return .handled
        }
        return .ignored
    }

    private var searchSection: some View {
        HStack {
            filterPicker
            ZStack(alignment: .trailing) {
                searchBar
                    .onKeyPress(
                        keys: Set(folderFilters.compactMap(\.keyEquivalent) + quickFilters.compactMap(\.keyEquivalent) + [.escape]),
                        phases: [.down], action: handleFilterKeyPress
                    )
                HStack {
                    if !fuzzy.query.isEmpty {
                        QuickFilterSaverView()
                            .keyboardShortcut("s")
                    }
                    Text("press / to focus")
                        .round(10)
                        .foregroundStyle(.secondary)
                    xButton
                }.offset(x: -10)
            }
        }
    }

    private var searchBar: some View {
        TextField("Search", text: $fuzzy.query)
            .textFieldStyle(.roundedBorder)
            .padding(.vertical)
            .onChange(of: fuzzy.query) { _, newValue in
                fuzzy.querySendTask = mainAsyncAfter(ms: 50) {
                    fuzzy.sendQuery(newValue)
                }
//                fuzzy.lastQuerySendTask = mainAsyncAfter(ms: 500) {
//                    fuzzy.sendQuery(newValue)
//                }
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

    private var xButton: some View {
        Button(action: {
            if fuzzy.query.isEmpty {
                dismiss()
                appManager.lastFrontmostApp?.activate()
            } else {
                fuzzy.query = ""
                focused = .search
            }
        }) {
            Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .keyboardShortcut(.cancelAction)
        .focusable(false)

    }

    @State private var windowManager = WM
    @State private var nameWidth: CGFloat = 250
    @State private var pathWidth: CGFloat = 300

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 20) {
            HStack {
                Text("Name").fontWeight(fuzzy.sortField == .name ? .bold : .medium)
                sortButton(.name, defaultReverse: false)
            }
            .frame(width: nameWidth + 32, alignment: .leading)
            HStack {
                Text("Path").fontWeight(fuzzy.sortField == .path ? .bold : .medium)
                sortButton(.path, defaultReverse: false)
            }
            .frame(width: pathWidth, alignment: .leading)
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

    private var results: [FilePath] {
        fuzzy.noQuery ? fuzzy.recents : fuzzy.results
    }

    @ViewBuilder
    private var resultsList: some View {
        header.frame(height: 20, alignment: .leading).padding(.leading, 16)
        List(selection: $selectedResults) {
            ForEach(results, id: \.self) { filepath in
                row(filepath).tag(filepath.string)
                    .contentShape(Rectangle())
                    .draggable(filepath.url)
                    .onDoubleClick {
                        NSApp.deactivate()
                        NSWorkspace.shared.open(filepath.url)
                    }
            }
        }
        .onChange(of: results) {
            selectFirstResult()
        }
        .onChange(of: selectedResults) {
            fuzzy.computeOpenWithApps(for: selectedResults.map(\.url))
        }
        .onKeyPress(.tab) {
            focused = .search
            return .handled
        }
        .focused($focused, equals: .list)
        .onAppear {
            let additionalWidth = windowManager.size.width - WindowManager.DEFAULT_SIZE.width
            nameWidth = 250 + (additionalWidth * (1.0 / 3.0))
            pathWidth = 300 + (additionalWidth * (2.0 / 3.0))
        }
        .onChange(of: windowManager.size) {
            let additionalWidth = windowManager.size.width - WindowManager.DEFAULT_SIZE.width
            nameWidth = 250 + (additionalWidth * (1.0 / 3.0))
            pathWidth = 300 + (additionalWidth * (2.0 / 3.0))
        }
    }

    @ViewBuilder
    private func sortButton(_ sorter: SortField, defaultReverse: Bool) -> some View {
        let action = {
            if fuzzy.sortField == sorter {
                fuzzy.reverseSort.toggle()
            } else {
                fuzzy.sortField = sorter
                fuzzy.reverseSort = defaultReverse
            }
        }
        Button(action: action) {
            Image(systemName: "arrow.up.arrow.down")
                .symbolRenderingMode(fuzzy.sortField == sorter ? .hierarchical : .monochrome)
                .rotationEffect(.degrees(fuzzy.sortField == sorter && fuzzy.reverseSort ? 180 : 0))
                .opacity(fuzzy.sortField == sorter ? 1 : 0.5)
        }
        .buttonStyle(TextButton(borderColor: .clear))
//        .keyboardShortcut(KeyEquivalent(sorter.key), modifiers: [.shift])
    }

    private func row(_ path: FilePath) -> some View {
        HStack(spacing: 20) {
            Image(nsImage: path.memoz.icon)
                .resizable()
                .frame(width: 16, height: 16)
            Text(path.name.string)
                .frame(width: nameWidth, alignment: .leading)
            Text(path.dir.shellString)
                .frame(width: pathWidth, alignment: .leading)
            Text(path.memoz.humanizedFileSize)
                .monospaced()
                .frame(width: 80, alignment: .trailing)
            Text((path.memoz.modificationDate ?? Date()).formatted(dateFormat))
                .monospaced()
                .frame(width: 200, alignment: .leading)
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private func selectFirstResult() {
        if let firstResult = results.first {
            selectedResults = [firstResult]
        } else {
            selectedResults.removeAll()
        }
    }
}

extension FilePath {
    var humanizedFileSize: String {
        (fileSize() ?? 0).humanSize
    }
    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: string)
    }
}
// #Preview {
//     ContentView()
// }
