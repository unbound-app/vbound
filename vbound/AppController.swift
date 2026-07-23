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
    var activeBuildTarget: BuildTarget? = nil
    var logLines:        [LogEntry] = []
    var isStreaming      = false
    var isStreamConnecting = false
    var shellLines:      [ShellLine] = []
    var isShellConnected = false
    var isShellConnecting = false
    var discordLaunchFailed = false
    var isBooting        = false
    var isLaunchingDiscord = false
    var bootedVphone     = false
    var vphoneUDID:      String? = nil
    var isMounted        = false
    var isMounting       = false
    var lastMountError:  String? = nil
    var lastTweakResult:  BuildResultSummary? = nil
    var lastAddonsResult: BuildResultSummary? = nil
    var lastFailedPlugins: [FailedPlugin] = []
    var sshTestState: SSHTestState = .idle

    // MARK: - Internal state (accessible from extension files)

    let shellBuffer = ANSILineBuffer()
    var buildLogFull = ""
    var lastPluginsWorkDir = ""
    var activeProcesses: [Process] = []
    var globalHotkeyMonitor: Any?
    var localHotkeyMonitor:  Any?

    // ~/.ssh/ is created lazily here so ControlPath is always valid on first use (#8)
    static let sshControlPath: String = {
        let dir = NSHomeDirectory() + "/.ssh"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        return dir + "/vbound-mux"
    }()

    weak var ourWindow:   NSWindow?
    var mountProcess:     Process?
    var forwardProcess:   Process?
    var buildTask:        Task<Void, Never>?
    var buildProcess:     Process?
    var logStreamTask:    Task<Void, Never>?
    var logStreamProcess: Process?
    var logStreamAutoReconnect = false
    var shellProcess:     Process?
    var shellInputHandle: FileHandle?
    var shellAutoReconnect = false
    var terminatingDelegate: TerminatingWindowDelegate?

    // MARK: - Private state (window attachment only)

    private var pollTimer:       Timer?
    private var windowObservers: [NSObjectProtocol] = []
    private var slowPollTickCounter = 0

    // MARK: - Lifecycle

    // Weak ref used by AppDelegate.applicationWillTerminate to reach the controller
    // regardless of which quit path fired (⌘Q, dock, close button, etc.)
    private(set) static weak var current: AppController?

    func start() {
        guard pollTimer == nil else { return }
        AppController.current = self
        // Reflects a mount left over from a previous session/crash so the Finder button
        // shows the right state immediately instead of only after the next click.
        Task { [weak self] in
            guard let self else { return }
            isMounted = await isPathMounted(AppController.mountPath)
        }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        setupWindowObservers()
        if globalHotkeyEnabled { enableGlobalHotkey() }
    }

    // The underlying CGWindowList enumeration in checkAndAttach() — not the timer
    // itself — is the real cost of polling every 100ms for the app's whole lifetime.
    // That cadence only actually matters while the panel is following vphone's window
    // live (autoAttachEnabled + already attached, so a drag needs to look smooth);
    // otherwise (not attached yet, or auto-attach is off so nothing ever repositions)
    // a few hundred ms of extra detection latency is imperceptible, so most ticks are
    // skipped — roughly a 5x cut to the syscall rate while idle.
    private func tick() {
        guard isAttached && autoAttachEnabled else {
            slowPollTickCounter += 1
            guard slowPollTickCounter >= 5 else { return }
            slowPollTickCounter = 0
            checkAndAttach()
            return
        }
        slowPollTickCounter = 0
        checkAndAttach()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        stopLogStream()
        disconnectShell()
        unmountVphone()
        disableGlobalHotkey()
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
        // Our window runs at `.floating` level so it stays above the vphone window it's
        // snapped to — but that also means any ordinary window (About panel, Settings,
        // alerts) opens *behind* it. Drop to `.normal` whenever another window becomes
        // key, and restore once no other windows are left open.
        let auxKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let self, let window = n.object as? NSWindow, window !== self.ourWindow else { return }
            self.ourWindow?.level = .normal
        }
        let auxClose = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let self, let closed = n.object as? NSWindow, closed !== self.ourWindow else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let othersRemain = NSApp.windows.contains { $0 !== self.ourWindow && $0.isVisible }
                if !othersRemain { self.ourWindow?.level = .floating }
            }
        }
        windowObservers = [mini, demini, auxKey, auxClose]
    }

    // MARK: - Window attachment / positioning

    private func checkAndAttach() {
        let app = findVphoneApp()
        guard let vphoneFrame = findVphoneWindowFrame() else {
            // vphoneDetected = process running (true even when minimized)
            vphoneDetected = app != nil
            if vphoneDetected { isBooting = false }
            updateWindowTitle()
            guard isAttached else { return }
            isAttached = false
            guard autoAttachEnabled else { return }
            // Anything short of a genuine Dock miniaturize (app quit, Stage Manager
            // sweeping the phone window off-screen, a Spaces switch, ...) should still
            // pull vbound out of view the same way vphone just did, instead of leaving
            // it glued in place at `.floating` level with nothing behind it.
            if let app, isVphoneMinimized(forPID: app.processIdentifier) {
                ourWindow?.miniaturize(nil)
            } else {
                ourWindow?.orderOut(nil)
            }
            return
        }
        vphoneDetected = true
        isBooting = false
        if autoAttachEnabled {
            if !isAttached { ourWindow?.orderFront(nil) }
            positionBeside(vphoneFrame)
        } else {
            markAttached()
        }
        updateWindowTitle()
    }

    // The titlebar otherwise just shows the static app name with a lot of unused
    // width next to the traffic lights — surface the resolved device identifier
    // there once known, since it isn't shown anywhere else in the UI.
    private func updateWindowTitle() {
        guard let window = ourWindow else { return }
        let newTitle: String
        if vphoneDetected, let udid = vphoneUDID {
            newTitle = "vbound · \(udid)"
        } else {
            newTitle = "vbound"
        }
        if window.title != newTitle { window.title = newTitle }
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

    // kCGWindowName (the window title) is redacted to nil by macOS unless vbound has
    // Screen Recording permission granted — which it has no reason to ask for — so the
    // *primary*, PID-based lookup below can't rely on titles to tell vphone-cli's
    // "Files" (700x500) and "Keychain" (900x500) browser windows apart from the actual
    // phone display. The phone window's aspect ratio is locked to the guest's screen
    // resolution at creation and stays locked through resizing, so it's always
    // portrait — unlike those two, which are always landscape. Bounds aren't gated by
    // that permission, so orientation is a reliable, permission-free discriminator.
    //
    // Orientation alone isn't quite enough, though: the same process also transiently
    // reports tiny Exposé/Mission-Control preview windows (well under 200pt either
    // dimension) and a square QuickLook panel it keeps around for the Files browser,
    // and either could otherwise slip through. A phone screen is comfortably bigger
    // than both, so a minimum-size floor filters them out too.
    private func isPhoneWindowShape(_ bounds: CGRect) -> Bool {
        bounds.height > bounds.width && bounds.width >= 250 && bounds.height >= 400
    }

    // Only used by the title-based fallback below, which does need Screen Recording
    // permission to see anything — kept best-effort for when that's granted.
    private func isPhoneWindowTitle(_ title: String?) -> Bool {
        (title ?? "").lowercased().hasPrefix("vphone [")
    }

    private func isVphoneMinimized(forPID pid: pid_t) -> Bool {
        let opts = CGWindowListOption.excludeDesktopElements
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int ?? 1) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  isPhoneWindowShape(rect)
            else { continue }
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
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  isPhoneWindowShape(rect)
            else { continue }
            return rect
        }
        return nil
    }

    // Fallback for the rare case findVphoneApp() can't resolve the process — scans
    // every on-screen window system-wide, so it leans on the title (when Screen
    // Recording permission allows reading it) rather than shape alone, which would be
    // too broad a net across unrelated apps' windows.
    private func windowFrameByTitle() -> CGRect? {
        let opts = CGWindowListOption([.optionOnScreenOnly, .excludeDesktopElements])
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int ?? 1) == 0,
                  isPhoneWindowTitle(info[kCGWindowName as String] as? String),
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            return rect
        }
        return nil
    }

    private func positionBeside(_ vphoneFrame: CGRect) {
        // vphoneFrame comes from CGWindowList, whose Y-coordinates are always relative to
        // the primary display's top edge — NOT to NSScreen.main, which is whichever screen
        // currently holds the key window. Using .main here flips against the wrong height
        // whenever vbound itself is focused on a different display than vphone, snapping
        // the panel to the wrong vertical position on multi-monitor setups.
        guard let window = ourWindow,
              let screenHeight = NSScreen.screens.first?.frame.height else { return }
        let appkitY = screenHeight - vphoneFrame.minY - window.frame.height
        let target  = NSPoint(x: vphoneFrame.maxX, y: appkitY)
        if window.frame.origin != target { window.setFrameOrigin(target) }
        markAttached()
    }

    // One-shot per attach transition (guarded by `isAttached`) so Settings' auto-start
    // toggles fire exactly once when vphone becomes reachable, not on every 100ms poll tick.
    private func markAttached() {
        guard !isAttached else { return }
        isAttached = true
        if autoStartLogStreamEnabled, !isStreaming      { startLogStream() }
        if autoConnectShellEnabled,   !isShellConnected { connectShell() }
    }
}
