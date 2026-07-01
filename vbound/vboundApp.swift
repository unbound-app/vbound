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
                             "-o", "ControlPath=/tmp/vbound-ssh-mux",
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

// MARK: - App entry point

extension Notification.Name {
    static let checkForUpdates = Notification.Name("vbound.checkForUpdates")
}

@main
struct vboundApp: App {
    @State private var manager = AppController()
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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appUpdater.check()
                    NotificationCenter.default.post(name: .checkForUpdates, object: nil)
                }
                .keyboardShortcut("u", modifiers: .command)
            }
        }
    }
}
