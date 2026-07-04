import SwiftUI

struct SettingsView: View {
    @State private var showResetConfirm = false

    // Every @AppStorage key surfaced anywhere in Settings (paths/connection/automation/
    // updates/buffers) — deliberately excludes main-window view state like log level
    // filters or merge mode, which a user wouldn't associate with a Settings reset.
    private static let resettableKeys = [
        "vphoneCliPath", "unboundPath", "sshPassword",
        "autoAttachEnabled", "autoStartLogStreamEnabled", "autoConnectShellEnabled",
        "autoCheckForUpdates", "updateCheckIntervalHours",
        "logBufferSize", "shellBufferSize",
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
                Spacer()
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
}

private struct GeneralSettingsView: View {
    @AppStorage("vphoneCliPath") private var vphoneCliPath = NSHomeDirectory() + "/vphone-cli"
    @AppStorage("unboundPath")   private var unboundPath   = NSHomeDirectory() + "/Developer/loader-ios"
    @AppStorage("sshPassword") private var sshPassword = ""

    var body: some View {
        Form {
            Section("Paths") {
                FolderPicker(label: "vphone-cli", path: $vphoneCliPath)
                FolderPicker(label: "Unbound Tweak", path: $unboundPath)
            }

            Section("Connection") {
                SecureField("Device password", text: $sshPassword, prompt: Text("alpine (default)"))
                Text("Used for SSH login and sudo on the vphone device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}

private struct AutomationSettingsView: View {
    @AppStorage("autoAttachEnabled") private var autoAttachEnabled = true
    @AppStorage("autoStartLogStreamEnabled") private var autoStartLogStreamEnabled = false
    @AppStorage("autoConnectShellEnabled")   private var autoConnectShellEnabled   = false

    var body: some View {
        Form {
            Section("Automation") {
                Toggle("Auto-attach to vphone window", isOn: $autoAttachEnabled)
                Toggle("Auto-start log stream on attach", isOn: $autoStartLogStreamEnabled)
                Toggle("Auto-connect shell on attach", isOn: $autoConnectShellEnabled)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}

private struct AdvancedSettingsView: View {
    @AppStorage("autoCheckForUpdates") private var autoCheckForUpdates = true
    @AppStorage("updateCheckIntervalHours") private var updateCheckIntervalHours = 24
    @AppStorage("logBufferSize")   private var logBufferSize   = 2000
    @AppStorage("shellBufferSize") private var shellBufferSize = 2000

    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $autoCheckForUpdates)
                Picker("Check frequency", selection: $updateCheckIntervalHours) {
                    Text("Hourly").tag(1)
                    Text("Daily").tag(24)
                    Text("Weekly").tag(168)
                }
                .disabled(!autoCheckForUpdates)
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
}
