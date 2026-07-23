import SwiftUI

struct SettingsView: View {
    @Environment(AppController.self) private var manager
    @State private var showResetConfirm = false

    // Every @AppStorage key surfaced anywhere in Settings (paths/connection/automation/
    // updates/buffers) — deliberately excludes main-window view state like log level
    // filters or merge mode, which a user wouldn't associate with a Settings reset.
    private static let resettableKeys = [
        "vphoneCliPath", "unboundPath", "unboundPluginsPath", "sshPassword",
        "autoAttachEnabled", "autoStartLogStreamEnabled", "autoConnectShellEnabled",
        "autoCheckForUpdates", "updateCheckIntervalHours",
        "logBufferSize", "shellBufferSize",
        "skippedUpdateVersion",
        "globalHotkeyEnabled", "buildSoundsEnabled", "buildNotificationsEnabled",
        "accentColorChoice",
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralSettingsView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                AutomationSettingsView()
                    .tabItem { Label("Automation", systemImage: "bolt") }
                AdvancedSettingsView()
                    .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            }

            Divider()

            HStack {
                Text(appVersionText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy Diagnostics") { manager.copyDiagnosticInfo() }
                    .buttonStyle(.link)
                    .font(.footnote)
                Button("Reset to Defaults…") { showResetConfirm = true }
                    .buttonStyle(.link)
                    .font(.footnote)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog(
            "Reset all settings to their defaults?",
            isPresented: $showResetConfirm
        ) {
            Button("Reset", role: .destructive) {
                for key in Self.resettableKeys { UserDefaults.standard.removeObject(forKey: key) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This resets paths, the device password, automation, update, and buffer settings back to their defaults.")
        }
    }

    // For quick reference against CHANGELOG.md/GitHub releases when reporting a bug —
    // there was previously nowhere in the app itself that showed this.
    private var appVersionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "vbound \(version) (\(build))"
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppController.self) private var manager
    @AppStorage("vphoneCliPath") private var vphoneCliPath = NSHomeDirectory() + "/vphone-cli"
    @AppStorage("unboundPath")   private var unboundPath   = NSHomeDirectory() + "/Developer/loader-ios"
    @AppStorage("unboundPluginsPath") private var unboundPluginsPath = NSHomeDirectory() + "/Developer/unbound-plugins"
    @AppStorage("sshPassword") private var sshPassword = ""
    @AppStorage("accentColorChoice") private var accentColorChoice = AccentChoice.system.rawValue
    @State private var isPasswordVisible = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Accent Color", selection: $accentColorChoice) {
                    ForEach(AccentChoice.allCases) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
            }

            Section("Paths") {
                FolderPicker(label: "vphone-cli", path: $vphoneCliPath)
                FolderPicker(label: "Unbound Tweak", path: $unboundPath)
                FolderPicker(label: "Addon Workspace", path: $unboundPluginsPath)
            }

            Section("Connection") {
                HStack {
                    Group {
                        if isPasswordVisible {
                            TextField("Device password", text: $sshPassword, prompt: Text("alpine (default)"))
                        } else {
                            SecureField("Device password", text: $sshPassword, prompt: Text("alpine (default)"))
                        }
                    }
                    Button {
                        isPasswordVisible.toggle()
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(isPasswordVisible ? "Hide password" : "Show password")
                }
                HStack {
                    Text("Used for SSH login and sudo on the vphone device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    testConnectionButton
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var testConnectionButton: some View {
        switch manager.sshTestState {
        case .idle:
            Button("Test Connection") { manager.testSSHConnection() }
                .buttonStyle(.link)
                .font(.footnote)
        case .testing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Testing…").font(.footnote).foregroundStyle(.secondary)
            }
        case .success:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case .failure(let message):
            Label("Failed", systemImage: "xmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .help(message)
        }
    }
}

private struct AutomationSettingsView: View {
    @Environment(AppController.self) private var manager
    @AppStorage("autoAttachEnabled") private var autoAttachEnabled = true
    @AppStorage("autoStartLogStreamEnabled") private var autoStartLogStreamEnabled = false
    @AppStorage("autoConnectShellEnabled")   private var autoConnectShellEnabled   = false
    @AppStorage("globalHotkeyEnabled") private var globalHotkeyEnabled = false

    var body: some View {
        Form {
            Section("Automation") {
                Toggle("Auto-attach to vphone window", isOn: $autoAttachEnabled)
                Toggle("Auto-start log stream on attach", isOn: $autoStartLogStreamEnabled)
                Toggle("Auto-connect shell on attach", isOn: $autoConnectShellEnabled)
            }

            Section("Shortcuts") {
                Toggle("Global hotkey (\(AppController.hotkeyLabel)) to show/hide vbound",
                       isOn: $globalHotkeyEnabled)
                .onChange(of: globalHotkeyEnabled) { _, enabled in
                    if enabled { manager.enableGlobalHotkey() } else { manager.disableGlobalHotkey() }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}

private struct AdvancedSettingsView: View {
    @AppStorage("autoCheckForUpdates") private var autoCheckForUpdates = true
    @AppStorage("updateCheckIntervalHours") private var updateCheckIntervalHours = 24
    @AppStorage("skippedUpdateVersion") private var skippedUpdateVersion = ""
    @AppStorage("logBufferSize")   private var logBufferSize   = 2000
    @AppStorage("shellBufferSize") private var shellBufferSize = 2000
    @AppStorage("buildSoundsEnabled") private var buildSoundsEnabled = true
    @AppStorage("buildNotificationsEnabled") private var buildNotificationsEnabled = true

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Play a sound when a build finishes", isOn: $buildSoundsEnabled)
                Toggle("Notify when a build finishes in the background", isOn: $buildNotificationsEnabled)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $autoCheckForUpdates)
                Picker("Check frequency", selection: $updateCheckIntervalHours) {
                    Text("Hourly").tag(1)
                    Text("Daily").tag(24)
                    Text("Weekly").tag(168)
                }
                .disabled(!autoCheckForUpdates)

                // "Skip This Version" in the update sheet has no other way to undo —
                // without this, a misclick silently suppresses that version's prompt
                // forever with no in-app recovery.
                if !skippedUpdateVersion.isEmpty {
                    HStack {
                        Text("Skipped version \(skippedUpdateVersion)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { skippedUpdateVersion = "" }
                            .buttonStyle(.link)
                            .font(.footnote)
                    }
                }
            }

            Section("Buffers") {
                Picker("Log stream buffer", selection: $logBufferSize) {
                    Text("500 lines").tag(500)
                    Text("1,000 lines").tag(1000)
                    Text("2,000 lines").tag(2000)
                    Text("5,000 lines").tag(5000)
                }
                Picker("Shell scrollback buffer", selection: $shellBufferSize) {
                    Text("500 lines").tag(500)
                    Text("1,000 lines").tag(1000)
                    Text("2,000 lines").tag(2000)
                    Text("5,000 lines").tag(5000)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}

#Preview {
    SettingsView()
        .environment(AppController())
}
