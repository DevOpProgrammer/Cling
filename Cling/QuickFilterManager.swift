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
            Text("Save Quick Filter").font(.headline)
            TextField("Name", text: $id)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    guard !query.trimmed.isEmpty, !id.isEmpty else { return }
                    dismiss()
                }
            TextField("Query", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    guard !query.trimmed.isEmpty, !id.isEmpty else { return }
                    dismiss()
                }
            HStack {
                Text("Hotkey: ")
                Text("⌥ +").bold()
                DynamicKey(key: $key, recording: $env.recording, allowedKeys: .ALL_KEYS)
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
        .padding()

    }
}

struct QuickFilterSaverView: View {
    var body: some View {
        saveQuickFilterButton
            .sheet(isPresented: $isSaving, onDismiss: save) {
                QuickFilterAddSheet(id: $filterID, query: $fuzzy.query, key: $filterKey)
            }
            .onChange(of: filterID) { filterKey = Self.getFilterKey(id: filterID) }
    }

    @State private var fuzzy = FUZZY
    @State private var isSaving = false
    @State private var filterID = ""
    @State private var filterKey: SauceKey = getFilterKey()

    @Default(.quickFilters) private var quickFilters: [QuickFilter]

    private var saveQuickFilterButton: some View {
        Button(action: { isSaving = true }) {
            Image(systemName: "plus.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .focusable(false)
    }

    private static func getFilterKey(id: String? = nil) -> SauceKey {
        let usedKeys = Set(Defaults[.quickFilters].compactMap(\.key))

        guard let id else {
            for char in "abcdefghijklmnopqrstuvwxyz" {
                if !usedKeys.contains(char) {
                    return SauceKey(rawValue: String(char)) ?? .section
                }
            }
            return .section // Fallback
        }

        for char in id.lowercased() {
            if !usedKeys.contains(char) {
                return SauceKey(rawValue: String(char)) ?? .section
            }
        }
        return .section // Fallback
    }

    private func save() {
        let query = fuzzy.query.trimmed
        guard !query.isEmpty, !filterID.isEmpty else {
            return
        }

        // Check for existing filter with the same key and set its key to nil
        let key = filterKey.lowercasedChar.first
        let filter = QuickFilter(id: filterID, query: query, key: key)
        if let key, let existingFilter = quickFilters.first(where: { $0.key == key }) {
            quickFilters = quickFilters.without([existingFilter, filter]) + [existingFilter.withKey(nil), filter]
            fuzzy.quickFilter = filter
            return
        }

        quickFilters = quickFilters.without(filter) + [filter]
        fuzzy.quickFilter = filter
    }

}
