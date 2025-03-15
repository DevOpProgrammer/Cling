import Defaults
import Foundation
import Lowtech
import SwiftUI
import System

struct FilterPicker: View {
    @Default(.folderFilters) private var folderFilters
    @Default(.quickFilters) private var quickFilters
    @State private var fuzzy: FuzzyClient = FUZZY
    @ObservedObject private var km = KM

    private var enabledVolumes: [FilePath]? {
        fuzzy.enabledVolumes.isEmpty ? nil : fuzzy.enabledVolumes
    }

    @ViewBuilder
    private var volumePicker: some View {
        if let enabledVolumes {
            let volumes = ([FilePath.root] + enabledVolumes).enumerated().map { $0 }
            Picker(selection: $fuzzy.volumeFilter) {
                Text("Volumes").round(11).foregroundColor(.secondary).selectionDisabled()
                ForEach(volumes, id: \.1) { i, volume in
                    filterItem(volume, key: i > 9 ? nil : i.s.first)
                }
            } label: { Text("Volume filter") }
                .labelsHidden()
                .pickerStyle(.inline)
        }
    }

    private var folderFilterPicker: some View {
        Picker(selection: $fuzzy.folderFilter) {
            Text("Folder filters").round(11).foregroundColor(.secondary).selectionDisabled()
            ForEach(folderFilters, id: \.self) { filter in
                filterItem(filter)
            }

            if let filter = fuzzy.folderFilter, !folderFilters.contains(filter) {
                Divider()
                filterItem(filter)
            }
        } label: { Text("Folder filter") }
            .labelsHidden()
            .pickerStyle(.inline)
    }

    private func filterItem(_ filter: FilePath, key: Character?) -> some View {
        (
            Text((filter == .root ? (filter.url.volumeName ?? "Root") : filter.name.string) + "\n") +
                Text(filter == .root ? "/" : filter.shellString)
                .foregroundStyle(.secondary)
                .font(.caption)
        )
        .tag(filter as FilePath?)
        .help("Searches inside: \(filter.shellString)")
        .ifLet(key) { view, key in
            view.keyboardShortcut(KeyEquivalent(key), modifiers: [.option])
        }
        .truncationMode(.tail)
    }

    private func filterItem(_ filter: QuickFilter) -> some View {
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

    private func filterItem(_ filter: FolderFilter) -> some View {
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

    @ViewBuilder private func filterButtons(_ filter: QuickFilter, action: String = "Edit") -> some View {
        Button(action) {
            isEditingFilter = action == "Edit"
            originalFilterID = filter.id
            lastQuery = fuzzy.query
            fuzzy.query = filter.query
            filterID = filter.id
            filterKey = filter.key.flatMap { SauceKey(rawValue: $0.lowercased()) } ?? .escape
            isAddingQuickFilter = true
        }
        Button("Delete") {
            Defaults[.quickFilters] = Defaults[.quickFilters].without(filter)
            if fuzzy.quickFilter == filter {
                fuzzy.quickFilter = nil
            }
        }
    }

    @State private var lastQuery = ""

    @ViewBuilder private func filterButtons(_ filter: FolderFilter, action: String = "Edit") -> some View {
        Button(action) {
            isEditingFilter = action == "Edit"
            originalFilterID = filter.id
            filterID = filter.id
            filterFolders = filter.folders
            filterKey = filter.key.flatMap { SauceKey(rawValue: $0.lowercased()) } ?? .escape
            isAddingFolderFilter = true
        }
        Button("Delete") {
            Defaults[.folderFilters] = Defaults[.folderFilters].without(filter)
            if fuzzy.folderFilter == filter {
                fuzzy.folderFilter = nil
            }
        }
    }

    @ViewBuilder private var folderFilterEditMenu: some View {
        Text("Folder filters").round(11).foregroundColor(.secondary).selectionDisabled()
        ForEach(folderFilters, id: \.self) { filter in
            Menu { filterButtons(filter) } label: { filterItem(filter) }

            if let filter = fuzzy.folderFilter, !folderFilters.contains(filter) {
                Divider()
                Menu { filterButtons(filter, action: "Save") } label: { filterItem(filter) }
            }
        }
    }
    private var quickFilterPicker: some View {
        Picker(selection: $fuzzy.quickFilter) {
            Text("Quick filters").round(11).foregroundColor(.secondary).selectionDisabled()
            ForEach(quickFilters, id: \.self) { filter in
                filterItem(filter)
            }

            if let filter = fuzzy.quickFilter, !quickFilters.contains(filter) {
                Divider()
                filterItem(filter)
            }
        } label: { Text("Quick filter") }
            .labelsHidden()
            .pickerStyle(.inline)
    }

    @ViewBuilder private var quickFilterEditMenu: some View {
        Text("Quick filters").round(11).foregroundColor(.secondary).selectionDisabled()
        ForEach(quickFilters, id: \.self) { filter in
            Menu { filterButtons(filter) } label: { filterItem(filter) }
        }

        if let filter = fuzzy.quickFilter, !quickFilters.contains(filter) {
            Divider()
            Menu { filterButtons(filter, action: "Save") } label: { filterItem(filter) }
        }
    }

    @State private var isAddingQuickFilter = false
    @State private var isAddingFolderFilter = false
    @State private var isEditingFilter = false
    @State private var originalFilterID = ""
    @State private var filterID = ""
    @State private var filterKey: SauceKey = .escape
    @State private var filterFolders: [FilePath] = []

    var body: some View {
        menu
            .sheet(isPresented: $isAddingQuickFilter, onDismiss: {
                saveQuickFilter(id: filterID, query: fuzzy.query.trimmed, key: filterKey, originalID: originalFilterID)
                filterID = ""
                originalFilterID = ""
                fuzzy.query = lastQuery
                lastQuery = ""
                isEditingFilter = false
            }) {
                QuickFilterAddSheet(id: $filterID, query: $fuzzy.query, key: $filterKey)
            }
            .sheet(isPresented: $isAddingFolderFilter, onDismiss: {
                saveFolderFilter(id: filterID, folders: filterFolders, key: filterKey, originalID: originalFilterID)
                filterID = ""
                originalFilterID = ""
                filterFolders = []
                isEditingFilter = false
            }) {
                FolderFilterAddSheet(id: $filterID, folders: $filterFolders, key: $filterKey)
            }
    }

    var menu: some View {
        Menu {
            if km.lalt || km.ralt {
                QuickFilterEditorView(label: "New Quick Filter", isPresented: $isAddingQuickFilter, filterID: $filterID, filterKey: $filterKey, isEditing: $isEditingFilter)
                FolderFilterEditorView(label: "New Folder Filter", isPresented: $isAddingFolderFilter, filterID: $filterID, filterKey: $filterKey, isEditing: $isEditingFilter)
                Divider()
                folderFilterEditMenu
                Divider()
                quickFilterEditMenu
            } else {
                folderFilterPicker
                quickFilterPicker
                volumePicker

                Button("All files") {
                    fuzzy.folderFilter = nil
                    fuzzy.quickFilter = nil
                    fuzzy.volumeFilter = nil
                }
                .help("Searches all indexed files without any filters")
                .keyboardShortcut(.escape, modifiers: [.option])

                Divider()
                Text("To edit filters, hold ⌥ Option while opening this menu")
                    .foregroundStyle(.secondary)
                    .round(11)
                    .disabled(true)
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "folder.fill")
                if let filter = fuzzy.quickFilter {
                    Text(filter.id)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if fuzzy.folderFilter != nil || fuzzy.volumeFilter != nil {
                    Text(" in ")
                        .foregroundStyle(.secondary)
                    if let filter = fuzzy.volumeFilter {
                        Text("\(Image(systemName: "externaldrive")) \(filter.name.string)")
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if fuzzy.folderFilter != nil {
                            Text("❯").foregroundStyle(.secondary)
                        }
                    }
                    if let filter = fuzzy.folderFilter {
                        Text(filter.id)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
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
}

@MainActor
func saveQuickFilter(id: String, query: String, key: SauceKey, originalID: String = "") {
    guard !query.isEmpty, !id.isEmpty else {
        return
    }

    guard key != .escape else {
        let filter = QuickFilter(id: id, query: query, key: nil)
        let originalFilter = Defaults[.quickFilters].first { $0.id == originalID }

        Defaults[.quickFilters] = Defaults[.quickFilters].without(originalFilter ?? filter) + [filter]
        FUZZY.quickFilter = filter

        return
    }

    // Check for existing filter with the same key and set its key to nil
    let key = key.lowercasedChar.first
    let filter = QuickFilter(id: id, query: query, key: key)
    let originalFilter = Defaults[.quickFilters].first { $0.id == originalID }
    // if let key, let existingFilter = Defaults[.folderFilters].first(where: { $0.key == key }) {
    //     Defaults[.folderFilters] = Defaults[.folderFilters].without(existingFilter) + [existingFilter.withKey(nil)]
    // }
    if let key, let existingFilter = Defaults[.quickFilters].first(where: { $0.key == key }), existingFilter != originalFilter {
        Defaults[.quickFilters] = Defaults[.quickFilters].without([existingFilter, originalFilter ?? filter]) + [existingFilter.withKey(nil), filter]
        FUZZY.quickFilter = filter
        return
    }

    Defaults[.quickFilters] = Defaults[.quickFilters].without(originalFilter ?? filter) + [filter]
    FUZZY.quickFilter = filter
}

@MainActor
func saveFolderFilter(id: String, folders: [FilePath], key: SauceKey, originalID: String = "") {
    guard !folders.isEmpty, !id.isEmpty else {
        return
    }

    guard key != .escape else {
        let filter = FolderFilter(id: id, folders: folders, key: nil)
        let originalFilter = Defaults[.folderFilters].first { $0.id == originalID }

        Defaults[.folderFilters] = Defaults[.folderFilters].without(originalFilter ?? filter) + [filter]
        FUZZY.folderFilter = filter

        return
    }

    // Check for existing filter with the same key and set its key to nil
    let key = key.lowercasedChar.first
    let filter = FolderFilter(id: id, folders: folders, key: key)
    let originalFilter = Defaults[.folderFilters].first { $0.id == originalID }
    // if let key, let existingFilter = Defaults[.quickFilters].first(where: { $0.key == key }) {
    //     Defaults[.quickFilters] = Defaults[.quickFilters].without(existingFilter) + [existingFilter.withKey(nil)]
    // }
    if let key, let existingFilter = Defaults[.folderFilters].first(where: { $0.key == key }), existingFilter != originalFilter {
        Defaults[.folderFilters] = Defaults[.folderFilters].without([existingFilter, originalFilter ?? filter]) + [existingFilter.withKey(nil), filter]
        FUZZY.folderFilter = filter
        return
    }

    Defaults[.folderFilters] = Defaults[.folderFilters].without(originalFilter ?? filter) + [filter]
    FUZZY.folderFilter = filter
}
