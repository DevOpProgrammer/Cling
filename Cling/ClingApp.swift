//
//  Created by Alin Panaitiu on 03.02.2025.
//

import AppKit
import Combine
import Defaults
import EonilFSEvents
import Lowtech
import LowtechIndie
import Sparkle
import SwiftUI
import System

extension [String] {
    func removing(_ element: String) -> [String] {
        filter { $0 != element }
    }
}

/// Arguments minus --hidden for custom processing
var appArguments: [String] {
    CommandLine.arguments.removing("--hidden")
}

@MainActor
func cleanup() {
    // Enhanced cleanup to ensure PTY resources are freed
    FUZZY.cleanup()
    
    // Force cleanup of any remaining terminals
    FUZZY.cleanupTerminals()
    
    // Additional cleanup for any lingering processes
    cleanupOrphanedProcesses()
}

/// Clean up any orphaned PTY processes
private func cleanupOrphanedProcesses() {
    // Get current process ID
    let currentPid = ProcessInfo.processInfo.processIdentifier
    
    // Use ps to find any child processes that might be hanging
    let task = Process()
    task.launchPath = "/bin/ps"
    task.arguments = ["-o", "pid,ppid,comm", "-x"]
    
    let pipe = Pipe()
    task.standardOutput = pipe
    
    do {
        try task.run()
        task.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            let lines = output.components(separatedBy: .newlines)
            
            for line in lines {
                let components = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
                if components.count >= 3,
                   let pid = Int32(components[0]),
                   let ppid = Int32(components[1]),
                   ppid == currentPid {
                    
                    // Kill child processes that might be holding PTY resources
                    kill(pid, SIGTERM)
                    
                    // Force kill after a short delay if needed
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                        kill(pid, SIGKILL)
                    }
                }
            }
        }
    } catch {
        log.error("Failed to cleanup orphaned processes: \(error)")
    }
}

@MainActor
class AppDelegate: LowtechIndieAppDelegate, Sendable {
    static var shared: AppDelegate? { NSApp.delegate as? AppDelegate }

    var mainWindow: NSWindow? {
        NSApp.windows.first { $0.title == "Cling" }
    }
    var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.title.contains("Settings") }
    }

    override func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.disableRelaunchOnLogin()
        if !SWIFTUI_PREVIEW,
           let app = NSWorkspace.shared.runningApplications.first(where: {
               $0.bundleIdentifier == Bundle.main.bundleIdentifier
                   && $0.processIdentifier != NSRunningApplication.current.processIdentifier
           })
        {
            app.forceTerminate()
        }
        FUZZY.start()
        setupCleanup()

        // Setup periodic relaunch timer
        super.applicationDidFinishLaunching(notification)

        KM.specialKey = Defaults[.enableGlobalHotkey] ? Defaults[.showAppKey] : nil
        KM.specialKeyModifiers = Defaults[.triggerKeys]
        KM.onSpecialHotkey = { [self] in
            if let mainWindow, mainWindow.isKeyWindow {
                WM.pinned = false
                mainWindow.resignKey()
                mainWindow.resignMain()
                mainWindow.close()
                APP_MANAGER.lastFrontmostApp?.activate()
            } else {
                WM.open("main")
                focusWindow()
                focus()
            }
        }
        pub(.enableGlobalHotkey)
            .sink { change in
                KM.specialKey = change.newValue ? Defaults[.showAppKey] : nil
                KM.reinitHotkeys()
            }.store(in: &observers)
        pub(.showAppKey)
            .sink { change in
                KM.specialKey = Defaults[.enableGlobalHotkey] ? change.newValue : nil
                KM.reinitHotkeys()
            }.store(in: &observers)
        pub(.triggerKeys)
            .sink { change in
                KM.specialKeyModifiers = change.newValue
                KM.reinitHotkeys()
            }.store(in: &observers)

        UM.updater = updateController.updater

        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )

        resizeCancellable = NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)
            .compactMap { $0.object as? NSWindow }
            .filter { $0.title == "Cling" }
            .map(\.frame.size)
            .filter { $0 != WM.size }
            .throttle(for: .milliseconds(80), scheduler: RunLoop.main, latest: true)
            .sink { newSize in
                WM.size = newSize
            }

        let skipWindow = CommandLine.arguments.contains("--hidden")
        if Defaults[.showWindowAtLaunch], !skipWindow {
            WM.open("main")
            mainWindow?.becomeMain()
            mainWindow?.becomeKey()
            focus()
        } else {
            NSApp.setActivationPolicy(.accessory)
            mainWindow?.close()
        }
    }

    override func applicationDidBecomeActive(_ notification: Notification) {
        guard didBecomeActiveAtLeastOnce else {
            didBecomeActiveAtLeastOnce = true
            return
        }
//        log.debug("Became active")
        focusWindow()
        // If relaunch was postponed and now window is visible, cancel postponement
        relaunchPostponedUntil = nil
    }

    override func applicationDidResignActive(_ notification: Notification) {
//        log.debug("Resigned active")
        settingsWindow?.close()
        guard !WM.pinned else {
            mainWindow?.level = .floating
            mainWindow?.alphaValue = 0.75
            return
        }
        guard !Defaults[.keepWindowOpenWhenDefocused] else {
            return
        }
        WM.mainWindowActive = false
        mainWindow?.close()
        // If relaunch was postponed and window is now not visible, check if we should relaunch
        checkAndRelaunchIfNeeded()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        log.debug("Open URLs: \(urls)")
        handleURLs(application, urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        log.debug("Open files: \(filenames)")
        handleURLs(sender, filenames.compactMap(\.url))
    }

    func handleURLs(_ application: NSApplication, _ urls: [URL]) {
        let filePaths = urls.compactMap(\.existingFilePath)
        guard !filePaths.isEmpty else {
            application.reply(toOpenOrPrint: .failure)
            return
        }
        let id = filePaths.count == 1 ? filePaths[0].name.string : "Custom"
        FUZZY.folderFilter = FolderFilter(id: id, folders: filePaths, key: nil)
        application.reply(toOpenOrPrint: .success)
    }

    func focusWindow() {
        mainWindow?.makeKeyAndOrderFront(nil)
        mainWindow?.orderFrontRegardless()
        mainWindow?.becomeMain()
        mainWindow?.becomeKey()
        mainAsyncAfter(0.1) {
            self.mainWindow?.makeKeyAndOrderFront(nil)
            self.mainWindow?.orderFrontRegardless()
            self.mainWindow?.becomeMain()
            self.mainWindow?.becomeKey()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let oldpid = FileManager.default.contents(atPath: PIDFILE.string)?.s?.i32 else {
            return
        }
        log.debug("Killing old process: \(oldpid)")
        kill(oldpid, SIGKILL)
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !SWIFTUI_PREVIEW else {
            return true
        }

//        log.debug("Reopened")

        if let mainWindow {
            mainWindow.orderFrontRegardless()
            mainWindow.becomeMain()
            mainWindow.becomeKey()
            focus()
        } else {
            WM.open("main")
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }

    func setupCleanup() {
        signal(SIGINT) { _ in
            cleanup()
            exit(0)
        }
        signal(SIGTERM) { _ in
            cleanup()
            exit(0)
        }
        signal(SIGKILL) { _ in
            cleanup()
            exit(0)
        }
    }

    @objc func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window.title == "Cling" {
            WM.mainWindowActive = false
            APP_MANAGER.lastFrontmostApp?.activate()

            // If relaunch was already postponed, push another 5 minutes to avoid quitting just after window close
            if relaunchPostponedUntil != nil {
                postponeRelaunch(by: 5 * MINUTE_FACTOR, reason: "after window close")
            }
        }
    }
    @objc func windowDidBecomeMain(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window.title == "Cling" {
            WM.mainWindowActive = true

            window.alphaValue = 1
            window.level = .normal
            window.titlebarAppearsTransparent = true
            window.styleMask = [
                .fullSizeContentView, .closable, .resizable, .miniaturizable, .titled,
                .nonactivatingPanel,
            ]
            window.isMovableByWindowBackground = true
            WM.size = window.frame.size
        }
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        cleanup()
    }

    private var relaunchTimer: Timer?
    private var relaunchPostponedUntil: Date?

    private var resizeCancellable: AnyCancellable?


    // Add periodic PTY cleanup without full restart
    private func schedulePeriodicCleanup() {
        Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in // Every 30 minutes
            mainActor {
                // Perform lightweight PTY cleanup
                FUZZY.cleanupTerminals()
                self.cleanupOrphanedProcesses()
            }
        }
    }

    private func postponeRelaunch(by interval: TimeInterval, reason: String? = nil) {
        relaunchPostponedUntil = Date().addingTimeInterval(interval)
        scheduleRelaunchTimer(interval: interval)
        if let reason { debug("Relaunch postponed by \(interval) seconds: \(reason)") }
    }

    private func attemptRelaunch() {
        if WM.mainWindowActive {
            postponeRelaunch(by: 30 * MINUTE_FACTOR, reason: "after window is active")
        } else {
            debug("Relaunching app")
            relaunchApp()
        }
    }

    private func checkAndRelaunchIfNeeded() {
        if let postponed = relaunchPostponedUntil, Date() >= postponed {
            debug("Relaunching app after inactivity")
            relaunchApp()
        }
    }

    private func relaunchApp() {
        cleanup()
        _ = shell(
            command: "while /bin/ps -o pid -p \(ProcessInfo.processInfo.processIdentifier) >/dev/null 2>/dev/null; do /bin/sleep 0.1; done; /bin/sleep 0.5; /usr/bin/open '\(Bundle.main.bundlePath)' --args --hidden",
            wait: false
        )
        exit(0)
    }

}

@MainActor @Observable
class WindowManager {
    static let DEFAULT_SIZE = CGSize(width: 1010, height: 850)

    var windowToOpen: String?
    var size = DEFAULT_SIZE
    var pinned = false

    var mainWindowActive = false {
        didSet {
            guard !pinned, !Defaults[.keepWindowOpenWhenDefocused] else {
                return
            }
            FUZZY.suspended = !mainWindowActive
        }
    }

    func open(_ window: String) {
        if window == "main", NSApp.windows.first(where: { $0.title == "Cling" }) != nil {
            focus()
            AppDelegate.shared?.focusWindow()
            if windowToOpen != nil {
                windowToOpen = nil
            }
            return
        }
        windowToOpen = window
    }
}
@MainActor let WM = WindowManager()

import IOKit.ps

func batteryLevel() -> Double {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources: NSArray = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
    else { return 1 }

    for ps in sources {
        guard let info: NSDictionary = IOPSGetPowerSourceDescription(snapshot, ps as CFTypeRef)?.takeUnretainedValue(),
              let capacity = info[kIOPSCurrentCapacityKey] as? Int,
              let max = info[kIOPSMaxCapacityKey] as? Int
        else { continue }

        return (max > 0) ? (Double(capacity) / Double(max)) : Double(capacity)
    }

    return 1
}

@main
struct ClingApp: App {
    @Environment(\.openWindow) var openWindow
    @Environment(\.dismiss) var dismiss

    var body: some Scene {
        Window("Cling", id: "main") {
            ContentView()
                .frame(minWidth: WindowManager.DEFAULT_SIZE.width, minHeight: 300)
                .ignoresSafeArea()
                .environmentObject(envState)
        }
        .defaultSize(width: WindowManager.DEFAULT_SIZE.width, height: WindowManager.DEFAULT_SIZE.height)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .help) {
                Button("Check for updates (current version: v\(Bundle.main.version))") {
                    UM.updater?.checkForUpdates()
                }
                .keyboardShortcut("U", modifiers: [.command])
            }
        }
        .onChange(of: wm.windowToOpen) {
            guard let window = wm.windowToOpen, !SWIFTUI_PREVIEW else {
                return
            }
            if window == "main", NSApp.windows.first(where: { $0.title == "Cling" }) != nil {
                return
            }

            openWindow(id: window)
            focus()
            NSApp.keyWindow?.orderFrontRegardless()
            wm.windowToOpen = nil
        }

        Settings {
            SettingsView()
                .frame(minWidth: 600, minHeight: 600)
                .environmentObject(envState)
        }
        .defaultSize(width: 600, height: 600)
    }

    @State private var wm = WM

    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

}
