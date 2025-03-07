import Defaults
import Lowtech
import LowtechIndie
import SwiftUI

extension Binding<Int> {
    var d: Binding<Double> {
        .init(
            get: { Double(wrappedValue) },
            set: { wrappedValue = Int($0) }
        )
    }
}

let envState = EnvState()

struct SettingsView: View {
    @ObservedObject var updateManager = UM

    @Default(.checkForUpdates) private var checkForUpdates
    @Default(.updateCheckInterval) private var updateCheckInterval
    @Default(.showWindowAtLaunch) private var showWindowAtLaunch
    @Default(.maxResultsCount) private var maxResultsCount
    @Default(.enableGlobalHotkey) private var enableGlobalHotkey
    @Default(.showAppKey) private var showAppKey
    @Default(.triggerKeys) private var triggerKeys
    @Default(.searchScopes) private var searchScopes

    private func selectApp(type: String, onCompletion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select \(type) App"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = "/Applications".fileURL

        if panel.runModal() == .OK, let url = panel.url {
            onCompletion(url)
        }
    }

    @State private var showShellAlert = false
    @State private var shellIntegrationMessage = ""
    @EnvironmentObject var env: EnvState

    var body: some View {
        Form {
            HStack {
                (
                    Text("Text editor")
                        + Text("\nUsed for editing text files")
                        .round(11, weight: .regular).foregroundColor(.secondary)
                ).fixedSize()
                Spacer()
                Button(editorApp.filePath?.stem ?? "TextEdit") {
                    selectApp(type: "Text Editor") { url in
                        editorApp = url.path
                    }
                }.truncationMode(.middle)
            }
            HStack {
                (
                    Text("Terminal")
                        + Text("\nUsed for running shell commands and opening folders")
                        .round(11, weight: .regular).foregroundColor(.secondary)
                ).fixedSize()
                Spacer()
                Button(terminalApp.filePath?.stem ?? "Terminal") {
                    selectApp(type: "Terminal") { url in
                        terminalApp = url.path
                    }
                }.truncationMode(.middle)
            }

            HStack {
                (
                    Text("Shell Integration")
                        + Text("\nIntegrates Cling with your shell as a `cling` function")
                        .round(11, weight: .regular).foregroundColor(.secondary)
                ).fixedSize()
                Spacer()
                Button("Install") {
                    shellIntegrationMessage = ShellIntegration.addClingFunction()
                    showShellAlert = true
                }
                .truncationMode(.middle)
                .alert("Shell Integration", isPresented: $showShellAlert, actions: {}) {
                    Text(shellIntegrationMessage)
                }
            }

            Toggle(isOn: $showWindowAtLaunch) {
                (
                    Text("Show window at launch")
                        + Text("\nShow the main window when Cling is first launched")
                        .round(11, weight: .regular).foregroundColor(.secondary)
                ).fixedSize()
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Global hotkey", isOn: $enableGlobalHotkey)
                HStack {
                    DirectionalModifierView(triggerKeys: $triggerKeys)
                        .disabled(!enableGlobalHotkey)
                    Text("+").heavy(12)
                    DynamicKey(key: $showAppKey, recording: $env.recording, allowedKeys: .ALL_KEYS)
                }
                .disabled(!enableGlobalHotkey)
                .opacity(enableGlobalHotkey ? 1 : 0.5)
            }

            Section(header: Text("Search")) {
                Section(header: Text("Search scopes")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: SearchScope.root.binding) {
                            (
                                Text("System")
                                    + Text("\nSearches system files and applications\nFolders: `/System`, `/Applications`, `/Library`, `/usr`, `/bin`, `/sbin`, `/opt`")
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            ).fixedSize()
                        }
                        Toggle(isOn: SearchScope.home.binding) {
                            (
                                Text("Home")
                                    + Text("\nSearches the user home directory (`~`) excluding `~/Library`")
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            ).fixedSize()
                        }
                        Toggle(isOn: SearchScope.library.binding) {
                            (
                                Text("Library")
                                    + Text("\nSearches the user library directory (`~/Library`)")
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                            ).fixedSize()
                        }
                    }.padding(.leading, 10)
                }

                HStack {
                    (
                        Text("Max Results")
                            + Text("\nMaximum number of results to show in the search results")
                            .round(11, weight: .regular).foregroundColor(.secondary)
                    ).fixedSize()
                    Spacer()
                    Slider(value: $maxResultsCount.d, in: 1 ... 100, step: 1) {
                        Text("\(Int(maxResultsCount))")
                    }.frame(width: 150)
                }

                HStack {
                    (
                        Text("Ignore File")
                            + Text("\nUses gitignore syntax for excluding files from the index")
                            .round(11, weight: .regular).foregroundColor(.secondary)
                    ).fixedSize()
                    Spacer()
                    Button("Edit Ignore File") {
                        NSWorkspace.shared.open([fsignore.url], withApplicationAt: editorApp.fileURL ?? "/Applications/TextEdit.app".fileURL!, configuration: .init(), completionHandler: { _, _ in })
                    }.truncationMode(.middle)
                }
            }

            if let updater = updateManager.updater {
                Section(header: Text("Updates *(current version: `v\(Bundle.main.version)`)*")) {
                    Toggle("Automatically check for updates", isOn: $checkForUpdates)
                    Picker("Update check interval", selection: $updateCheckInterval) {
                        Text("Daily").tag(UpdateCheckInterval.daily.rawValue)
                        Text("Every 3 days").tag(UpdateCheckInterval.everyThreeDays.rawValue)
                        Text("Weekly").tag(UpdateCheckInterval.weekly.rawValue)
                    }.pickerStyle(.segmented)

                    GentleUpdateView(updater: updater)
                }
            }

        }
        .formStyle(.grouped)
        .padding()
        .alert(isPresented: $showErrorAlert) {
            Alert(
                title: Text("Error"), message: Text(errorMessage),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    @Default(.editorApp) private var editorApp
    @Default(.terminalApp) private var terminalApp
}
