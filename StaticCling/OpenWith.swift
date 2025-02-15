import Lowtech
import SwiftUI

struct OpenWithMenuView: View {
    let fileURLs: [URL]

    var body: some View {
        Menu("⌘O Open with...   ") {
            let apps = commonApplications(for: fileURLs).sorted(by: \.lastPathComponent)
            ForEach(apps, id: \.path) { app in
                Button(action: {
                    NSWorkspace.shared.open(
                        fileURLs, withApplicationAt: app, configuration: .init(),
                        completionHandler: { _, _ in }
                    )
                }) {
                    SwiftUI.Image(nsImage: icon(for: app))
                    Text(app.lastPathComponent.ns.deletingPathExtension)
                }
            }
        }
    }

}

struct OpenWithPickerView: View {
    let fileURLs: [URL]
    @Environment(\.dismiss) var dismiss
    @State private var fuzzy: FuzzyClient = FUZZY

    func openWithApp(_ app: URL) {
        NSWorkspace.shared.open(
            fileURLs, withApplicationAt: app, configuration: .init(),
            completionHandler: { _, _ in }
        )
        dismiss()
    }

    func appButton(_ app: URL) -> some View {
        Button(action: { openWithApp(app) }) {
            HStack {
                SwiftUI.Image(nsImage: icon(for: app))
                Text(app.lastPathComponent.ns.deletingPathExtension)

                if let shortcut = fuzzy.openWithAppShortcuts[app] {
                    Spacer()
                    Text(String(shortcut).uppercased()).monospaced().bold().foregroundColor(.secondary)
                }
            }.hfill()
        }
    }

    var appList: some View {
        ForEach(fuzzy.commonOpenWithApps, id: \.path) { app in
            appButton(app)
                .buttonStyle(FlatButton(color: .bg.primary.opacity(0.4), textColor: .primary))
                .ifLet(fuzzy.openWithAppShortcuts[app]) {
                    $0.keyboardShortcut(KeyEquivalent($1), modifiers: [])
                }
        }.focusable(false)
    }

    var body: some View {
        VStack {
            appList
        }
        .padding()
    }
}

func icon(for app: URL) -> NSImage {
    let i = NSWorkspace.shared.icon(forFile: app.path)
    i.size = NSSize(width: 14, height: 14)
    return i
}

extension URL {
    var bundleIdentifier: String? {
        guard let bundle = Bundle(url: self) else {
            return nil
        }
        return bundle.bundleIdentifier
    }
}
