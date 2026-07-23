import SwiftUI
import AppKit
import AppUpdater
import UserNotifications

// MARK: - Window delegate that quits the app on close

// Handles BOTH the window delegate path (windowShouldClose) and the target-action
// path (close button override) so one of them is guaranteed to fire regardless of
// how SwiftUI wires up the close button internally.
final class TerminatingWindowDelegate: NSObject, NSWindowDelegate {
    weak var originalDelegate: (any NSWindowDelegate)?
    weak var controller: AppController?

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        handleClose()
        return false  // never let the normal close/hide path run
    }

    // MARK: Target-action backup (close button override)

    @objc func closeWindow(_ sender: Any?) {
        handleClose()
    }

    // MARK: Private

    private func handleClose() {
        guard let ctrl = controller else { quit(); return }
        guard confirmQuit(for: ctrl) else { return }
        quit(ctrl)
    }

    private func quit(_ ctrl: AppController? = nil) {
        // Capture before stop() — it nils out shellProcess/logStreamProcess itself
        // (via disconnectShell()/stopLogStream()), so grabbing them after would just
        // hand terminateWithChildren a nil reference and silently reap nothing.
        let shellProc   = ctrl?.shellProcess
        let logProc     = ctrl?.logStreamProcess
        let forwardProc = ctrl?.forwardProcess
        let buildProc   = ctrl?.buildProcess
        let mountProc   = ctrl?.mountProcess
        ctrl?.buildTask?.cancel()
        ctrl?.stop()
        terminateWithChildren(shellProc)
        terminateWithChildren(logProc)
        terminateWithChildren(forwardProc)
        terminateWithChildren(buildProc)
        terminateWithChildren(mountProc)
        // Ask the SSH multiplexer master to exit too (ControlPersist=60 would otherwise
        // leave it running for a minute after the last client disconnects). Fire-and-forget:
        // waiting here would block the whole app quit if the control socket doesn't
        // respond, which is exactly what left vbound "running in the background" before.
        let mux = Process()
        mux.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        mux.arguments     = ["ssh", "-O", "exit",
                             "-o", "ControlPath=\(AppController.sshControlPath)",  // #8
                             "mobile@127.0.0.1"]
        try? mux.run()
        // Same fire-and-forget reasoning as the mux exit above — waiting on umount here
        // would block quit if the mount is wedged, and a leftover mount just fails the
        // next mountVphone() call cleanly rather than causing any real harm.
        let umount = Process()
        umount.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        umount.arguments     = ["umount", AppController.mountPath]
        try? umount.run()
        NSApp.terminate(nil)
    }

    // MARK: Delegate forwarding — pass every other call to the original SwiftUI delegate

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard !super.responds(to: aSelector) else { return nil }
        return originalDelegate
    }
}

// MARK: - App delegate for guaranteed process cleanup on all quit paths
// applicationWillTerminate fires for every quit route (⌘Q, dock, close button,
// force-quit, etc.) so processes are always cleaned up even if TerminatingWindowDelegate
// somehow does not fire (e.g. macOS 26 SwiftUI window management changes).
final class AppDelegate: NSObject, NSApplicationDelegate {
    // ⌘Q and Dock → Quit land here, going straight through NSApp.terminate rather than
    // the window's close button / windowShouldClose — without this, the single most
    // common quit gesture skipped the build-in-progress and vphone-booted-by-us warnings
    // entirely, silently interrupting either one with no chance to cancel.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let ctrl = AppController.current else { return .terminateNow }
        return confirmQuit(for: ctrl) ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let ctrl = AppController.current else { return }
        // Same capture-before-stop ordering as TerminatingWindowDelegate.quit() — this
        // is the path a Dock "Quit" or ⌘Q takes (bypassing that delegate entirely), so
        // it needs the same fix independently rather than relying on the other path
        // having already run first.
        let shellProc   = ctrl.shellProcess
        let logProc     = ctrl.logStreamProcess
        let forwardProc = ctrl.forwardProcess
        let buildProc   = ctrl.buildProcess
        let mountProc   = ctrl.mountProcess
        ctrl.buildTask?.cancel()
        ctrl.stop()
        terminateWithChildren(shellProc)
        terminateWithChildren(logProc)
        terminateWithChildren(forwardProc)
        terminateWithChildren(buildProc)
        terminateWithChildren(mountProc)
        let mux = Process()
        mux.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        mux.arguments     = ["ssh", "-O", "exit",
                             "-o", "ControlPath=\(AppController.sshControlPath)",
                             "mobile@127.0.0.1"]
        try? mux.run()
        let umount = Process()
        umount.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        umount.arguments     = ["umount", AppController.mountPath]
        try? umount.run()
    }
}

// Shared by both quit paths — the window's close button (TerminatingWindowDelegate) and
// ⌘Q/Dock Quit (AppDelegate.applicationShouldTerminate) — so the same warnings and the
// same graceful-shutdown side effect apply regardless of which gesture triggered the quit.
func confirmQuit(for ctrl: AppController) -> Bool {
    if ctrl.buildPhase.isRunning {
        let alert = NSAlert()
        alert.messageText     = "Build in progress"
        alert.informativeText = "vbound is currently building, uploading, or installing. " +
                                "Quitting now will interrupt it."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
    }

    if ctrl.bootedVphone && ctrl.vphoneDetected {
        let alert = NSAlert()
        alert.messageText     = "Shut down vphone?"
        alert.informativeText = "vphone was started by vbound and is still running. " +
                                "Quitting will shut it down gracefully."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Shut Down & Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        if let udid = ctrl.vphoneUDID {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments     = ["pymobiledevice3", "diagnostics", "shutdown", "--udid", udid]
            p.environment   = ctrl.enrichedEnvironment
            try? p.run()
            p.waitUntilExit()
        }
    }

    return true
}

// `sshpass`/`pymobiledevice3` wrappers can fork a real child (e.g. sshpass execs ssh as a
// separate process) that never receives SIGTERM when we only signal the wrapper we tracked —
// that orphaned child is exactly what survives after quitting and shows up as vbound still
// "running in the background". Reap any children explicitly alongside the wrapper itself.
func terminateWithChildren(_ process: Process?) {
    guard let process, process.isRunning else { return }
    let pid = process.processIdentifier
    process.terminate()
    let reap = Process()
    reap.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    reap.arguments = ["-TERM", "-P", "\(pid)"]
    try? reap.run()
}

// MARK: - App entry point

extension Notification.Name {
    static let checkForUpdates       = Notification.Name("vbound.checkForUpdates")
    static let requestShutdownVphone = Notification.Name("vbound.requestShutdownVphone")
    static let focusLogFilter        = Notification.Name("vbound.focusLogFilter")
    static let showCommandPalette    = Notification.Name("vbound.showCommandPalette")
    static let showOnboardingChecklist = Notification.Name("vbound.showOnboardingChecklist")
    static let showLogs              = Notification.Name("vbound.showLogs")
    static let showShell             = Notification.Name("vbound.showShell")
    static let clearConsole          = Notification.Name("vbound.clearConsole")
    static let copyVisibleOutput     = Notification.Name("vbound.copyVisibleOutput")
    static let exportVisibleOutput   = Notification.Name("vbound.exportVisibleOutput")
    static let jumpToLatest          = Notification.Name("vbound.jumpToLatest")
}

@main
struct vboundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var manager = AppController()
    @AppStorage("vphoneCliPath") private var vphoneCliPath = NSHomeDirectory() + "/vphone-cli"
    @AppStorage("unboundPath")   private var unboundPath   = NSHomeDirectory() + "/Developer/loader-ios"
    @AppStorage("unboundPluginsPath") private var unboundPluginsPath = NSHomeDirectory() + "/Developer/unbound-plugins"
    @AppStorage("autoCheckForUpdates") private var autoCheckForUpdates = true
    @AppStorage("updateCheckIntervalHours") private var updateCheckIntervalHours = 24
    @AppStorage("logFilterRegex") private var logFilterRegex = false
    @AppStorage("logRelativeTimestamps") private var logRelativeTimestamps = false
    @StateObject private var appUpdater: AppUpdater = {
        let updater = AppUpdater(owner: "unbound-app", repo: "vbound")
        #if DEBUG
        if let mockURL = Bundle.main.url(forResource: "releases.mock", withExtension: "json") {
            updater.provider = MockReleaseProvider(source: .fileURL(mockURL))
        }
        updater.skipCodeSignValidation = true
        #endif
        return updater
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(manager)
                .environmentObject(appUpdater)
                .task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    #if !DEBUG
                    if autoCheckForUpdates { appUpdater.check() }
                    // Polls in short increments rather than sleeping for the whole interval
                    // in one shot — a single long Task.sleep would ignore a Settings change
                    // to a shorter interval until the original (possibly week-long) sleep
                    // happened to finish on its own.
                    var elapsedSeconds: Double = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        elapsedSeconds += 60
                        guard elapsedSeconds >= Double(updateCheckIntervalHours) * 3600 else { continue }
                        elapsedSeconds = 0
                        guard !Task.isCancelled, autoCheckForUpdates else { continue }
                        appUpdater.check()
                    }
                    #endif
                }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 720, height: 560)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About vbound") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Divider()
                Button("Check for Updates…") {
                    appUpdater.check()
                    NotificationCenter.default.post(name: .checkForUpdates, object: nil)
                }
                .keyboardShortcut("u", modifiers: .command)
                Divider()
                Button("View on GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/unbound-app/vbound")!)
                }
                Button("Report an Issue…") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/unbound-app/vbound/issues/new")!)
                }
                Button("What's New…") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/unbound-app/vbound/releases")!)
                }
                Divider()
                Button("Show Setup Checklist…") {
                    NotificationCenter.default.post(name: .showOnboardingChecklist, object: nil)
                }
            }
            CommandMenu("Actions") {
                // Mirrors the status strip's merged Boot/Stop button — the toolbar
                // collapsed these into one toggle, so the menu should read the same way
                // instead of still offering them as two separately-enabled items.
                Button(manager.vphoneDetected ? "Shut Down vphone…" : "Boot vphone") {
                    if manager.vphoneDetected {
                        NotificationCenter.default.post(name: .requestShutdownVphone, object: nil)
                    } else {
                        manager.bootVphone(in: vphoneCliPath)
                    }
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!manager.vphoneDetected && !AppController.pathValid(vphoneCliPath))

                Button(manager.buildPhase.isRunning && manager.activeBuildTarget == .tweak ? "Cancel Build" : "Build Tweak") {
                    manager.toggleTweakBuild(in: unboundPath)
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(manager.buildPhase.isRunning
                          ? manager.activeBuildTarget != .tweak
                          : !AppController.pathValid(unboundPath))

                Button(manager.buildPhase.isRunning && manager.activeBuildTarget == .plugins ? "Cancel Addons Build" : "Build Addons") {
                    manager.toggleAddonsBuild(in: unboundPluginsPath)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(manager.buildPhase.isRunning
                          ? manager.activeBuildTarget != .plugins
                          : !AppController.pathValid(unboundPluginsPath))

                Button(manager.isStreaming ? "Stop Log Stream" : "Start Log Stream") {
                    if manager.isStreaming { manager.stopLogStream() } else { manager.startLogStream() }
                }
                .keyboardShortcut("l", modifiers: .command)

                Button(manager.isShellConnected ? "Disconnect Shell" : "Connect Shell") {
                    if manager.isShellConnected { manager.disconnectShell() } else { manager.connectShell() }
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Launch Discord") {
                    manager.launchDiscord()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!manager.vphoneDetected)

                Divider()

                Button("Command Palette…") {
                    NotificationCenter.default.post(name: .showCommandPalette, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandMenu("Console") {
                Button("Show Logs") {
                    NotificationCenter.default.post(name: .showLogs, object: nil)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Show Shell") {
                    NotificationCenter.default.post(name: .showShell, object: nil)
                }
                .keyboardShortcut("2", modifiers: .command)

                Divider()

                Button("Find in Logs") {
                    NotificationCenter.default.post(name: .focusLogFilter, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Toggle("Use Regular Expression", isOn: $logFilterRegex)
                Toggle("Use Relative Timestamps", isOn: $logRelativeTimestamps)

                Divider()

                Button("Jump to Latest") {
                    NotificationCenter.default.post(name: .jumpToLatest, object: nil)
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                Button("Copy Visible Output") {
                    NotificationCenter.default.post(name: .copyVisibleOutput, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Export Visible Output…") {
                    NotificationCenter.default.post(name: .exportVisibleOutput, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Clear Console") {
                    NotificationCenter.default.post(name: .clearConsole, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Divider()

                Menu("Send Control Character") {
                    Button("Interrupt — Control-C") { manager.sendShellControlBytes([0x03]) }
                    Button("End of File — Control-D") { manager.sendShellControlBytes([0x04]) }
                    Button("Suspend — Control-Z") { manager.sendShellControlBytes([0x1A]) }
                    Button("Clear Screen — Control-L") {
                        manager.sendShellControlBytes([0x0C])
                        manager.shellBuffer.reset()
                        manager.shellLines = manager.shellBuffer.lines
                    }
                    Divider()
                    Button("Escape") { manager.sendShellControlBytes([0x1B]) }
                    Button("Tab") { manager.sendShellControlBytes([0x09]) }
                    Button("Up Arrow") { manager.sendShellControlBytes([0x1B, 0x5B, 0x41]) }
                    Button("Down Arrow") { manager.sendShellControlBytes([0x1B, 0x5B, 0x42]) }
                }
                .disabled(!manager.isShellConnected)
            }
        }

        Settings {
            SettingsView()
                .environment(manager)
        }
    }
}
