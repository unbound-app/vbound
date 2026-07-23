import SwiftUI
import AppKit

private struct PaletteKeyboardMonitor: NSViewRepresentable {
    let moveUp: () -> Void
    let moveDown: () -> Void
    let submit: () -> Void
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(moveUp: moveUp, moveDown: moveDown, submit: submit, dismiss: dismiss)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.moveUp = moveUp
        context.coordinator.moveDown = moveDown
        context.coordinator.submit = submit
        context.coordinator.dismiss = dismiss
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var moveUp: () -> Void
        var moveDown: () -> Void
        var submit: () -> Void
        var dismiss: () -> Void
        private var monitor: Any?

        init(
            moveUp: @escaping () -> Void,
            moveDown: @escaping () -> Void,
            submit: @escaping () -> Void,
            dismiss: @escaping () -> Void
        ) {
            self.moveUp = moveUp
            self.moveDown = moveDown
            self.submit = submit
            self.dismiss = dismiss
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                switch event.keyCode {
                case 125:
                    moveDown()
                case 126:
                    moveUp()
                case 36, 76:
                    submit()
                case 53:
                    dismiss()
                default:
                    return event
                }
                return nil
            }
        }

        func stop() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

private struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let icon: String
    let action: () -> Void

    init(title: String, icon: String, action: @escaping () -> Void) {
        id = "\(icon)-\(title)"
        self.title = title
        self.icon = icon
        self.action = action
    }
}

struct CommandPaletteView: View {
    @Environment(AppController.self) private var manager
    @Environment(\.openSettings) private var openSettings
    @Binding var isPresented: Bool
    @AppStorage("vphoneCliPath") private var vphoneCliPath = NSHomeDirectory() + "/vphone-cli"
    @AppStorage("unboundPath")   private var unboundPath   = NSHomeDirectory() + "/Developer/loader-ios"
    @AppStorage("unboundPluginsPath") private var unboundPluginsPath = NSHomeDirectory() + "/Developer/unbound-plugins"
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private var commands: [PaletteCommand] {
        [
            PaletteCommand(title: manager.vphoneDetected ? "Shut Down vphone" : "Boot vphone",
                            icon: manager.vphoneDetected ? "stop.fill" : "power") {
                if manager.vphoneDetected {
                    NotificationCenter.default.post(name: .requestShutdownVphone, object: nil)
                } else {
                    manager.bootVphone(in: vphoneCliPath)
                }
            },
            PaletteCommand(title: manager.buildPhase.isRunning && manager.activeBuildTarget == .tweak
                            ? "Cancel Tweak Build" : "Build Tweak", icon: "hammer.fill") {
                manager.toggleTweakBuild(in: unboundPath)
            },
            PaletteCommand(title: manager.buildPhase.isRunning && manager.activeBuildTarget == .plugins
                            ? "Cancel Addons Build" : "Build Addons", icon: "puzzlepiece.extension.fill") {
                manager.toggleAddonsBuild(in: unboundPluginsPath)
            },
            PaletteCommand(title: manager.isStreaming ? "Stop Log Stream" : "Start Log Stream",
                            icon: "text.alignleft") {
                if manager.isStreaming { manager.stopLogStream() } else { manager.startLogStream() }
            },
            PaletteCommand(title: manager.isShellConnected ? "Disconnect Shell" : "Connect Shell",
                            icon: "terminal") {
                if manager.isShellConnected { manager.disconnectShell() } else { manager.connectShell() }
            },
            PaletteCommand(title: "Launch Discord", icon: "arrow.clockwise") {
                manager.launchDiscord()
            },
            PaletteCommand(title: manager.isMounted ? "Unmount vphone" : "Mount vphone in Finder",
                            icon: manager.isMounted ? "externaldrive.fill" : "externaldrive") {
                if manager.isMounted { manager.unmountVphone() } else { manager.mountVphone() }
            },
            PaletteCommand(title: "Open Settings", icon: "gearshape") {
                openSettings()
            },
            PaletteCommand(title: "Copy Diagnostic Info", icon: "doc.on.doc") {
                manager.copyDiagnosticInfo()
            },
            PaletteCommand(title: "Test SSH Connection", icon: "network") {
                manager.testSSHConnection()
            },
            PaletteCommand(title: "Show Setup Checklist", icon: "checklist") {
                NotificationCenter.default.post(name: .showOnboardingChecklist, object: nil)
            },
            PaletteCommand(title: "Check for Updates…", icon: "arrow.down.circle") {
                NotificationCenter.default.post(name: .checkForUpdates, object: nil)
            },
        ]
    }

    private var filtered: [PaletteCommand] {
        guard !query.isEmpty else { return commands }
        return commands.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            card
        }
        .task {
            await Task.yield()
            searchFocused = true
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onSubmit { runSelected() }
            }
            .padding(12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                            Button {
                                command.action()
                                close()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: command.icon).frame(width: 16)
                                    Text(command.title)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(index == selectedIndex ? Color.accentColor.opacity(0.15) : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(command.id)
                        }
                        if filtered.isEmpty {
                            Text("No matching commands")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                    }
                }
                .onChange(of: selectedIndex) { _, index in
                    guard filtered.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(filtered[index].id, anchor: .center)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .background(
            PaletteKeyboardMonitor(
                moveUp: { selectedIndex = max(selectedIndex - 1, 0) },
                moveDown: {
                    selectedIndex = min(selectedIndex + 1, max(filtered.count - 1, 0))
                },
                submit: runSelected,
                dismiss: close
            )
        )
    }

    private func runSelected() {
        guard filtered.indices.contains(selectedIndex) else { return }
        filtered[selectedIndex].action()
        close()
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.15)) { isPresented = false }
    }
}
