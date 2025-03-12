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
            HStack(spacing: 1) {
                Image(systemName: wm.pinned ? "pin.circle.fill" : "pin.circle")
                Text(wm.pinned ? "Unpin" : "Pin")
            }
        }
        .font(.round(10))
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .keyboardShortcut(".")
        .focusable(false)
        .help(wm.pinned ? "Unpin window (⌘.)" : "Pin window to keep it on top of other windows (⌘.)")
    }

    var quitButton: some View {
        Button(action: {
            NSApp.terminate(nil)
        }) {
            HStack(spacing: 1) {
                Image(systemName: "xmark.circle.fill")
                Text("Quit")
            }
        }
        .font(.round(10))
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .focusable(false)
        .help("Quit Cling (⌘Q)")
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack {
                pinButton
                quitButton
            }
            .offset(x: -10, y: 5)
            content
                .onAppear {
                    focused = .search
                    mainAsyncAfter(ms: 100) {
                        focused = .search
                    }
                }
                .onChange(of: focused) {
                    if !fuzzy.hasFullDiskAccess {
                        focused = nil
                    }
                }
                .disabled(!wm.mainWindowActive)
        }
    }

    var content: some View {
        VStack {
            searchSection
                .onKeyPress(
                    keys: Set(folderFilters.compactMap(\.keyEquivalent) + quickFilters.compactMap(\.keyEquivalent) + [.escape]),
                    phases: [.down], action: handleFilterKeyPress
                )

            resultsList
                .onKeyPress("/", phases: [.down]) { keyPress in
                    guard keyPress.modifiers.isEmpty else { return .ignored }
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
                .onKeyPress(
                    keys: Set(folderFilters.compactMap(\.keyEquivalent) + quickFilters.compactMap(\.keyEquivalent) + [.escape]),
                    phases: [.down], action: handleFilterKeyPress
                )
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

                    Text("Press **`\(triggerKeys.readableStr) + \(showAppKey.character)`** to show/hide Cling")
                        .foregroundStyle(.secondary)
                        .opacity(0.7)
                        .padding(.top, 10)

                }
                .fill()
                .background(.ultraThinMaterial)
            )
        }
        .if(!fuzzy.hasFullDiskAccess) { view in
            view.overlay(
                VStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                    Text("Waiting for Full Disk Access permissions to start indexing")
                        .foregroundStyle(.secondary)
                        .medium(20)
                    Button("Open System Preferences") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }

                    Text("Press **`\(triggerKeys.readableStr) + \(showAppKey.character)`** to show/hide Cling")
                        .foregroundStyle(.secondary)
                        .opacity(0.7)
                        .padding(.top, 10)

                }
                .fill()
                .background(.ultraThinMaterial)
            )
        }
    }
    @Default(.triggerKeys) private var triggerKeys
    @Default(.showAppKey) private var showAppKey

    @FocusState private var focused: FocusedField?

    @State private var appManager = APP_MANAGER
    @State private var renamedPaths: [FilePath]? = nil
    @State private var fuzzy: FuzzyClient = FUZZY
    @State private var scriptManager: ScriptManager = SM
    @State private var selectedResults = Set<FilePath>()

    @Default(.folderFilters) private var folderFilters
    @Default(.quickFilters) private var quickFilters

    private func handleFilterKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard keyPress.modifiers == [.option] else { return .ignored }
        guard keyPress.key != .escape else {
            fuzzy.folderFilter = nil
            fuzzy.quickFilter = nil
            focused = .search
            return .handled
        }

        if let filter = folderFilters.first(where: { $0.keyEquivalent == keyPress.key }) {
            fuzzy.folderFilter = filter
            focused = .search
            return .handled
        }
        if let filter = quickFilters.first(where: { $0.keyEquivalent == keyPress.key }) {
            fuzzy.quickFilter = filter
            focused = .search
            return .handled
        }
        return .ignored
    }

    @State private var isAddingQuickFilter = false
    @State private var filterID = ""
    @State private var filterKey: SauceKey = .escape

    private var searchSection: some View {
        HStack {
            FilterPicker()
                .help("Quick Filters: narrow down results without typing often used queries")

            ZStack(alignment: .trailing) {
                searchBar
                HStack {
                    Text("press / to focus")
                        .round(10)
                        .foregroundStyle(.secondary)
                    xButton
                    if !fuzzy.query.isEmpty {
                        QuickFilterEditorView(isPresented: $isAddingQuickFilter, filterID: $filterID, filterKey: $filterKey, isEditing: .false)
                            .keyboardShortcut("s")
                            .help("Save current query as a Quick Filter (⌘S)")
                    }
                }.offset(x: -10)
            }
        }.sheet(isPresented: $isAddingQuickFilter, onDismiss: { saveQuickFilter(id: filterID, query: fuzzy.query.trimmed, key: filterKey) }) {
            QuickFilterAddSheet(id: $filterID, query: $fuzzy.query, key: $filterKey)
        }
    }

    private var searchBar: some View {
        TextField("Search", text: $fuzzy.query)
            .textFieldStyle(.roundedBorder)
            .padding(.vertical)
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
                sortButton(.name, defaultReverse: false).keyboardShortcut("1", modifiers: [.control])
                    .help("Sort by name (Control-1)")
            }
            .frame(width: nameWidth + 32, alignment: .leading)
            HStack {
                Text("Path").fontWeight(fuzzy.sortField == .path ? .bold : .medium)
                sortButton(.path, defaultReverse: false).keyboardShortcut("2", modifiers: [.control])
                    .help("Sort by path (Control-2)")
            }
            .frame(width: pathWidth, alignment: .leading)
            HStack {
                Text("Size").fontWeight(fuzzy.sortField == .size ? .bold : .medium)
                sortButton(.size, defaultReverse: true).keyboardShortcut("3", modifiers: [.control])
                    .help("Sort by size (Control-3)")
            }
            .frame(width: 80, alignment: .trailing)
            HStack {
                Text("Date Modified").fontWeight(fuzzy.sortField == .date ? .bold : .medium)
                sortButton(.date, defaultReverse: true).keyboardShortcut("4", modifiers: [.control])
                    .help("Sort by date modified (Control-4)")
            }
            .frame(width: 160, alignment: .leading)

            Button(action: {
                fuzzy.sortField = .score
                fuzzy.reverseSort = true
            }) {
                Image(systemName: "flag.pattern.checkered.circle" + (fuzzy.sortField == .score ? ".fill" : ""))
                    .font(.system(size: 20))
                    .opacity(fuzzy.sortField == .score ? 1 : 0.5)
            }
            .buttonStyle(TextButton(borderColor: .clear))
            .keyboardShortcut("0", modifiers: [.control])
            .help("Sort by score (Control-0)")

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
