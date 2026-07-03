import SwiftUI

struct SettingsView: View {
    @AppStorage("vphoneCliPath") private var vphoneCliPath = NSHomeDirectory() + "/vphone-cli"
    @AppStorage("unboundPath")   private var unboundPath   = NSHomeDirectory() + "/Developer/loader-ios"
    @AppStorage("sshPassword") private var sshPassword = ""
    @AppStorage("autoAttachEnabled") private var autoAttachEnabled = true
    @AppStorage("autoStartLogStreamEnabled") private var autoStartLogStreamEnabled = false
    @AppStorage("autoConnectShellEnabled")   private var autoConnectShellEnabled   = false
    @AppStorage("autoCheckForUpdates") private var autoCheckForUpdates = true
    @AppStorage("updateCheckIntervalHours") private var updateCheckIntervalHours = 24
    @AppStorage("logBufferSize")   private var logBufferSize   = 2000
    @AppStorage("shellBufferSize") private var shellBufferSize = 2000

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

            Section("Automation") {
                Toggle("Auto-attach to vphone window", isOn: $autoAttachEnabled)
                Toggle("Auto-start log stream on attach", isOn: $autoStartLogStreamEnabled)
                Toggle("Auto-connect shell on attach", isOn: $autoConnectShellEnabled)
            }

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
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    SettingsView()
}
