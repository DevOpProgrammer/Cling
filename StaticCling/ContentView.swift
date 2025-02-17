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

let dateFormat = Date.FormatStyle
    .dateTime.year(.padded(4)).month().day(.twoDigits)
    .hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits)

enum FocusedField {
    case search, list, openWith, executeScript
}

struct ContentView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var km = KM

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
                    QuickLooker.quicklook(urls: selectedResults.map(\.url))
                    return .handled
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            ActionButtons(selectedResults: $selectedResults, focused: $focused)
                .hfill(.leading)
                .padding(.bottom, 4)

            OpenWithActionButtons(selectedResults: selectedResults)
                .hfill(.leading)
            ScriptActionButtons(selectedResults: selectedResults, focused: $focused)
                .hfill(.leading)

            StatusBarView().hfill(.leading).padding(.top, 10)
        }
        .padding([.top, .leading, .trailing])
        .padding(.bottom, 4)
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

    @FocusState private var focused: FocusedField?

    @State private var appManager = APP_MANAGER
    @State private var renamedPaths: [FilePath]? = nil
    @State private var fuzzy: FuzzyClient = FUZZY
    @State private var scriptManager: ScriptManager = SM
    @State private var query = ""
    @State private var selectedResults = Set<FilePath>()

    @Default(.terminalApp) private var terminalApp

    private var searchSection: some View {
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
    private var searchBar: some View {
        TextField("Search", text: $query)
            .textFieldStyle(.roundedBorder)
            .padding(.vertical)
            .onChange(of: query) { _, newValue in
                fuzzy.querySendTask = mainAsyncAfter(ms: 150) {
                    fuzzy.sendQuery(newValue)
                }
                fuzzy.lastQuerySendTask = mainAsyncAfter(ms: 1000) {
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

    private var xButton: some View {
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

    @ViewBuilder
    private var resultsList: some View {
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
            Image(nsImage: NSWorkspace.shared.icon(forFile: path.string))
                .resizable()
                .frame(width: 16, height: 16)
            Text(path.name.string)
                .frame(width: nameWidth, alignment: .leading)
            Text(path.dir.shellString)
                .frame(width: pathWidth, alignment: .leading)
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
}

// #Preview {
//     ContentView()
// }
