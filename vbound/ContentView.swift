import SwiftUI
import AppKit
import AppUpdater

private let cardSize = NSSize(width: 600, height: 660)

struct ContentView: View {
    @Environment(AppController.self) var manager
    @EnvironmentObject private var appUpdater: AppUpdater
    @AppStorage("vphoneCliPath") private var vphoneCliPath = NSHomeDirectory() + "/vphone-cli"
    @AppStorage("unboundPath")   private var unboundPath   = NSHomeDirectory() + "/Developer/loader-ios"
    @State private var showUpdateSheet = false

    @State private var logSearch         = ""
    @State private var showINF           = true
    @State private var showERR           = true
    @State private var showDBG           = true
    @State private var highlightStartIdx = -1
    @State private var activeTab         : LogTab = .unbound
    @State private var scrollVersion        = 0
    @State private var showShutdownConfirm  = false
    @State private var shellInput           = ""
    @State private var shellScrollVersion   = 0
    @FocusState private var shellInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
            Divider()
            actionButtons
            Divider()
            midSection
            Divider()
            logsSection
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .background(
            WindowAccessor { window in
                window.styleMask.remove(.resizable)
                window.contentMinSize = cardSize
                window.contentMaxSize = cardSize
                window.setContentSize(cardSize)
                window.level = .floating
                window.collectionBehavior = [.canJoinAllSpaces, .transient]
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
            Task {
                try? await Task.sleep(for: .milliseconds(1400))
                withAnimation(.easeOut(duration: 0.9)) { highlightStartIdx = -1 }
            }
        }
        .sheet(isPresented: $showUpdateSheet) {
            UpdateSheet()
                .environmentObject(appUpdater)
        }
        .onReceive(NotificationCenter.default.publisher(for: .checkForUpdates)) { _ in
            showUpdateSheet = true
        }
        .onReceive(appUpdater.$state) { state in
            if case .none = state { return }
            if !showUpdateSheet { showUpdateSheet = true }
        }
    }

    // MARK: - Status strip

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
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Action buttons

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    manager.bootVphone(in: vphoneCliPath)
                } label: {
                    Label("Boot vphone", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.vphoneDetected)

                Button {
                    showShutdownConfirm = true
                } label: {
                    Label("Shut Down", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!manager.vphoneDetected)
                .confirmationDialog("Shut down vphone?", isPresented: $showShutdownConfirm) {
                    Button("Shut Down", role: .destructive) { manager.shutdownVphone() }
                    Button("Cancel",    role: .cancel) {}
                } message: {
                    Text("This will power off the virtual phone.")
                }
            }

            HStack(spacing: 10) {
                Button {
                    manager.launchDiscord()
                } label: {
                    Label("Launch Discord", systemImage: "bubble.left.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    manager.buildUnbound(in: unboundPath)
                } label: {
                    Label("Build & Install", systemImage: "hammer.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(manager.buildPhase.isRunning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Mid section (folders ↔ progress, animated)

    @ViewBuilder
    private var midSection: some View {
        ZStack(alignment: .topLeading) {
            folderRow
                .opacity(manager.buildPhase.isActive ? 0 : 1)
                .allowsHitTesting(!manager.buildPhase.isActive)
                .animation(.easeInOut(duration: 0.3), value: manager.buildPhase.isActive)

            progressSection
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(manager.buildPhase.isActive ? 1 : 0)
                .allowsHitTesting(manager.buildPhase.isActive)
                .animation(.easeInOut(duration: 0.3), value: manager.buildPhase.isActive)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 80, maxHeight: 80)
    }

    @ViewBuilder
    private var folderRow: some View {
        HStack(spacing: 12) {
            FolderPicker(label: "vphone-cli", path: $vphoneCliPath)
            FolderPicker(label: "Unbound Tweak", path: $unboundPath)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !manager.buildPhase.label.isEmpty {
                Text(manager.buildPhase.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if manager.buildPhase.isRunning {
                if case .building = manager.buildPhase {
                    ProgressView(value: manager.buildProgress).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            if manager.buildPhase.isActive && !manager.buildLog.isEmpty {
                Text(manager.buildLog)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.75))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                tabButton(.unbound,     icon: "puzzlepiece.extension",                   label: "Unbound")
                tabButton(.reactNative, icon: "chevron.left.forwardslash.chevron.right", label: "React Native")
                tabButton(.shell,       icon: "terminal",                                label: "Shell")
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
                    Task {
                        try? await Task.sleep(for: .milliseconds(1400))
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
                scrollVersion: scrollVersion
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func tabButton(_ tab: LogTab, icon: String, label: String) -> some View {
        if activeTab == tab {
            Button { activeTab = tab } label: {
                Label(label, systemImage: icon).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button { activeTab = tab } label: {
                Label(label, systemImage: icon).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
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
        HStack(spacing: 8) {
            // SSH target — expands like the log search field
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 12))
                Text(manager.isShellConnected ? "mobile@127.0.0.1:2222" : "not connected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Group {
                Button { manager.sendShellInterrupt() } label: {
                    Image(systemName: "stop.circle")
                }
                .help("Send Ctrl+C (interrupt)")
                .disabled(!manager.isShellConnected)

                Divider().frame(height: 16)

                Button { shellScrollVersion += 1 } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .help("Scroll to bottom")

                Button { copyShellOutput() } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy shell output to clipboard")

                Button {
                    manager.shellLines = []
                    if manager.isShellConnected { manager.sendShellInput("") }
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear terminal output")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14))

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
                        Text(manager.shellLines.map { $0.isEmpty ? " " : $0 }.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.white)
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
                        manager.sendShellInput(shellInput)
                        shellInput = ""
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(white: 0.1))
            .environment(\.colorScheme, .dark)
        }
    }

    private func copyShellOutput() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            manager.shellLines.joined(separator: "\n"),
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
