import SwiftUI
import AppKit
import AppUpdater
import Version

private let cardSize = NSSize(width: 600, height: 505)

struct ContentView: View {
    @Environment(AppController.self) var manager
    @EnvironmentObject private var appUpdater: AppUpdater
    @AppStorage("vphoneCliPath") private var vphoneCliPath = NSHomeDirectory() + "/vphone-cli"
    @AppStorage("unboundPath")   private var unboundPath   = NSHomeDirectory() + "/Developer/loader-ios"
    @AppStorage("skippedUpdateVersion") private var skippedUpdateVersion = ""
    @State private var showUpdateSheet = false

    @State private var logSearch         = ""
    @State private var showINF           = true
    @State private var showERR           = true
    @State private var showDBG           = true
    @State private var highlightStartIdx = -1
    @State private var highlightTask: Task<Void, Never>? = nil  // #11
    @State private var activeTab         : LogTab = .unbound
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
        .background(
            WindowAccessor { window in
                window.styleMask.remove(.resizable)
                window.contentMinSize = cardSize
                window.contentMaxSize = cardSize
                window.setContentSize(cardSize)
                window.level = .floating
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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
        )
        .onChange(of: manager.logLines.count) { old, new in
            let delta = new - old
            guard delta > 0 else { return }
            scrollVersion += 1
            highlightStartIdx = max(0, filteredEntries.count - delta)
            // Cancel any in-flight fade so a burst of new entries resets the timer (#11)
            highlightTask?.cancel()
            highlightTask = Task {
                try? await Task.sleep(for: .milliseconds(1400))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.9)) { highlightStartIdx = -1 }
            }
            markUnread(manager.logLines[old..<new])
        }
        // Cancel highlight when the filter changes — the index is relative to filteredEntries
        // and would point to the wrong rows after the filter updates (#11)
        .onChange(of: logSearch)  { _, _ in cancelHighlight() }
        .onChange(of: showINF)    { _, _ in cancelHighlight() }
        .onChange(of: showERR)    { _, _ in cancelHighlight() }
        .onChange(of: showDBG)    { _, _ in cancelHighlight() }
        .onChange(of: activeTab)  { _, new in
            cancelHighlight()
            if new == .unbound     { unboundUnread     = .none }
            if new == .reactNative { reactNativeUnread = .none }
        }
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
        .onReceive(appUpdater.$state) { state in
            if case .none = state { return }
            guard state.release?.tagName.description != skippedUpdateVersion else { return }
            if !showUpdateSheet { withAnimation(.easeOut(duration: 0.15)) { showUpdateSheet = true } }
        }
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

            Spacer(minLength: 8)

            Button {
                manager.bootVphone(in: vphoneCliPath)
            } label: {
                Label("Boot", systemImage: "power")
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.vphoneDetected || !pathValid(vphoneCliPath))
            .help("Boot vphone")

            Button {
                showShutdownConfirm = true
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(!manager.vphoneDetected)
            .help("Shut down vphone")
            .confirmationDialog("Shut down vphone?", isPresented: $showShutdownConfirm) {
                Button("Shut Down", role: .destructive) { manager.shutdownVphone() }
                Button("Cancel",    role: .cancel) {}
            } message: {
                Text("This will power off the virtual phone.")
            }

            Button {
                manager.launchDiscord()
            } label: {
                Label { Text("Discord") } icon: { Image("Discord") }
            }
            .buttonStyle(.bordered)
            .help("Launch Discord")

            Button {
                manager.buildUnbound(in: unboundPath)
            } label: {
                Label("Build", systemImage: "hammer.fill")
            }
            .buttonStyle(.bordered)
            .disabled(manager.buildPhase.isRunning || !pathValid(unboundPath))
            .help("Build & Install")

            Divider().frame(height: 16)

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.bordered)
            .help("Settings")
        }
        .controlSize(.small)
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
                tabButton(.unbound,     icon: "Unbound",      label: "Unbound",      unread: unboundUnread)
                tabButton(.reactNative, icon: "React Native", label: "React Native", unread: reactNativeUnread)
                tabButton(.shell,       icon: "terminal",     label: "Shell",        unread: .none)
            }
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
                if !logSearch.isEmpty {
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

            Group {
                Button { manager.logLines = [] } label: {
                    Image(systemName: "trash")
                }
                .help("Clear all logs")

                Button { copyLogs() } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy visible logs to clipboard")

                Button {
                    scrollVersion += 1
                    guard !filteredEntries.isEmpty else { return }
                    highlightStartIdx = max(0, filteredEntries.count - 5)
                    highlightTask?.cancel()  // #11
                    highlightTask = Task {
                        try? await Task.sleep(for: .milliseconds(1400))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.9)) { highlightStartIdx = -1 }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Scroll to newest log entry")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14))

            Divider().frame(height: 16)

            HStack(spacing: 6) {
                Circle()
                    .fill(manager.isStreaming ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
                    .animation(.easeInOut(duration: 0.25), value: manager.isStreaming)
                Button(manager.isStreaming ? "Stop" : "Stream") {
                    if manager.isStreaming { manager.stopLogStream() }
                    else                  { manager.startLogStream() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(manager.isStreaming ? .red : Color.accentColor)
                .help(manager.isStreaming ? "Stop live log stream" : "Start live log stream")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var logScrollView: some View {
        if filteredEntries.isEmpty {
            Text(manager.isStreaming ? "Waiting for logs…" : "Tap Stream to start")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LogTextView(
                entries: filteredEntries,
                highlightStartIdx: highlightStartIdx,
                scrollVersion: scrollVersion,
                searchQuery: logSearch,
                onFilterToSource: { entry in logSearch = entry.source }
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

    @ViewBuilder
    private func tabLabel(icon: String, label: String, unread: UnreadLevel) -> some View {
        Label {
            Text(label)
        } icon: {
            if Self.customSymbolNames.contains(icon) {
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
        let target: LogSubsystem = activeTab == .unbound ? .unbound : .reactNative
        return manager.logLines.filter { entry in
            if entry.isHeader { return true }
            if let sub = entry.subsystem, sub != target { return false }
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

    // MARK: - Shell toolbar + view

    @ViewBuilder
    private var shellToolbar: some View {
        HStack(spacing: 6) {
            // SSH target — expands like the log search field
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 12))
                Text(manager.isShellConnected ? "mobile@127.0.0.1:2222" : "not connected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Group {
                ForEach(terminalControlKeys, id: \.label) { control in
                    Button {
                        manager.sendShellControlByte(control.byte)
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

                Button {
                    manager.shellBuffer.reset()
                    manager.shellLines = manager.shellBuffer.lines
                    if manager.isShellConnected { manager.sendShellInput("") }
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear terminal output")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14))
            .layoutPriority(1)

            Divider().frame(height: 16)

            HStack(spacing: 6) {
                Circle()
                    .fill(manager.isShellConnected ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
                    .animation(.easeInOut(duration: 0.25), value: manager.isShellConnected)
                Button(manager.isShellConnected ? "Disconnect" : "Connect") {
                    if manager.isShellConnected { manager.disconnectShell() }
                    else                        { manager.connectShell() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(manager.isShellConnected ? .red : Color.accentColor)
                .help(manager.isShellConnected ? "Disconnect SSH session" : "Connect SSH session")
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
            guard activeTab != tab else { continue }
            let level: UnreadLevel = entry.level == "ERR" ? .error : .info
            if sub == .unbound {
                if level == .error || unboundUnread == .none { unboundUnread = level }
            } else {
                if level == .error || reactNativeUnread == .none { reactNativeUnread = level }
            }
        }
    }

    private func cancelHighlight() {  // #11
        highlightTask?.cancel()
        highlightTask = nil
        highlightStartIdx = -1
    }

    private func pathValid(_ path: String) -> Bool {  // #12
        AppController.pathValid(path)
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
    private let terminalControlKeys: [(label: String, byte: UInt8, help: String)] = [
        ("^C",  0x03, "Send Ctrl+C (interrupt)"),
        ("^D",  0x04, "Send Ctrl+D (EOF)"),
        ("^Z",  0x1A, "Send Ctrl+Z (suspend)"),
        ("^L",  0x0C, "Clear screen"),
        ("Tab", 0x09, "Send Tab (autocomplete)"),
    ]

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

    private var statusText: String {
        if manager.isAttached     { return "Attached · vphone running" }
        if manager.vphoneDetected { return "vphone running" }
        return "vphone not running"
    }
}

#Preview {
    ContentView()
        .environment(AppController())
}
