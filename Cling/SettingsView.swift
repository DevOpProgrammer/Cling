import Defaults
import LaunchAtLogin
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
    @Default(.keepWindowOpenWhenDefocused) private var keepWindowOpenWhenDefocused
    @Default(.maxResultsCount) private var maxResultsCount
    @Default(.enableGlobalHotkey) private var enableGlobalHotkey
    @Default(.showAppKey) private var showAppKey
    @Default(.triggerKeys) private var triggerKeys
    @Default(.searchScopes) private var searchScopes
    @Default(.fasterSearchLessOptimalResults) private var fasterSearchLessOptimalResults
    @Default(.externalVolumes) private var externalVolumes

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
            LaunchAtLogin.Toggle()

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
            Toggle(isOn: $keepWindowOpenWhenDefocused) {
                (
                    Text("Keep window open when the app is in background")
                        + Text("\nDon't hide the window when clicking outside the app or when focusing another app")
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

                        Divider()
                        VolumeListView()
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

                    Button(action: { showHelp.toggle() }) {
                        Image(systemName: "questionmark.circle").foregroundColor(.secondary)
                    }
                    .sheet(isPresented: $showHelp) {
                        VStack(spacing: 5) {
                            HStack {
                                Button(action: { showHelp = false }) {
                                    Image(systemName: "xmark")
                                        .font(.heavy(7))
                                        .foregroundColor(.bg.warm)
                                }
                                .buttonStyle(FlatButton(color: .fg.warm.opacity(0.6), circle: true, horizontalPadding: 5, verticalPadding: 5))
                                .padding(.top, 8).padding(.leading, 8)
                                Spacer()
                            }

                            IgnoreHelpText().padding()
                        }
                        .frame(width: 500)
                    }.buttonStyle(BorderlessTextButton())

                    Button("Edit Ignore File") {
                        NSWorkspace.shared.open([fsignore.url], withApplicationAt: editorApp.fileURL ?? "/Applications/TextEdit.app".fileURL!, configuration: .init(), completionHandler: { _, _ in })
                    }.truncationMode(.middle)
                }

                Toggle(isOn: $fasterSearchLessOptimalResults) {
                    (
                        Text("Faster search, with less optimal results")
                            + Text("\nUses a more speed oriented algorithm but may return less accurate results")
                            .round(11, weight: .regular).foregroundColor(.secondary)
                    ).fixedSize()
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

    @State private var showHelp = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    @Default(.editorApp) private var editorApp
    @Default(.terminalApp) private var terminalApp
}

struct IgnoreHelpText: View {
    var body: some View {
        ScrollView {
            Text("""
            **Pattern syntax:**

            1. **Wildcards**: You can use asterisks (`*`) as wildcards to match multiple characters or directories at any level. For example, `*.jpg` will match all files with the .jpg extension, such as `image.jpg` or `photo.jpg`. Similarly, `*.pdf` will match any PDF files.

            2. **Directory names**: You can specify directories in patterns by ending the pattern with a slash (/). For instance, `images/` will match all files or directories named "images" or residing within an "images" directory.

            3. **Negation**: Prefixing a pattern with an exclamation mark (!) negates the pattern, instructing the app to include files that would otherwise be excluded. For example, `!important.pdf` would include a file named "important.pdf" even if it satisfies other exclusion patterns.

            4. **Comments**: You can include comments by adding a hash symbol (`#`) at the beginning of the line. These comments are ignored by the app and serve as helpful annotations for humans.

            *More complex patterns can be found in the [gitignore documentation](https://git-scm.com/docs/gitignore#_pattern_format).*

            **Examples:**

            `# Ignore all hidden files starting with a period character (dotfiles)`
            `.*`
            ` `
            `# Ignore all files and subfolders of app bundles`
            `*.app/*`
            ` `
            `# Exclude all files in a "DontSearch" directory`
            `DontSearch/`
            ` `
            `# Exclude all files with the `.temp` extension`
            `*.temp`
            ` `
            `# Exclude invoices (PDF files starting with "invoice-")`
            `invoice-*.pdf`
            ` `
            `# Exclude a specific file named "confidential.pdf"`
            `confidential.pdf`
            ` `
            `# Include a specific file named "important.pdf" even if it matches other patterns`
            `!important.pdf`
            """)
            .foregroundColor(.secondary)
        }
    }
}

import System

let VOLUMES: FilePath = "/Volumes"

extension URL {
    var volumeName: String? {
        (try? resourceValues(forKeys: [.volumeNameKey]))?.volumeName
    }
    var isLocalVolume: Bool {
        (try? resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true
    }
    var isRootVolume: Bool {
        (try? resourceValues(forKeys: [.volumeIsRootFileSystemKey]))?.volumeIsRootFileSystem == true
    }
    var isVolume: Bool {
        guard let vals = try? resourceValues(forKeys: [.isVolumeKey, .volumeIsRootFileSystemKey]) else { return false }
        return vals.isVolume == true && vals.volumeIsRootFileSystem == false
    }
}

extension FilePath: @retroactive Comparable {
    public static func < (lhs: FilePath, rhs: FilePath) -> Bool {
        lhs.string < rhs.string
    }

    @MainActor
    var isOnExternalVolume: Bool {
        let volume = FUZZY.externalVolumes
            .filter { self.starts(with: $0) }
            .max(by: \.components.count)
        guard let volume else { return false }
        return !volume.url.isLocalVolume
    }

    var enabledVolumeBinding: Binding<Bool> {
        Binding(
            get: { !Defaults[.disabledVolumes].contains(self) },
            set: { enabled in
                if enabled {
                    Defaults[.disabledVolumes].removeAll { $0 == self }
                } else {
                    Defaults[.disabledVolumes].append(self)
                }
            }
        )
    }
}

struct VolumeListView: View {
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                (
                    Text("External Volumes")
                        + Text("\nIndex external or network drives")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                ).fixedSize()
            }

            if !fuzzy.externalVolumes.isEmpty {
                List {
                    ForEach(fuzzy.externalVolumes, id: \.string) { volume in
                        volumeItem(volume)
                    }
                }
            }
        }
    }

    func volumeItem(_ volume: FilePath) -> some View {
        Toggle(isOn: volume.enabledVolumeBinding) {
            HStack {
                Image(systemName: "externaldrive")
                Text(volume.name.string)
                Spacer()
                Text(volume.shellString)
                    .monospaced()
                    .foregroundColor(.secondary)
                    .truncationMode(.middle)
            }
        }

    }

    @State private var fuzzy = FUZZY

    @Default(.disabledVolumes) private var disabledVolumes
}
