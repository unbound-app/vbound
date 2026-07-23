import SwiftUI
import AppKit
import AppUpdater
import Version
import UniformTypeIdentifiers
import Combine

private let defaultWindowSize = NSSize(width: 720, height: 560)

private enum WorkspaceSection: String, CaseIterable, Identifiable {
    case logs, shell

    var id: String { rawValue }
    var label: String { self == .logs ? "Logs" : "Shell" }
    var icon: String { self == .logs ? "text.alignleft" : "terminal" }
}

private enum LogScope: String, CaseIterable, Identifiable {
    case unbound, reactNative, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unbound: return "Unbound"
        case .reactNative: return "React Native"
        case .all: return "All"
        }
    }
}

private enum NativeSegmentImage {
    case asset(String)
    case system(String)
    case none
}

private struct NativeSegmentItem<Selection: Hashable> {
    let value: Selection
    let title: String
    let image: NativeSegmentImage
    let showsTitle: Bool

    init(
        _ value: Selection,
        _ title: String,
        image: NativeSegmentImage = .none,
        showsTitle: Bool = true
    ) {
        self.value = value
        self.title = title
        self.image = image
        self.showsTitle = showsTitle
    }
}

private struct NativeSegmentedControl<Selection: Hashable>: NSViewRepresentable {
    @Binding var selection: Selection
    let items: [NativeSegmentItem<Selection>]

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, items: items)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectionChanged(_:))
        control.segmentStyle = .automatic
        update(control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        context.coordinator.items = items
        update(control)
    }

    private func update(_ control: NSSegmentedControl) {
        control.segmentCount = items.count
        for (index, item) in items.enumerated() {
            control.setLabel(item.showsTitle ? item.title : "", forSegment: index)
            control.setImage(image(for: item), forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            control.setEnabled(true, forSegment: index)
        }
        control.selectedSegment = items.firstIndex { $0.value == selection } ?? -1
    }

    private func image(for item: NativeSegmentItem<Selection>) -> NSImage? {
        let image: NSImage?
        switch item.image {
        case .asset(let assetName):
            image = NSImage(named: assetName)?.copy() as? NSImage
        case .system(let systemName):
            image = NSImage(
                systemSymbolName: systemName,
                accessibilityDescription: item.title
            )?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        case .none:
            image = nil
        }
        image?.isTemplate = true
        return image
    }

    final class Coordinator: NSObject {
        var selection: Binding<Selection>
        var items: [NativeSegmentItem<Selection>]

        init(selection: Binding<Selection>, items: [NativeSegmentItem<Selection>] = []) {
            self.selection = selection
            self.items = items
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard items.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = items[sender.selectedSegment].value
        }
    }
}

struct ContentView: View {
    @Environment(AppController.self) var manager
    @EnvironmentObject private var appUpdater: AppUpdater
    @AppStorage("vphoneCliPath") private var vphoneCliPath = NSHomeDirectory() + "/vphone-cli"
    @AppStorage("unboundPath")   private var unboundPath   = NSHomeDirectory() + "/Developer/loader-ios"
    @AppStorage("unboundPluginsPath") private var unboundPluginsPath = NSHomeDirectory() + "/Developer/unbound-plugins"
    @AppStorage("skippedUpdateVersion") private var skippedUpdateVersion = ""
    @State private var showUpdateSheet = false

    @State private var logSearch         = ""
    @State private var searchMatchIndex  = 0
    @AppStorage("showINF") private var showINF = true
    @AppStorage("showERR") private var showERR = true
    @AppStorage("showDBG") private var showDBG = true
    @AppStorage("logFilterRegex") private var logFilterRegex = false
    @AppStorage("logRelativeTimestamps") private var logRelativeTimestamps = false
    @AppStorage("accentColorChoice") private var accentColorChoice = AccentChoice.system.rawValue
    @State private var bookmarkedIDs: Set<LogEntry.ID> = []
    @State private var scrollToBookmarkID: LogEntry.ID? = nil
    @State private var showBookmarks = false
    @State private var showCommandPalette = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    // Resets to true each launch/attach — auto-follow is the expected default, not a
    // sticky "stay off forever" preference (#18).
    @State private var logAutoScroll     = true
    @State private var activeTab         : LogTab = .unbound
    @State private var lastLogTab        : LogTab = .unbound
    @AppStorage("logsMerged") private var logsMerged = false
    @State private var scrollVersion        = 0
    @State private var showShutdownConfirm  = false
    @State private var shellInput           = ""
    @State private var shellScrollVersion   = 0
    @State private var shellAutoScroll      = true
    @State private var unboundUnread     : UnreadLevel = .none
    @State private var reactNativeUnread : UnreadLevel = .none
    @State private var shellHistory      : [String] = []
    @State private var shellHistoryIndex : Int? = nil
    @Environment(\.openSettings) private var openSettings
    @FocusState private var shellInputFocused: Bool
    @FocusState private var logSearchFocused: Bool

    var body: some View {
        logsSection
        .frame(width: defaultWindowSize.width, height: defaultWindowSize.height)
        .overlay(alignment: .bottom) {
            if manager.buildPhase.isActive {
                buildProgressOverlay
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: manager.buildPhase.isActive)
        .tint(AccentChoice(rawValue: accentColorChoice)?.color)
        .background(WindowAccessor(callback: configureWindow))
        .toolbar { windowToolbar }
        .onAppear {
            guard !hasCompletedOnboarding else { return }
            showOnboarding = true
        }
        .overlay {
            if showOnboarding {
                OnboardingView(isPresented: $showOnboarding)
                    .environment(manager)
            }
        }
        .overlay {
            if showCommandPalette {
                CommandPaletteView(isPresented: $showCommandPalette)
                    .environment(manager)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCommandPalette)) { _ in
            showCommandPalette = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboardingChecklist)) { _ in
            showOnboarding = true
        }
        .onReceive(consoleNotifications, perform: handleConsoleNotification)
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
            if new != .shell { lastLogTab = new }
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
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.contentMinSize = defaultWindowSize
        window.contentMaxSize = defaultWindowSize
        window.setContentSize(defaultWindowSize)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .line
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

    private var consoleNotifications: Publishers.MergeMany<NotificationCenter.Publisher> {
        Publishers.MergeMany([
            NotificationCenter.default.publisher(for: .showLogs),
            NotificationCenter.default.publisher(for: .showShell),
            NotificationCenter.default.publisher(for: .clearConsole),
            NotificationCenter.default.publisher(for: .copyVisibleOutput),
            NotificationCenter.default.publisher(for: .exportVisibleOutput),
            NotificationCenter.default.publisher(for: .jumpToLatest)
        ])
    }

    private func handleConsoleNotification(_ notification: Notification) {
        switch notification.name {
        case .showLogs:
            if activeTab == .shell { activeTab = lastLogTab }
        case .showShell:
            activeTab = .shell
        case .clearConsole:
            clearConsole()
        case .copyVisibleOutput:
            if activeTab == .shell { copyShellOutput() } else { copyLogs() }
        case .exportVisibleOutput:
            saveVisibleOutputToFile()
        case .jumpToLatest:
            if activeTab == .shell {
                shellScrollVersion += 1
            } else {
                logAutoScroll = true
                scrollVersion += 1
            }
        default:
            break
        }
    }

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            deviceMenu
        }

        ToolbarItem(placement: .navigation) {
            Picker("Workspace", selection: workspaceSelection) {
                ForEach(WorkspaceSection.allCases) { section in
                    Image(systemName: section.icon)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 56)
            .accessibilityLabel("Workspace")
        }

        if activeTab == .shell {
            shellActionToolbar
        } else {
            quickActionToolbar
        }
    }

    @ToolbarContentBuilder
    private var quickActionToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            discordQuickAction
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            tweakQuickAction
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            addonsQuickAction
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            mountQuickAction
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            settingsQuickAction
        }
    }

    @ToolbarContentBuilder
    private var shellActionToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                manager.sendShellControlBytes([0x03])
            } label: {
                HStack(spacing: 5) {
                Image(systemName: "stop.circle")
                Text("Interrupt")
            }
                .padding(.horizontal, 2)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(!manager.isShellConnected)
            .help("Send Ctrl+C")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button {
                copyShellOutput()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc")
                    Text("Copy")
                }
                .padding(.horizontal, 2)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(manager.shellLines.isEmpty)
            .help("Copy shell output")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button {
                clearConsole()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash")
                    Text("Clear")
                }
                .padding(.horizontal, 2)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(manager.shellLines.isEmpty)
            .help("Clear terminal output")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button {
                saveVisibleOutputToFile()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Export")
                }
                .padding(.horizontal, 2)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(manager.shellLines.isEmpty)
            .help("Export shell output")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            settingsQuickAction
        }
    }

    private var workspaceSelection: Binding<WorkspaceSection> {
        Binding(
            get: { activeTab == .shell ? .shell : .logs },
            set: { section in
                switch section {
                case .logs:
                    if activeTab == .shell { activeTab = lastLogTab }
                case .shell:
                    activeTab = .shell
                }
            }
        )
    }

    private var deviceMenu: some View {
        Menu {
            if manager.vphoneDetected {
                Button("Shut Down vphone", role: .destructive) {
                    showShutdownConfirm = true
                }
            } else {
                Button("Boot vphone") {
                    manager.bootVphone(in: vphoneCliPath)
                }
                .disabled(manager.isBooting || !pathValid(vphoneCliPath))
            }
            if manager.isMounted {
                Button("Reveal in Finder") { manager.revealMountInFinder() }
            }
            if let udid = manager.vphoneUDID {
                Divider()
                Button("Copy Device UDID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(udid, forType: .string)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(manager.vphoneDetected ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 11))
            }
        }
        .help(statusHelpText)
        .confirmationDialog("Shut down vphone?", isPresented: $showShutdownConfirm) {
            Button("Shut Down", role: .destructive) { manager.shutdownVphone() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if manager.buildPhase.isRunning {
                Text("A build is currently in progress. Shutting down now will interrupt it.")
            } else {
                Text("This will power off the virtual phone.")
            }
        }
    }

    private var tweakQuickAction: some View {
        Button {
            logAutoScroll = true
            manager.toggleTweakBuild(in: unboundPath)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: manager.buildPhase.isRunning && manager.activeBuildTarget == .tweak
                      ? "xmark"
                      : "hammer.fill")
                Text(manager.buildPhase.isRunning && manager.activeBuildTarget == .tweak ? "Cancel" : "Tweak")
            }
            .padding(.horizontal, 2)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(manager.buildPhase.isRunning
                  ? manager.activeBuildTarget != .tweak
                  : !pathValid(unboundPath))
        .help(tweakActionHelpText)
    }

    private var addonsQuickAction: some View {
        Button {
            logAutoScroll = true
            manager.toggleAddonsBuild(in: unboundPluginsPath)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: manager.buildPhase.isRunning && manager.activeBuildTarget == .plugins
                      ? "xmark"
                      : "puzzlepiece.extension.fill")
                Text(manager.buildPhase.isRunning && manager.activeBuildTarget == .plugins ? "Cancel" : "Addons")
            }
            .padding(.horizontal, 2)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(manager.buildPhase.isRunning
                  ? manager.activeBuildTarget != .plugins
                  : !pathValid(unboundPluginsPath))
        .help(addonsActionHelpText)
    }

    private var discordQuickAction: some View {
        Button {
            logAutoScroll = true
            manager.launchDiscord()
        } label: {
            HStack(spacing: 5) {
                Image("Discord")
                    .renderingMode(.template)
                Text("Discord")
            }
            .padding(.horizontal, 2)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(!manager.vphoneDetected || manager.isLaunchingDiscord)
        .help(manager.discordLaunchFailed
              ? "Discord relaunch failed — check the device password in Settings"
              : "Relaunch Discord")
        .overlay(alignment: .topTrailing) {
            if manager.discordLaunchFailed {
                Circle()
                    .fill(Color.red)
                    .frame(width: 5, height: 5)
                    .offset(x: 2, y: -2)
            }
        }
    }

    private var mountQuickAction: some View {
        Button {
            if manager.isMounted {
                manager.unmountVphone()
            } else {
                manager.mountVphone()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: manager.isMounted ? "externaldrive.fill" : "externaldrive")
                Text(manager.isMounted ? "Unmount" : "Mount")
            }
            .padding(.horizontal, 2)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .disabled(manager.isMounting || (!manager.isMounted && !manager.sshfsAvailable))
        .help(mountActionHelpText)
        .overlay(alignment: .topTrailing) {
            if manager.lastMountError != nil, !manager.isMounted, !manager.isMounting {
                Circle()
                    .fill(Color.red)
                    .frame(width: 5, height: 5)
                    .offset(x: 2, y: -2)
            }
        }
    }

    private var settingsQuickAction: some View {
        Button {
            openSettings()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gearshape")
                Text("Settings")
            }
            .padding(.horizontal, 2)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .help("Open Settings")
    }

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
        case .pluginsDeployed:
            resultRow(icon: "checkmark.circle.fill", tint: .green, message: manager.buildPhase.label, showDismiss: false)
        case .cancelled:
            resultRow(icon: "xmark.circle.fill", tint: .secondary, message: manager.buildPhase.label, showDismiss: false)
        case .failed:
            failedResultRow(message: manager.buildPhase.label)
        default:
            VStack(alignment: .leading, spacing: 3) {
                if manager.buildPhase == .building || manager.buildPhase == .deployingPlugins {
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

    @ViewBuilder
    private func failedResultRow(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if manager.activeBuildTarget == .plugins, !manager.lastFailedPlugins.isEmpty {
                Button("Retry") { manager.retryFailedPlugins() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            if !manager.buildLogFull.isEmpty {
                Button("Save Log…") { manager.saveBuildLog() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            Button {
                manager.dismissBuildResult()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var logsSection: some View {
        Group {
            if activeTab == .shell {
                VStack(spacing: 0) {
                    ZStack(alignment: .bottomTrailing) {
                        shellView
                        if !shellAutoScroll {
                            Button {
                                shellAutoScroll = true
                                shellScrollVersion += 1
                            } label: {
                                Label("Jump to Latest", systemImage: "arrow.down.to.line")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(14)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    Divider()
                    shellStatusBar
                }
                .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    logFilterBar
                    Divider()
                    logScrollView
                        .overlay(alignment: .bottomTrailing) {
                        if !logAutoScroll, !filteredEntries.isEmpty {
                            Button {
                                logAutoScroll = true
                                scrollVersion += 1
                            } label: {
                                Label("Jump to Latest", systemImage: "arrow.down.to.line")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .clipped()
                    Divider()
                    logStatusBar
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: activeTab == .shell)
        .animation(.easeInOut(duration: 0.16), value: logAutoScroll)
        .animation(.easeInOut(duration: 0.16), value: shellAutoScroll)
        .onChange(of: activeTab) { _, new in
            if new == .shell, !manager.isShellConnected {
                shellAutoScroll = true
                manager.connectShell()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var logFilterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                logScopePicker
                logSearchField
                logLevelFilters
            }
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    logScopePicker
                    Spacer()
                    logLevelFilters
                }
                logSearchField
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var logScopePicker: some View {
        NativeSegmentedControl(
            selection: logScopeSelection,
            items: [
                NativeSegmentItem(.unbound, logScopeTitle(.unbound), image: .asset("Unbound")),
                NativeSegmentItem(.reactNative, logScopeTitle(.reactNative), image: .asset("React Native")),
                NativeSegmentItem(.all, logScopeTitle(.all))
            ]
        )
        .frame(width: 284)
        .padding(.leading, 6)
        .accessibilityLabel("Source")
    }

    private func logScopeTitle(_ scope: LogScope) -> String {
        switch unreadLevel(for: scope) {
        case .none:
            return scope.label
        case .info, .error:
            return "\(scope.label) •"
        }
    }

    private var logSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: logFilterRegex ? "textformat.alt" : "magnifyingglass")
                .foregroundStyle(logFilterRegex ? Color.accentColor : Color.secondary)
                .font(.system(size: 12))

            TextField("Search logs", text: $logSearch)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
                .focused($logSearchFocused)
                .onSubmit { jumpToNextMatch() }
                .onKeyPress { press in
                    if press.key == .escape {
                        if !logSearch.isEmpty { logSearch = "" } else { logSearchFocused = false }
                        return .handled
                    }
                    guard press.characters.lowercased() == "g",
                          press.modifiers.contains(.command) else { return .ignored }
                    if press.modifiers.contains(.shift) { jumpToPreviousMatch() }
                    else { jumpToNextMatch() }
                    return .handled
                }

            if !logSearch.isEmpty {
                Text(matchCountLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Button { jumpToPreviousMatch() } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(searchMatches.isEmpty)
                .help("Previous match (⇧⌘G)")

                Button { jumpToNextMatch() } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(searchMatches.isEmpty)
                .help("Next match (⌘G)")

                Button { logSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        }
        .frame(minWidth: 170, maxWidth: .infinity)
        .contextMenu {
            Toggle("Regular Expression", isOn: $logFilterRegex)
            Toggle("Relative Timestamps", isOn: $logRelativeTimestamps)
            Divider()
            Button("Clear Search") { logSearch = "" }
                .disabled(logSearch.isEmpty)
        }
    }

    private var logLevelFilters: some View {
        HStack(spacing: 5) {
            LevelFilter(label: "DBG", on: $showDBG, color: .secondary)
                .help("Show or hide Debug messages")
            LevelFilter(label: "INF", on: $showINF, color: .blue)
                .help("Show or hide Info messages")
            LevelFilter(label: "ERR", on: $showERR, color: .red)
                .help("Show or hide Error messages")
        }
        .fixedSize()
    }

    private var logStatusBar: some View {
        HStack(spacing: 7) {
            if manager.isStreamConnecting {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(manager.isStreaming ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }

            Text(manager.isStreamConnecting ? "Connecting" : manager.isStreaming ? "Live" : "Offline")
                .foregroundStyle(manager.isStreaming ? .primary : .secondary)

            Text("·")
                .foregroundStyle(.tertiary)

            Text("\(visibleLogCount.formatted()) entries")
                .foregroundStyle(.secondary)

            if !bookmarkedEntriesOrdered.isEmpty {
                Button {
                    showBookmarks.toggle()
                } label: {
                    Label("\(bookmarkedEntriesOrdered.count)", systemImage: "bookmark.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .popover(isPresented: $showBookmarks, arrowEdge: .bottom) {
                    bookmarkPopover
                }
            }

            Spacer()

            Button(manager.isStreaming ? "Stop Stream" : "Start Stream") {
                if manager.isStreaming {
                    manager.stopLogStream()
                } else {
                    logAutoScroll = true
                    manager.startLogStream()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(manager.isStreaming ? .red : Color.accentColor)
            .disabled(manager.isStreamConnecting)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private var bookmarkPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Bookmarks")
                .font(.headline)
                .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(bookmarkedEntriesOrdered) { entry in
                        Button {
                            logAutoScroll = false
                            scrollToBookmarkID = entry.id
                            showBookmarks = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bookmarkMenuLabel(for: entry))
                                    .lineLimit(1)
                                Text(entry.source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 240)

            Divider()

            Button("Clear Bookmarks", role: .destructive) {
                bookmarkedIDs.removeAll()
                showBookmarks = false
            }
            .padding(10)
        }
        .frame(width: 320)
    }

    private var logScopeSelection: Binding<LogScope> {
        Binding(
            get: {
                if logsMerged { return .all }
                return activeTab == .reactNative ? .reactNative : .unbound
            },
            set: { scope in
                switch scope {
                case .unbound:
                    logsMerged = false
                    activeTab = .unbound
                case .reactNative:
                    logsMerged = false
                    activeTab = .reactNative
                case .all:
                    logsMerged = true
                    activeTab = .unbound
                }
            }
        )
    }

    private func unreadLevel(for scope: LogScope) -> UnreadLevel {
        switch scope {
        case .unbound: return unboundUnread
        case .reactNative: return reactNativeUnread
        case .all: return allUnread
        }
    }

    private var visibleLogCount: Int {
        filteredEntries.lazy.filter { !$0.isHeader }.count
    }

    private var emptyLogStateMessage: String {
        if !showINF && !showERR && !showDBG {
            return "All log levels are hidden"
        }
        return manager.isStreaming ? "Waiting for logs…" : "Start the stream to begin"
    }

    @ViewBuilder
    private var logScrollView: some View {
        if filteredEntries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: manager.isStreaming ? "waveform.path" : "text.alignleft")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(emptyLogStateMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                if !manager.isStreaming {
                    Text("vbound will show Unbound and React Native output here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LogTextView(
                entries: filteredEntries,
                scrollVersion: scrollVersion,
                autoScroll: logAutoScroll,
                searchQuery: logSearch,
                useRegexFilter: logFilterRegex,
                relativeTimestamps: logRelativeTimestamps,
                bookmarkedIDs: bookmarkedIDs,
                focusedEntryID: currentMatchID,
                scrollToID: scrollToBookmarkID,
                onFilterToSource: { entry in logSearch = entry.source },
                onToggleBookmark: { entry in toggleBookmark(entry) },
                onUserInteraction: { logAutoScroll = false },
                onReachedBottom: { logAutoScroll = true }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            default: levelPass = true
            }
            guard levelPass else { return false }
            return matchesFilter(entry.asString())
        }
    }

    private func matchesFilter(_ text: String) -> Bool {
        guard !logSearch.isEmpty else { return true }
        guard logFilterRegex else {
            return text.localizedCaseInsensitiveContains(logSearch)
        }
        guard let regex = try? NSRegularExpression(pattern: logSearch, options: .caseInsensitive) else {
            return false
        }
        let ns = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
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
                            .frame(minWidth: defaultWindowSize.width - 16, alignment: .topLeading)
                            .padding(.horizontal, 8)
                        Color.clear.frame(height: 1).id("shellBottom")
                    }
                    .padding(.vertical, 4)
                }
                .defaultScrollAnchor(.bottomLeading)
                .background(Color.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { shellInputFocused = true }
                .onChange(of: manager.shellLines.count) { _, _ in
                    if shellAutoScroll {
                        proxy.scrollTo("shellBottom", anchor: .bottomLeading)
                    }
                }
                .onChange(of: manager.shellLines.last) { _, _ in
                    if shellAutoScroll {
                        proxy.scrollTo("shellBottom", anchor: .bottomLeading)
                    }
                }
                .onChange(of: shellScrollVersion) { _, _ in
                    proxy.scrollTo("shellBottom", anchor: .bottomLeading)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 2
                } action: { _, isAtBottom in
                    shellAutoScroll = isAtBottom
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

    private var shellStatusBar: some View {
        HStack(spacing: 7) {
            if manager.isShellConnecting {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Circle()
                    .fill(manager.isShellConnected ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }

            Text(manager.isShellConnecting ? "Connecting" : manager.isShellConnected ? "Connected" : "Offline")
                .foregroundStyle(manager.isShellConnected ? .primary : .secondary)

            Text("·")
                .foregroundStyle(.tertiary)

            Text("mobile@127.0.0.1:2222")
                .foregroundStyle(.secondary)

            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
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
        if manager.isBooting           { return "Booting…" }
        if manager.vphoneDetected      { return "vphone is already running" }
        if !pathValid(vphoneCliPath)   { return "vphone-cli path is invalid — check Settings" }
        return "Boot vphone"
    }

    private var tweakActionHelpText: String {
        if manager.buildPhase.isRunning {
            return manager.activeBuildTarget == .tweak ? "Cancel tweak build" : "Another build is running"
        }
        if !pathValid(unboundPath) { return "Unbound tweak path is invalid — check Settings" }
        return "Build and install tweak"
    }

    private var addonsActionHelpText: String {
        if manager.buildPhase.isRunning {
            return manager.activeBuildTarget == .plugins ? "Cancel addons build" : "Another build is running"
        }
        if !pathValid(unboundPluginsPath) { return "Addon workspace path is invalid — check Settings" }
        return "Build and deploy addons"
    }

    private var mountActionHelpText: String {
        if manager.isMounted { return "Unmount vphone" }
        if manager.isMounting { return "Mounting…" }
        if !manager.sshfsAvailable {
            return "sshfs not found — install macFUSE and sshfs-mac"
        }
        if let error = manager.lastMountError { return "Mount failed: \(error)" }
        return "Mount vphone in Finder"
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

    private func clearConsole() {
        if activeTab == .shell {
            manager.shellBuffer.reset()
            manager.shellLines = manager.shellBuffer.lines
            return
        }
        manager.logLines.removeAll()
        bookmarkedIDs.removeAll()
        searchMatchIndex = 0
    }

    private func copyLogs() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            filteredEntries.map { $0.asString() }.joined(separator: "\n"),
            forType: .string
        )
    }

    private func saveVisibleOutputToFile() {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let outputName = activeTab == .shell ? "shell" : "logs"
        panel.nameFieldStringValue = "vbound-\(outputName)-\(formatter.string(from: Date())).log"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = activeTab == .shell
            ? manager.shellLines.map(\.plain).joined(separator: "\n")
            : filteredEntries.map { $0.asString() }.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func toggleBookmark(_ entry: LogEntry) {
        if bookmarkedIDs.contains(entry.id) {
            bookmarkedIDs.remove(entry.id)
        } else {
            bookmarkedIDs.insert(entry.id)
        }
    }

    private var bookmarkedEntriesOrdered: [LogEntry] {
        filteredEntries.filter { bookmarkedIDs.contains($0.id) }
    }

    private func bookmarkMenuLabel(for entry: LogEntry) -> String {
        let text = entry.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 48 ? String(text.prefix(48)) + "…" : text
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
