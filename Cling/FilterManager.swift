import Defaults
import Foundation
import Lowtech
import SwiftUI
import System

struct QuickFilterAddSheet: View {
    @EnvironmentObject var env: EnvState

    @Binding var id: String
    @Binding var query: String
    @Binding var key: SauceKey

    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack {
            Text("New Quick Filter").font(.headline)
            HStack {
                TextField("Name", text: $id)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        guard !query.trimmed.isEmpty, !id.isEmpty else { return }
                        dismiss()
                    }.padding(.trailing, 8)
                Text("Hotkey: ")
                Text("⌥ +").bold()
                DynamicKey(key: $key, recording: $env.recording, allowedKeys: .ALL_KEYS)
            }
            TextField("Query", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    guard !query.trimmed.isEmpty, !id.isEmpty else { return }
                    dismiss()
                }

            HStack {
                Button("Cancel") {
                    id = ""
                    dismiss()
                }
                Button("Save") { dismiss() }
                    .disabled(query.trimmed.isEmpty || id.isEmpty)
            }
        }
        .onExitCommand {
            id = ""
            dismiss()
        }

        .padding()

    }
}

struct QuickFilterEditorView: View {
    var label: String? = nil

    var body: some View {
        newQuickFilterButton
            .onChange(of: filterID) {
                guard !isEditing else { return }
                filterKey = getFilterKey(id: filterID)
            }
    }

    @State private var fuzzy = FUZZY
    @Binding var isPresented: Bool
    @Binding var filterID: String
    @Binding var filterKey: SauceKey
    @Binding var isEditing: Bool

    private var newQuickFilterButton: some View {
        Button(action: { isPresented = true }) {
            if let label {
                Text(label)
            } else {
                Image(systemName: "plus.circle.fill")
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .focusable(false)
    }
}

struct FolderFilterEditorView: View {
    var label: String? = nil

    var body: some View {
        newFolderFilterButton
            .onChange(of: filterID) {
                guard !isEditing else { return }
                filterKey = getFilterKey(id: filterID)
            }
    }

    @Binding var isPresented: Bool
    @Binding var filterID: String
    @Binding var filterKey: SauceKey
    @Binding var isEditing: Bool

    private var newFolderFilterButton: some View {
        Button(action: { isPresented = true }) {
            if let label {
                Text(label)
            } else {
                Image(systemName: "plus.circle.fill")
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .focusable(false)
    }
}

extension FilePath: @retroactive Identifiable {
    public var id: String { string }
}

struct FolderFilterAddSheet: View {
    @EnvironmentObject var env: EnvState

    @Binding var id: String
    @Binding var folders: [FilePath]
    @Binding var key: SauceKey

    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack {
            Text("New Folder Filter").font(.headline)
            HStack {
                TextField("Name", text: $id)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        guard !folders.isEmpty, !id.isEmpty else { return }
                        dismiss()
                    }
                    .padding(.trailing, 8)
                Text("Hotkey: ")
                Text("⌥ +").bold()
                DynamicKey(key: $key, recording: $env.recording, allowedKeys: .ALL_KEYS)
            }

            VStack(alignment: .leading) {
                ForEach(folders) { folder in
                    HStack {
                        Text(folder.shellString)
                            .mono(12)
                            .hfill(.leading)
                        Button(action: { folders.removeAll(where: { $0 == folder }) }) {
                            Image(systemName: "minus.circle.fill")
                        }.buttonStyle(FlatButton(color: .clear, textColor: .red.opacity(0.7)))
                    }
                }
                Button(action: addFolder) {
                    Label("Add folder", systemImage: "plus")
                }
            }
            .hfill(.leading)
            .roundbg(verticalPadding: folders.isEmpty ? 0 : 8, horizontalPadding: folders.isEmpty ? 0 : 8, color: .primary.opacity(folders.isEmpty ? 0 : 0.05))
            .padding(.bottom)

            HStack {
                Button("Cancel") {
                    id = ""
                    dismiss()
                }
                Button("Save") { dismiss() }
                    .disabled(folders.isEmpty || id.isEmpty)
            }
        }
        .onExitCommand {
            id = ""
            dismiss()
        }
        .padding()
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        panel.begin { response in
            if response == .OK, let path = panel.url?.existingFilePath, !folders.contains(path) {
                folders = folders + [path]
            }
        }
    }
}

func getFilterKey(id: String? = nil) -> SauceKey {
    guard let id else {
        return .escape
    }

    let usedKeys = Set(Defaults[.quickFilters].compactMap(\.key) + Defaults[.folderFilters].compactMap(\.key))

    for char in id.lowercased() {
        if !usedKeys.contains(char), let key = SauceKey(rawValue: String(char)) {
            return key
        }
    }
    return .escape
}
