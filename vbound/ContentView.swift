import SwiftUI
import AppKit
import AppUpdater
import Version
import UniformTypeIdentifiers

private let cardSize = NSSize(width: 600, height: 505)

struct ContentView: View {
    @Environment(AppController.self) var manager
    @EnvironmentObject private var appUpdater: AppUpdater
    @AppStorage("vphoneCliPath") private var vphoneCliPath = NSHomeDirectory() + "/vphone-cli"
    @AppStorage("unboundPath")   private var unboundPath   = NSHomeDirectory() + "/Developer/loader-ios"
    @AppStorage("skippedUpdateVersion") private var skippedUpdateVersion = ""
    @State private var showUpdateSheet = false

    @State private var logSearch         = ""
    @State private var searchMatchIndex  = 0
    @AppStorage("showINF") private var showINF = true
    @AppStorage("showERR") private var showERR = true
    @AppStorage("showDBG") private var showDBG = true
    // Resets to true each launch/attach — auto-follow is the expected default, not a
    // sticky "stay off forever" preference (#18).
    @State private var logAutoScroll     = true
    @State private var activeTab         : LogTab = .unbound
    @AppStorage("logsMerged") private var logsMerged = false
    @State private var scrollVersion        = 0
    @State private var showShutdownConfirm  = false
    @State private var shellInput           = ""
    @State private var shellScrollVersion   = 0
    @State private var unboundUnread     : UnreadLevel = .none
    @State private var reactNativeUnread : UnreadLevel = .none
    @State private var shellHistory      : [String] = []
    @State private var shellHistoryIndex : Int? = nil
    @Environment(\.openSettings) private var openSettings
    @FocusState private var shellInputFocused: Bool
    @FocusState private var logSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
            Divider()
            logsSection
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .overlay(alignment: .bottom) {
            if manager.buildPhase.isActive {
                buildProgressOverlay
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: manager.buildPhase.isActive)
        .background(WindowAccessor(callback: configureWindow))
        .onChange(of: manager.logLines.count) { old, new in
            let delta = new - old
            guard delta > 0 else { return }
            scrollVersion += 1
            markUnread(manager.logLines[old..<new])
        }
        .onChange(of: logsMerged) { _, merged in
            guard merged else { return }
            if activeTab == .reactNative { activeTab = .unbound }
            // Merging while already parked on the (now-combined) tab counts as viewing
            // both subsystems immediately — without this, an unread React Native badge
            // earned before merging would keep showing through on the merged tab even
            // though its entries are right there on screen.
            if activeTab == .unbound { unboundUnread = .none; reactNativeUnread = .none }
        }
        .onChange(of: activeTab)  { _, new in
            logAutoScroll = true  // #18 — switching tabs means you want to watch that tab live
            searchMatchIndex = 0  // match list is tab-scoped (via filteredEntries)
            if new == .unbound {
                unboundUnread = .none
                if logsMerged { reactNativeUnread = .none }
            }
            if new == .reactNative { reactNativeUnread = .none }
        }
        .onChange(of: logSearch) { _, _ in searchMatchIndex = 0 }
        .overlay {
            if showUpdateSheet {
                UpdateOverlay(isPresented: $showUpdateSheet)
                    .environmentObject(appUpdater)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .checkForUpdates)) { _ in
            withAnimation(.easeOut(duration: 0.15)) { showUpdateSheet = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestShutdownVphone)) { _ in
            showShutdownConfirm = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusLogFilter)) { _ in
            // The filter field doesn't apply to Shell content — hop to a log tab first
            // so ⌘F always lands somewhere the search actually does something.
            if activeTab == .shell { activeTab = .unbound }
            logSearchFocused = true
        }
        .onReceive(appUpdater.$state) { state in
            if case .none = state { return }
            guard state.release?.tagName.description != skippedUpdateVersion else { return }
            if !showUpdateSheet { withAnimation(.easeOut(duration: 0.15)) { showUpdateSheet = true } }
        }
    }

    // Pulled out of the WindowAccessor closure literal — inlining this much statement
    // volume directly into the `body` modifier chain pushed SwiftUI's type-checker over
    // its "reasonable time" budget for the whole (already large) expression tree.
    private func configureWindow(_ window: NSWindow) {
        window.styleMask.remove(.resizable)
        // There's no "zoomable" style mask to remove — the button itself has to be
        // disabled directly, otherwise it stays clickable-looking even though
        // contentMinSize == contentMaxSize means zooming can't change anything.
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.contentMinSize = cardSize
        window.contentMaxSize = cardSize
        window.setContentSize(cardSize)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Only matters when auto-attach is off (positionBeside overrides the origin every
        // poll tick otherwise) — restores wherever the window was last manually dragged to
        // instead of resetting to the default placement on every relaunch.
        window.setFrameAutosaveName("vboundMainWindow")
        manager.ourWindow = window
        // Replace window delegate with a proxy that quits on close.
        // windowShouldClose intercepts SwiftUI's hide-instead-of-close behaviour;
        // the close button target-action is a belt-and-suspenders backup.
        let quitDelegate = TerminatingWindowDelegate()
        quitDelegate.originalDelegate = window.delegate
        quitDelegate.controller = manager
        manager.terminatingDelegate = quitDelegate
        window.delegate = quitDelegate
        window.standardWindowButton(.closeButton)?.target = quitDelegate
        window.standardWindowButton(.closeButton)?.action =
            #selector(TerminatingWindowDelegate.closeWindow(_:))
        manager.start()
    }

    // MARK: - Status strip (status + all primary actions, one line)

    @ViewBuilder
    private var statusStrip: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(manager.vphoneDetected ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)
                .animation(.easeInOut(duration: 0.2), value: manager.vphoneDetected)
            Text(statusText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(statusHelpText)
                .contextMenu {
                    if let udid = manager.vphoneUDID {
                        Button("Copy UDID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(udid, forType: .string)
                        }
                    }
                }

            Spacer(minLength: 8)

            // One toggling button instead of two permanently-visible ones — Boot and Stop
            // are never both relevant at once (vphoneDetected gates them oppositely
            // already), so showing both wasted a full button's worth of width. Mirrors
            // the Stream/Connect toggles elsewhere: same prominent style throughout,
            // only the tint swaps.
            Button {
                if manager.vphoneDetected {
                    showShutdownConfirm = true
                } else {
                    manager.bootVphone(in: vphoneCliPath)
                }
            } label: {
                Label(manager.vphoneDetected ? "Stop" : "Boot",
                      systemImage: manager.vphoneDetected ? "stop.fill" : "power")
            }
            .buttonStyle(.borderedProminent)
            .tint(manager.vphoneDetected ? .red : Color.accentColor)
            .disabled(!manager.vphoneDetected && !pathValid(vphoneCliPath))
            .help(manager.vphoneDetected ? "Shut down vphone" : bootHelpText)
            .confirmationDialog("Shut down vphone?", isPresented: $showShutdownConfirm) {
                Button("Shut Down", role: .destructive) { manager.shutdownVphone() }
                Button("Cancel",    role: .cancel) {}
            } message: {
                // Mirrors the same warning TerminatingWindowDelegate already shows when
                // quitting mid-build — shutting down vphone is just as destructive to an
                // in-flight upload/install as quitting the app is.
                if manager.buildPhase.isRunning {
                    Text("A build is currently in progress. Shutting down now will interrupt it.")
                } else {
                    Text("This will power off the virtual phone.")
                }
            }

            Button {
                logAutoScroll = true  // #18 — launching Discord means you want to watch it boot
                manager.launchDiscord()
            } label: {
                Label { Text("Launch Discord") } icon: { Image("Discord") }
            }
            .buttonStyle(.bordered)
            .disabled(!manager.vphoneDetected)
            .help(manager.discordLaunchFailed
                  ? "Failed to restart Discord — check the device password in Settings"
                  : "Launch Discord")
            // The SSH command is fire-and-forget from the caller's perspective, so without
            // this a failed restart (bad password, device offline) looked identical to a
            // successful one — nothing to click, nothing to dismiss, just silence.
            .overlay(alignment: .topTrailing) {
                if manager.discordLaunchFailed {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .offset(x: 2, y: -2)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: manager.discordLaunchFailed)

            Button {
                if manager.buildPhase.isRunning {
                    manager.cancelBuild()
                } else {
                    logAutoScroll = true  // #18 — same for a fresh build/install run
                    manager.buildUnbound(in: unboundPath)
                }
            } label: {
                Label(manager.buildPhase.isRunning ? "Cancel Build" : "Build Tweak",
                      systemImage: manager.buildPhase.isRunning ? "xmark" : "hammer.fill")
            }
            .buttonStyle(.bordered)
            .tint(manager.buildPhase.isRunning ? .red : Color.accentColor)
            .disabled(!manager.buildPhase.isRunning && !pathValid(unboundPath))
            .help(buildHelpText)

            Divider().frame(height: 16)

            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)
            .help("Settings")
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Build progress (floats over the bottom of the log/shell area)

    @ViewBuilder
    private var buildProgressOverlay: some View {
        progressSection
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var progressSection: some View {
        switch manager.buildPhase {
        case .succeeded:
            resultRow(icon: "checkmark.circle.fill", tint: .green, message: manager.buildPhase.label, showDismiss: false)
        case .cancelled:
            resultRow(icon: "xmark.circle.fill", tint: .secondary, message: manager.buildPhase.label, showDismiss: false)
        case .failed:
            resultRow(icon: "exclamationmark.triangle.fill", tint: .red, message: manager.buildPhase.label, showDismiss: true)
        default:
            VStack(alignment: .leading, spacing: 3) {
                if case .building = manager.buildPhase {
                    ProgressView(value: manager.buildProgress).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if !manager.buildLog.isEmpty {
                    Text(manager.buildLog)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary.opacity(0.75))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func resultRow(icon: String, tint: Color, message: String, showDismiss: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if showDismiss {
                Button {
                    manager.dismissBuildResult()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Logs section

    @ViewBuilder
    private var logsSection: some View {
        VStack(spacing: 0) {
            // Cross-fade between log and shell toolbars
            ZStack(alignment: .leading) {
                logToolbar
                    .opacity(activeTab == .shell ? 0 : 1)
                    .allowsHitTesting(activeTab != .shell)
                shellToolbar
                    .opacity(activeTab == .shell ? 1 : 0)
                    .allowsHitTesting(activeTab == .shell)
            }
            .animation(.easeInOut(duration: 0.25), value: activeTab == .shell)

            Divider()

            HStack(spacing: 10) {
                if logsMerged {
                    tabButton(.unbound, icon: Self.mergedIconKey, label: "Logs", unread: allUnread)
                        .keyboardShortcut("1", modifiers: .command)
                        .transition(.opacity)
                } else {
                    tabButton(.unbound,     icon: "Unbound",      label: "Unbound",      unread: unboundUnread)
                        .keyboardShortcut("1", modifiers: .command)
                        .transition(.opacity)
                    tabButton(.reactNative, icon: "React Native", label: "React Native", unread: reactNativeUnread)
                        .keyboardShortcut("2", modifiers: .command)
                        .transition(.opacity)
                }
                tabButton(.shell, icon: "terminal", label: "Shell", unread: .none)
                    .keyboardShortcut("3", modifiers: .command)
            }
            .animation(.easeInOut(duration: 0.25), value: logsMerged)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)

            Divider()

            // Cross-fade between log and shell content
            ZStack {
                logScrollView
                    .opacity(activeTab == .shell ? 0 : 1)
                    .allowsHitTesting(activeTab != .shell)
                shellView
                    .opacity(activeTab == .shell ? 1 : 0)
                    .allowsHitTesting(activeTab == .shell)
            }
            .animation(.easeInOut(duration: 0.25), value: activeTab == .shell)
        }
        .onChange(of: activeTab) { _, new in
            if new == .shell, !manager.isShellConnected { manager.connectShell() }
        }
    }

    @ViewBuilder
    private var logToolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 12))
                TextField("Filter…", text: $logSearch)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .focused($logSearchFocused)
                    .onSubmit { jumpToNextMatch() }
                    .onKeyPress { press in
                        // Escape mirrors the standard Safari/Xcode find-bar convention:
                        // clear the query first, then (now that there's nothing left to
                        // clear) drop focus out of the field on a second press.
                        if press.key == .escape {
                            if !logSearch.isEmpty { logSearch = "" } else { logSearchFocused = false }
                            return .handled
                        }
                        // ⌘G / ⇧⌘G jump between search matches while the filter field
                        // has focus — matches are already highlighted, but there was no
                        // way to step between them without scrolling by hand.
                        guard press.characters.lowercased() == "g",
                              press.modifiers.contains(.command) else { return .ignored }
                        if press.modifiers.contains(.shift) { jumpToPreviousMatch() }
                        else                                { jumpToNextMatch() }
                        return .handled
                    }
                if !logSearch.isEmpty {
                    Text(matchCountLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                    Button { jumpToPreviousMatch() } label: {
                        Image(systemName: "chevron.up")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .disabled(searchMatches.isEmpty)
                    .help("Previous match (⇧⌘G)")
                    Button { jumpToNextMatch() } label: {
                        Image(systemName: "chevron.down")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .disabled(searchMatches.isEmpty)
                    .help("Next match (⌘G)")
                    Button { logSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
            )

            LevelFilter(label: "INF", on: $showINF, color: .blue)
                .help("Show/hide Info messages")
            LevelFilter(label: "ERR", on: $showERR, color: .red)
                .help("Show/hide Error messages")
            LevelFilter(label: "DBG", on: $showDBG, color: .secondary)
                .help("Show/hide Debug messages")

            Divider().frame(height: 16)

            LevelFilter(label: "MERGE", on: $logsMerged, color: .purple)
                .help("Merge Unbound and React Native into one combined view")

            Divider().frame(height: 16)

            Group {
                // ⌘K only while a log tab is showing — the shell toolbar's Clear button
                // claims the same shortcut while Shell is active, so exactly one of the
                // two is ever attached at a time (both toolbars stay mounted underneath
                // the cross-fade, so having both claim it unconditionally would be
                // ambiguous). Mirrors Terminal.app's own ⌘K-clears-buffer convention.
                if activeTab != .shell {
                    Button { manager.logLines = [] } label: {
                        Image(systemName: "trash")
                    }
                    .keyboardShortcut("k", modifiers: .command)
                } else {
                    Button { manager.logLines = [] } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14))
            .help("Clear all logs")

            Group {
                Button { copyLogs() } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy visible logs to clipboard")

                // #18 — persistent auto-follow toggle: disengages the moment the user
                // scrolls or clicks into the log view (see LogTextView's onUserInteraction),
                // so reading older entries doesn't keep getting yanked back to the bottom.
                // Re-engaging jumps straight to the newest entry, same as the old
                // dedicated "scroll to newest" button this replaced.
                Button {
                    logAutoScroll.toggle()
                    guard logAutoScroll else { return }
                    scrollVersion += 1
                } label: {
                    Image(systemName: logAutoScroll ? "pin.fill" : "pin.slash")
                }
                .foregroundStyle(logAutoScroll ? Color.accentColor : Color.secondary)
                .help(logAutoScroll
                      ? "Auto-scroll to newest is on — click to pause"
                      : "Auto-scroll to newest is off — click to resume")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14))

            Divider().frame(height: 16)

            HStack(spacing: 6) {
                // Resolving the vphone UDID (before any data has actually arrived) gets a
                // spinner instead of a solid dot — isStreaming flips true immediately on
                // click so the button already reads "Stop", but without this the dot would
                // claim "live" for the second or so it takes just to find the device.
                if manager.isStreamConnecting {
                    ProgressView().controlSize(.mini).frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(manager.isStreaming ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 8, height: 8)
                        .animation(.easeInOut(duration: 0.25), value: manager.isStreaming)
                }
                Button(manager.isStreaming ? "Stop" : "Stream") {
                    if manager.isStreaming {
                        manager.stopLogStream()
                    } else {
                        logAutoScroll = true  // #18 — (re)starting the stream means watch live
                        manager.startLogStream()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(manager.isStreaming ? .red : Color.accentColor)
                .help(manager.isStreamConnecting ? "Resolving vphone device…"
                      : manager.isStreaming      ? "Stop live log stream"
                                                  : "Start live log stream")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // Distinguishes "nothing has arrived yet" from "entries exist but every level filter
    // is off" — the latter now persists across relaunches, so a leftover all-off state
    // would otherwise silently masquerade as a dead/broken stream (see #17).
    private var emptyLogStateMessage: String {
        if !showINF && !showERR && !showDBG {
            return "INF/ERR/DBG are all hidden — enable one to see logs"
        }
        return manager.isStreaming ? "Waiting for logs…" : "Tap Stream to start"
    }

    @ViewBuilder
    private var logScrollView: some View {
        if filteredEntries.isEmpty {
            Text(emptyLogStateMessage)
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LogTextView(
                entries: filteredEntries,
                scrollVersion: scrollVersion,
                autoScroll: logAutoScroll,
                searchQuery: logSearch,
                focusedEntryID: currentMatchID,
                onFilterToSource: { entry in logSearch = entry.source },
                onUserInteraction: { logAutoScroll = false },
                onReachedBottom: { logAutoScroll = true }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func tabButton(_ tab: LogTab, icon: String, label: String, unread: UnreadLevel) -> some View {
        if activeTab == tab {
            Button { activeTab = tab } label: {
                tabLabel(icon: icon, label: label, unread: unread)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button { activeTab = tab } label: {
                tabLabel(icon: icon, label: label, unread: unread)
            }
            .buttonStyle(.bordered)
        }
    }

    private static let customSymbolNames: Set<String> = ["Unbound", "React Native", "Discord"]
    private static let mergedIconKey = "Unbound+ReactNative"

    // The merged "Logs" tab stands in for both subsystems, so its icon combines their
    // actual marks (with a small "+") rather than a generic system glyph that means
    // nothing on its own.
    private var mergedLogsIcon: some View {
        HStack(spacing: 3) {
            Image("Unbound")
            Image(systemName: "plus")
                .font(.system(size: 8, weight: .bold))
            Image("React Native")
        }
    }

    @ViewBuilder
    private func tabLabel(icon: String, label: String, unread: UnreadLevel) -> some View {
        Label {
            Text(label)
        } icon: {
            if icon == Self.mergedIconKey {
                mergedLogsIcon
            } else if Self.customSymbolNames.contains(icon) {
                Image(icon)
            } else {
                Image(systemName: icon)
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            if unread != .none {
                Circle()
                    .fill(unread == .error ? Color.red : Color.blue)
                    .frame(width: 6, height: 6)
                    .offset(x: -6)
            }
        }
    }

    private var filteredEntries: [LogEntry] {
        guard activeTab != .shell else { return [] }
        let target: LogSubsystem? = logsMerged ? nil : (activeTab == .unbound ? .unbound : .reactNative)
        return manager.logLines.filter { entry in
            if entry.isHeader { return true }
            if let target, let sub = entry.subsystem, sub != target { return false }
            let levelPass: Bool
            switch entry.level {
            case "INF": levelPass = showINF
            case "ERR": levelPass = showERR
            case "DBG": levelPass = showDBG
            default:    levelPass = true
            }
            guard levelPass else { return false }
            return logSearch.isEmpty || entry.asString().localizedCaseInsensitiveContains(logSearch)
        }
    }

    private var allUnread: UnreadLevel {
        if unboundUnread == .error || reactNativeUnread == .error { return .error }
        if unboundUnread == .info  || reactNativeUnread == .info  { return .info }
        return .none
    }

    // MARK: - Search match navigation

    // Collapsed the same way LogTextView collapses for display, so a match index here
    // lines up with an actual rendered row (a raw, pre-collapse entry could otherwise be
    // folded into a duplicate-run's "×N" row under a different representative entry).
    private var searchMatches: [LogEntry] {
        guard !logSearch.isEmpty else { return [] }
        return LogTextView.collapseConsecutive(filteredEntries).map(\.entry).filter { !$0.isHeader }
    }

    private var currentMatchID: LogEntry.ID? {
        guard !searchMatches.isEmpty else { return nil }
        return searchMatches[min(max(searchMatchIndex, 0), searchMatches.count - 1)].id
    }

    private var matchCountLabel: String {
        guard !searchMatches.isEmpty else { return "0/0" }
        return "\(min(max(searchMatchIndex, 0), searchMatches.count - 1) + 1)/\(searchMatches.count)"
    }

    private func jumpToNextMatch() {
        guard !searchMatches.isEmpty else { return }
        logAutoScroll = false  // browsing matches, not watching the live tail
        searchMatchIndex = (searchMatchIndex + 1) % searchMatches.count
    }

    private func jumpToPreviousMatch() {
        guard !searchMatches.isEmpty else { return }
        logAutoScroll = false
        searchMatchIndex = (searchMatchIndex - 1 + searchMatches.count) % searchMatches.count
    }

    // MARK: - Shell toolbar + view

    @ViewBuilder
    private var shellToolbar: some View {
        HStack(spacing: 6) {
            // SSH target — expands like the log search field. The full address
            // (mobile@127.0.0.1:2222, always the same host) lives in the tooltip rather
            // than inline: with the control-key row now 8 buttons wide there's rarely
            // enough leftover width for the full string, and it was clipping (#20).
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 12))
                Text("SSH")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .help(manager.isShellConnected ? "Connected to mobile@127.0.0.1:2222" : "Not connected")

            Group {
                ForEach(terminalControlKeys, id: \.label) { control in
                    Button {
                        manager.sendShellControlBytes(control.bytes)
                        // ^L alone only asks the remote to redraw — ANSILineBuffer
                        // deliberately drops the clear-screen escape sequence the remote
                        // sends back (non-SGR CSI sequences are out of scope for this
                        // terminal emulation), so without this the label "Clear screen"
                        // wouldn't actually clear anything locally, just add a redrawn
                        // prompt below all the existing scrollback.
                        if control.label == "^L" {
                            manager.shellBuffer.reset()
                            manager.shellLines = manager.shellBuffer.lines
                        }
                    } label: {
                        Text(control.label)
                            .font(.system(size: 10, design: .monospaced))
                            .fixedSize()
                    }
                    .help(control.help)
                    .disabled(!manager.isShellConnected)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .layoutPriority(1)

            Divider().frame(height: 16)

            Group {
                Button { shellScrollVersion += 1 } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .help("Scroll to bottom")

                Button { copyShellOutput() } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy shell output to clipboard")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14))
            .layoutPriority(1)

            Group {
                // ⌘K only while Shell is active — see the matching comment on the log
                // toolbar's own Clear button for why this has to be conditional.
                if activeTab == .shell {
                    Button {
                        manager.shellBuffer.reset()
                        manager.shellLines = manager.shellBuffer.lines
                        if manager.isShellConnected { manager.sendShellInput("") }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .keyboardShortcut("k", modifiers: .command)
                } else {
                    Button {
                        manager.shellBuffer.reset()
                        manager.shellLines = manager.shellBuffer.lines
                        if manager.isShellConnected { manager.sendShellInput("") }
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14))
            .layoutPriority(1)
            .help("Clear terminal output")

            Divider().frame(height: 16)

            HStack(spacing: 6) {
                // Port-forwarding + the SSH handshake take a real second or two with no
                // feedback otherwise — a spinner here avoids the "did my click register?"
                // moment (and, unlike the log stream's Stop, there's no reliable way to
                // cancel mid-handshake, so the button is disabled rather than relabeled).
                if manager.isShellConnecting {
                    ProgressView().controlSize(.mini).frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(manager.isShellConnected ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 8, height: 8)
                        .animation(.easeInOut(duration: 0.25), value: manager.isShellConnected)
                }
                Button(manager.isShellConnecting ? "Connecting…" : (manager.isShellConnected ? "Disconnect" : "Connect")) {
                    if manager.isShellConnected { manager.disconnectShell() }
                    else                        { manager.connectShell() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(manager.isShellConnected ? .red : Color.accentColor)
                .disabled(manager.isShellConnecting)
                .help(manager.isShellConnecting ? "Connecting…"
                      : manager.isShellConnected ? "Disconnect SSH session"
                                                  : "Connect SSH session")
            }
            .fixedSize()
            .layoutPriority(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var shellView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        // A single Text spanning every line (rather than one Text per line) so
                        // drag-selection can span multiple lines — SwiftUI does not merge
                        // adjacent Text views into one continuous selectable range.
                        styledShellText()
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .frame(minWidth: cardSize.width - 32, alignment: .topLeading)
                            .padding(.horizontal, 8)
                        Color.clear.frame(height: 1).id("shellBottom")
                    }
                    .padding(.vertical, 4)
                }
                .defaultScrollAnchor(.bottom)
                .background(Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { shellInputFocused = true }
                .onChange(of: manager.shellLines.count) { _, _ in
                    proxy.scrollTo("shellBottom", anchor: .bottomLeading)
                }
                .onChange(of: manager.shellLines.last) { _, _ in
                    proxy.scrollTo("shellBottom", anchor: .bottomLeading)
                }
                .onChange(of: shellScrollVersion) { _, _ in
                    proxy.scrollTo("shellBottom", anchor: .bottomLeading)
                }
            }

            Divider()

            HStack(spacing: 6) {
                Text("›")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.8))
                TextField("", text: $shellInput)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .textFieldStyle(.plain)
                    .focused($shellInputFocused)
                    .onSubmit {
                        guard !shellInput.isEmpty else { return }
                        manager.sendShellInput(shellInput)
                        if shellHistory.last != shellInput { shellHistory.append(shellInput) }
                        shellHistoryIndex = nil
                        shellInput = ""
                    }
                    .onKeyPress(.upArrow) {
                        guard !shellHistory.isEmpty else { return .ignored }
                        let next = (shellHistoryIndex ?? shellHistory.count) - 1
                        guard next >= 0 else { return .handled }
                        shellHistoryIndex = next
                        shellInput = shellHistory[next]
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard let idx = shellHistoryIndex else { return .ignored }
                        let next = idx + 1
                        if next >= shellHistory.count {
                            shellHistoryIndex = nil
                            shellInput = ""
                        } else {
                            shellHistoryIndex = next
                            shellInput = shellHistory[next]
                        }
                        return .handled
                    }
                    .onPasteCommand(of: [.plainText], perform: handleShellPaste)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(white: 0.1))
            .environment(\.colorScheme, .dark)
        }
    }

    private func markUnread(_ newEntries: ArraySlice<LogEntry>) {
        for entry in newEntries {
            guard let sub = entry.subsystem else { continue }
            let tab: LogTab = sub == .unbound ? .unbound : .reactNative
            // While merged, the single "Logs" tab (identity `.unbound`) shows both
            // subsystems at once, so viewing it clears unread for either one.
            let isViewingThisTab = logsMerged ? (activeTab == .unbound) : (activeTab == tab)
            // An error hidden by the ERR chip is still invisible even while you're parked
            // on this exact tab — without this, "viewing the tab" was treated as "saw
            // everything in it" regardless of the level filter, so toggling ERR off could
            // hide a real crash/error with no indication anywhere. Scoped to ERR only:
            // filtering INF/DBG is a deliberate noise-reduction choice and shouldn't earn
            // a badge just because it happened to arrive while filtered out.
            let hiddenByErrorFilter = entry.level == "ERR" && !showERR
            guard !isViewingThisTab || hiddenByErrorFilter else { continue }
            let level: UnreadLevel = entry.level == "ERR" ? .error : .info
            if sub == .unbound {
                if level == .error || unboundUnread == .none { unboundUnread = level }
            } else {
                if level == .error || reactNativeUnread == .none { reactNativeUnread = level }
            }
        }
    }

    private func pathValid(_ path: String) -> Bool {  // #12
        AppController.pathValid(path)
    }

    // A disabled button with a static tooltip gives no clue *why* — surface the actual
    // reason (bad path vs. already busy) instead of making the user dig into Settings.
    private var bootHelpText: String {
        if manager.vphoneDetected      { return "vphone is already running" }
        if !pathValid(vphoneCliPath)   { return "vphone-cli path is invalid — check Settings" }
        return "Boot vphone"
    }

    private var buildHelpText: String {
        if manager.buildPhase.isRunning { return "Cancel build" }
        if !pathValid(unboundPath)      { return "Unbound tweak path is invalid — check Settings" }
        return "Build Tweak"
    }

    private func styledShellText() -> Text {
        var result = AttributedString()
        for (index, line) in manager.shellLines.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            guard !line.isEmpty else { result += AttributedString(" "); continue }
            for segment in line.segments where !segment.text.isEmpty {
                var run = AttributedString(segment.text)
                run.foregroundColor = segment.color ?? .white
                if segment.bold { run.inlinePresentationIntent = .stronglyEmphasized }
                result += run
            }
        }
        return Text(result)
    }

    // Plain ASCII "^" rather than the Unicode "⌃" modifier glyph — that symbol is
    // designed to render as a tiny mark meant for NSMenuItem key-equivalent display,
    // not as normal-sized text in a button label.
    private let terminalControlKeys: [(label: String, bytes: [UInt8], help: String)] = [
        ("^C",  [0x03],             "Send Ctrl+C (interrupt)"),
        ("^D",  [0x04],             "Send Ctrl+D (EOF)"),
        ("^Z",  [0x1A],             "Send Ctrl+Z (suspend)"),
        ("^L",  [0x0C],             "Clear screen"),
        ("Esc", [0x1B],             "Send Escape"),
        ("Tab", [0x09],             "Send Tab (autocomplete)"),
        ("↑",   [0x1B, 0x5B, 0x41], "Send Up arrow (remote shell history)"),
        ("↓",   [0x1B, 0x5B, 0x42], "Send Down arrow (remote shell history)"),
    ]

    // A single-line TextField mangles pasted newlines by default — this mirrors real
    // terminal paste semantics instead: every newline-terminated line is sent immediately,
    // and a trailing partial line (no final newline) is left in the field to edit/submit
    // rather than silently dropped or auto-run.
    private func handleShellPaste(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let text = reading as? String, !text.isEmpty else { return }
            DispatchQueue.main.async {
                guard text.contains("\n") else {
                    shellInput += text
                    return
                }
                let endsWithNewline = text.hasSuffix("\n")
                var lines = text.components(separatedBy: "\n")
                if endsWithNewline { lines.removeLast() }  // drop the empty tail from the split
                let trailing = endsWithNewline ? "" : lines.removeLast()
                for line in lines where !line.isEmpty {
                    manager.sendShellInput(line)
                    if shellHistory.last != line { shellHistory.append(line) }
                }
                shellHistoryIndex = nil
                shellInput = trailing
            }
        }
    }

    private func copyShellOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            manager.shellLines.map(\.plain).joined(separator: "\n"),
            forType: .string
        )
    }

    private func copyLogs() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            filteredEntries.map { $0.asString() }.joined(separator: "\n"),
            forType: .string
        )
    }

    // Shortened from "Attached · vphone running" etc. — the dot already carries the
    // running/not-running signal, and the fuller phrasing was pushed into a tooltip
    // instead of staying inline, now that the status strip's buttons take up more
    // width (regular control size, "Settings" gained a text label) and were truncating
    // this with an ellipsis.
    private var statusText: String {
        if manager.isAttached     { return "Attached" }
        if manager.vphoneDetected { return "Running" }
        return "Not Running"
    }

    private var statusHelpText: String {
        if manager.isAttached     { return "Attached to the vphone window" }
        if manager.vphoneDetected { return "vphone is running but not attached" }
        return "vphone is not running"
    }
}

#Preview {
    ContentView()
        .environment(AppController())
}
