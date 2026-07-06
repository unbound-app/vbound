import SwiftUI
import AppKit
import AppUpdater

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
        ctrl?.buildTask?.cancel()
        ctrl?.stop()
        terminateWithChildren(shellProc)
        terminateWithChildren(logProc)
        terminateWithChildren(forwardProc)
        terminateWithChildren(buildProc)
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
        ctrl.buildTask?.cancel()
        ctrl.stop()
        terminateWithChildren(shellProc)
        terminateWithChildren(logProc)
        terminateWithChildren(forwardProc)
        terminateWithChildren(buildProc)
        let mux = Process()
        mux.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        mux.arguments     = ["ssh", "-O", "exit",
                             "-o", "ControlPath=\(AppController.sshControlPath)",
                             "mobile@127.0.0.1"]
        try? mux.run()
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
    static let checkForUpdates      = Notification.Name("vbound.checkForUpdates")
    static let requestShutdownVphone = Notification.Name("vbound.requestShutdownVphone")
    static let focusLogFilter        = Notification.Name("vbound.focusLogFilter")
}

@main
struct vboundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var manager = AppController()
    @AppStorage("vphoneCliPath") private var vphoneCliPath = NSHomeDirectory() + "/vphone-cli"
    @AppStorage("unboundPath")   private var unboundPath   = NSHomeDirectory() + "/Developer/loader-ios"
    @AppStorage("autoCheckForUpdates") private var autoCheckForUpdates = true
    @AppStorage("updateCheckIntervalHours") private var updateCheckIntervalHours = 24
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
        .commands {
            // vbound is a single fixed-size panel bound to one AppController instance
            // (shared via .environment(manager)) — a second window from the default
            // WindowGroup "New Window" command would drive the *same* controller, and
            // WindowAccessor's configureWindow would silently steal manager.ourWindow
            // out from under the first window the next time it ran.
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

                Button(manager.buildPhase.isRunning ? "Cancel Build" : "Build Tweak") {
                    if manager.buildPhase.isRunning {
                        manager.cancelBuild()
                    } else {
                        manager.buildUnbound(in: unboundPath)
                    }
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!manager.buildPhase.isRunning && !AppController.pathValid(unboundPath))

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

                Button("Find in Logs") {
                    NotificationCenter.default.post(name: .focusLogFilter, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }
}
