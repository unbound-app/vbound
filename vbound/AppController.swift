import AppKit
import CoreGraphics
import Observation

@Observable
final class AppController: @unchecked Sendable {

    // MARK: - Observable state

    var vphoneDetected  = false
    var isAttached      = false
    var buildPhase: BuildPhase = .idle
    var buildLog:   String = ""
    var buildProgress: Double = 0
    var logLines:        [LogEntry] = []
    var isStreaming      = false
    var shellLines:      [String] = []
    var isShellConnected = false
    var bootedVphone     = false
    var vphoneUDID:      String? = nil

    // MARK: - Internal state (accessible from extension files)

    // ~/.ssh/ is created lazily here so ControlPath is always valid on first use (#8)
    static let sshControlPath: String = {
        let dir = NSHomeDirectory() + "/.ssh"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        return dir + "/vbound-mux"
    }()

    weak var ourWindow:   NSWindow?
    var forwardProcess:   Process?
    var logStreamTask:    Task<Void, Never>?
    var shellProcess:     Process?
    var shellInputHandle: FileHandle?
    var shellAutoReconnect = false
    var terminatingDelegate: TerminatingWindowDelegate?

    // MARK: - Private state (window attachment only)

    private var pollTimer:       Timer?
    private var windowObservers: [NSObjectProtocol] = []

    // MARK: - Lifecycle

    func start() {
        guard pollTimer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkAndAttach() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        setupWindowObservers()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        stopLogStream()
    }

    // MARK: - Window observers

    private func setupWindowObservers() {
        let mini = NotificationCenter.default.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let self, (n.object as? NSWindow) === self.ourWindow else { return }
            self.isAttached = false
            self.findVphoneApp()?.hide()
        }
        let demini = NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let self, (n.object as? NSWindow) === self.ourWindow else { return }
            self.findVphoneApp()?.unhide()
        }
        windowObservers = [mini, demini]
    }

    // MARK: - Window attachment / positioning

    private func checkAndAttach() {
        let app = findVphoneApp()
        guard let vphoneFrame = findVphoneWindowFrame() else {
            // vphoneDetected = process running (true even when minimized)
            vphoneDetected = app != nil
            guard isAttached else { return }
            isAttached = false
            if let app, isVphoneMinimized(forPID: app.processIdentifier) {
                ourWindow?.miniaturize(nil)
            } else if app == nil {
                ourWindow?.orderOut(nil)
            }
            return
        }
        vphoneDetected = true
        if !isAttached { ourWindow?.orderFront(nil) }
        positionBeside(vphoneFrame)
    }

    private func findVphoneApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            ($0.localizedName ?? "").lowercased().contains("vphone") ||
            ($0.bundleIdentifier ?? "").lowercased().contains("vphone")
        }
    }

    private func findVphoneWindowFrame() -> CGRect? {
        let minWidth: CGFloat = 200
        if let app = findVphoneApp(),
           let frame = windowFrame(forPID: app.processIdentifier), frame.width >= minWidth {
            return frame
        }
        if let frame = windowFrameByTitle(), frame.width >= minWidth { return frame }
        return nil
    }

    private func isVphoneMinimized(forPID pid: pid_t) -> Bool {
        let opts = CGWindowListOption.excludeDesktopElements
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int ?? 1) == 0 else { continue }
            if info[kCGWindowIsOnscreen as String] as? Bool == false { return true }
        }
        return false
    }

    private func windowFrame(forPID pid: pid_t) -> CGRect? {
        let opts = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int ?? 1) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            return rect
        }
        return nil
    }

    private func windowFrameByTitle() -> CGRect? {
        let opts = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int ?? 1) == 0,
                  (info[kCGWindowName as String] as? String ?? "").lowercased().contains("vphone"),
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            return rect
        }
        return nil
    }

    private func positionBeside(_ vphoneFrame: CGRect) {
        guard let window = ourWindow,
              let screenHeight = NSScreen.main?.frame.height else { return }
        let appkitY = screenHeight - vphoneFrame.minY - window.frame.height
        let target  = NSPoint(x: vphoneFrame.maxX, y: appkitY)
        if window.frame.origin != target { window.setFrameOrigin(target) }
        if !isAttached { isAttached = true }
    }
}
