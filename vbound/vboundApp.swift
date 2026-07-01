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

        if ctrl.bootedVphone && ctrl.vphoneDetected {
            let alert = NSAlert()
            alert.messageText     = "Shut down vphone?"
            alert.informativeText = "vphone was started by vbound and is still running. " +
                                    "Quitting will shut it down gracefully."
            alert.alertStyle      = .warning
            alert.addButton(withTitle: "Shut Down & Quit")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertFirstButtonReturn {
                if let udid = ctrl.vphoneUDID {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    p.arguments     = ["pymobiledevice3", "diagnostics", "shutdown", "--udid", udid]
                    p.environment   = ctrl.enrichedEnvironment
                    try? p.run()
                    p.waitUntilExit()
                }
                quit(ctrl)
            }
        } else {
            quit(ctrl)
        }
    }

    private func quit(_ ctrl: AppController? = nil) {
        ctrl?.stop()
        ctrl?.shellProcess?.terminate()
        ctrl?.forwardProcess?.terminate()
        // Kill the SSH multiplexer master process (ControlPersist=60 keeps it alive
        // for 60 s after the last client disconnects, which leaves a background process)
        let mux = Process()
        mux.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        mux.arguments     = ["ssh", "-O", "exit",
                             "-o", "ControlPath=\(AppController.sshControlPath)",  // #8
                             "mobile@127.0.0.1"]
        try? mux.run()
        mux.waitUntilExit()
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
    func applicationWillTerminate(_ notification: Notification) {
        guard let ctrl = AppController.current else { return }
        ctrl.stop()
        ctrl.shellProcess?.terminate()
        ctrl.forwardProcess?.terminate()
        let mux = Process()
        mux.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        mux.arguments     = ["ssh", "-O", "exit",
                             "-o", "ControlPath=\(AppController.sshControlPath)",
                             "mobile@127.0.0.1"]
        try? mux.run()
        mux.waitUntilExit()
    }
}

// MARK: - Observer token box (#17)
// Wraps the NotificationCenter observer token in a reference type so it has a
// stable identity independent of the App struct's value semantics.
private final class TokenBox {
    var token: NSObjectProtocol?
}

// MARK: - App entry point

extension Notification.Name {
    static let checkForUpdates = Notification.Name("vbound.checkForUpdates")
}

@main
struct vboundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var manager = AppController()
    @State private var aboutTokenBox = TokenBox()  // #17
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
                    appUpdater.check()
                    #endif
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About vbound") {
                    NSApp.activate(ignoringOtherApps: true)
                    let floatingWins = NSApp.windows.filter { $0.level == .floating }
                    floatingWins.forEach { $0.level = .normal }
                    NSApp.orderFrontStandardAboutPanel(nil)
                    // Remove any leftover observer from a previous About-panel open (#17)
                    if let prev = aboutTokenBox.token {
                        NotificationCenter.default.removeObserver(prev)
                        aboutTokenBox.token = nil
                    }
                    // TokenBox gives the observer closure a stable reference to its own
                    // token without relying on a local `var` that falls out of scope (#17).
                    let box = aboutTokenBox
                    box.token = NotificationCenter.default.addObserver(
                        forName: NSWindow.willCloseNotification,
                        object: nil,
                        queue: .main
                    ) { [box] notification in
                        guard let closed = notification.object as? NSWindow,
                              !floatingWins.contains(closed) else { return }
                        floatingWins.forEach { $0.level = .floating }
                        if let t = box.token { NotificationCenter.default.removeObserver(t) }
                        box.token = nil
                    }
                }
                Divider()
                Button("Check for Updates…") {
                    appUpdater.check()
                    NotificationCenter.default.post(name: .checkForUpdates, object: nil)
                }
                .keyboardShortcut("u", modifiers: .command)
            }
        }
    }
}
