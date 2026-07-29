import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppController.self) private var manager
    @State private var showResetConfirm = false

    // Every @AppStorage key surfaced anywhere in Settings (paths/connection/automation/
    // updates/buffers) — deliberately excludes main-window view state like log level
    // filters or merge mode, which a user wouldn't associate with a Settings reset.
    private static let resettableKeys = [
        "vphoneCliPath", "vphoneVMName", "unboundPath", "unboundPluginsPath", "sshPassword",
        "autoAttachEnabled", "autoStartLogStreamEnabled", "autoConnectShellEnabled", "shutdownVphoneOnQuit",
        "autoCheckForUpdates", "updateCheckIntervalHours",
        "logBufferSize", "shellBufferSize",
        "skippedUpdateVersion",
        "globalHotkeyEnabled", "buildSoundsEnabled", "buildNotificationsEnabled",
        "accentColorChoice",
        "selectedVphoneUDID",
        "workspaceProfilesData", "activeWorkspaceProfileID",
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralSettingsView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                WorkspaceProfilesSettingsView()
                    .tabItem { Label("Profiles", systemImage: "rectangle.stack") }
                AutomationSettingsView()
                    .tabItem { Label("Automation", systemImage: "bolt") }
                AdvancedSettingsView()
                    .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                ReadinessSettingsView()
                    .tabItem { Label("Readiness", systemImage: "checklist") }
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

private struct WorkspaceProfilesSettingsView: View {
    @Environment(AppController.self) private var manager
    @AppStorage("vphoneCliPath") private var vphoneCliPath = AppController.defaultVphoneCLIPath
    @AppStorage("vphoneVMName") private var vphoneVMName = AppController.defaultVphoneVMName
    @AppStorage("unboundPath") private var unboundPath = NSHomeDirectory() + "/Developer/loader-ios"
    @AppStorage("unboundPluginsPath") private var unboundPluginsPath = NSHomeDirectory() + "/Developer/unbound-plugins"
    @AppStorage("sshPassword") private var sshPassword = ""
    @AppStorage("workspaceProfilesData") private var profilesData = Data()
    @AppStorage("activeWorkspaceProfileID") private var activeProfileID = ""
    @State private var profiles: [WorkspaceProfile] = []
    @State private var showNewProfile = false
    @State private var newProfileName = ""

    var body: some View {
        Form {
            Section("Workspace Profiles") {
                if profiles.isEmpty {
                    Text("Save the current paths, password, and selected vphone as a reusable profile.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Active Profile", selection: $activeProfileID) {
                        Text("No active profile").tag("")
                        ForEach(profiles) { profile in
                            Text(profile.name).tag(profile.id.uuidString)
                        }
                    }
                    .onChange(of: activeProfileID) { _, id in
                        guard let profile = profiles.first(where: { $0.id.uuidString == id }) else { return }
                        apply(profile)
                    }
                    .disabled(manager.buildPhase.isRunning)
                }

                HStack {
                    Button("Save Current as…") {
                        newProfileName = ""
                        showNewProfile = true
                    }
                    .disabled(manager.buildPhase.isRunning)
                    Button("Update Active") { updateActiveProfile() }
                        .disabled(activeProfileID.isEmpty || manager.buildPhase.isRunning)
                    Button("Delete Active", role: .destructive) { deleteActiveProfile() }
                        .disabled(activeProfileID.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .onAppear(perform: loadProfiles)
        .alert("Save Workspace Profile", isPresented: $showNewProfile) {
            TextField("Profile name", text: $newProfileName)
            Button("Save") { saveNewProfile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Profiles include paths, the device password, and the selected vphone.")
        }
    }

    private func loadProfiles() {
        profiles = (try? JSONDecoder().decode([WorkspaceProfile].self, from: profilesData)) ?? []
    }

    private func persistProfiles() {
        profilesData = (try? JSONEncoder().encode(profiles)) ?? Data()
    }

    private func currentProfile(name: String, id: UUID = UUID()) -> WorkspaceProfile {
        WorkspaceProfile(
            id: id,
            name: name,
            vphoneCliPath: vphoneCliPath,
            vphoneVMName: vphoneVMName,
            unboundPath: unboundPath,
            unboundPluginsPath: unboundPluginsPath,
            sshPassword: sshPassword,
            selectedVphoneUDID: manager.selectedVphoneUDID
        )
    }

    private func saveNewProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let profile = currentProfile(name: name)
        profiles.append(profile)
        activeProfileID = profile.id.uuidString
        persistProfiles()
    }

    private func updateActiveProfile() {
        guard let index = profiles.firstIndex(where: { $0.id.uuidString == activeProfileID }) else { return }
        profiles[index] = currentProfile(name: profiles[index].name, id: profiles[index].id)
        persistProfiles()
    }

    private func deleteActiveProfile() {
        profiles.removeAll { $0.id.uuidString == activeProfileID }
        activeProfileID = ""
        persistProfiles()
    }

    private func apply(_ profile: WorkspaceProfile) {
        vphoneCliPath = profile.vphoneCliPath
        vphoneVMName = profile.vphoneVMName ?? AppController.defaultVphoneVMName
        unboundPath = profile.unboundPath
        unboundPluginsPath = profile.unboundPluginsPath
        sshPassword = profile.sshPassword
        if let udid = profile.selectedVphoneUDID { manager.selectVphone(udid) }
        else { manager.clearSelectedVphone() }
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppController.self) private var manager
    @AppStorage("vphoneCliPath") private var vphoneCliPath = AppController.defaultVphoneCLIPath
    @AppStorage("vphoneVMName") private var vphoneVMName = AppController.defaultVphoneVMName
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
                ExecutablePicker(label: "vphone-cli", path: $vphoneCliPath)
                TextField("VM Name", text: $vphoneVMName)
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
        SSHTestStatusView(manager: manager)
    }
}

private struct SSHTestStatusView: View {
    let manager: AppController

    var body: some View {
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
    @AppStorage("shutdownVphoneOnQuit") private var shutdownVphoneOnQuit = false
    @AppStorage("globalHotkeyEnabled") private var globalHotkeyEnabled = false

    var body: some View {
        Form {
            Section("Automation") {
                Toggle("Auto-attach to vphone window", isOn: $autoAttachEnabled)
                Toggle("Auto-start log stream on attach", isOn: $autoStartLogStreamEnabled)
                Toggle("Auto-connect shell on attach", isOn: $autoConnectShellEnabled)
                Toggle("Shut down vphone when quitting vbound", isOn: $shutdownVphoneOnQuit)
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

private struct ReadinessItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let isReady: Bool
    let repairCommand: String?
}

private struct ReadinessSettingsView: View {
    @Environment(AppController.self) private var manager
    @AppStorage("vphoneCliPath") private var vphoneCliPath = AppController.defaultVphoneCLIPath
    @AppStorage("unboundPath") private var unboundPath = NSHomeDirectory() + "/Developer/loader-ios"
    @AppStorage("unboundPluginsPath") private var unboundPluginsPath = NSHomeDirectory() + "/Developer/unbound-plugins"
    @State private var items: [ReadinessItem] = []
    @State private var isChecking = false

    var body: some View {
        Form {
            Section("Development Readiness") {
                if isChecking && items.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking this Mac…").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.isReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(item.isReady ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                Text(item.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let repairCommand = item.repairCommand, !item.isReady {
                                Button("Copy Fix") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(repairCommand, forType: .string)
                                }
                                .buttonStyle(.link)
                                .font(.footnote)
                            }
                        }
                    }
                }
                Button(isChecking ? "Checking…" : "Refresh") { check() }
                    .disabled(isChecking)
            }

            Section("Connection") {
                HStack {
                    Text(manager.vphoneDetected ? "vphone is running" : "vphone is not running")
                    Spacer()
                    SSHTestStatusView(manager: manager)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .task { check() }
    }

    private func check() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            let expandedVphone = (vphoneCliPath as NSString).expandingTildeInPath
            let expandedTweak = (unboundPath as NSString).expandingTildeInPath
            let expandedAddons = (unboundPluginsPath as NSString).expandingTildeInPath
            async let pymobiledevice3 = manager.runCapture(args: ["which", "pymobiledevice3"], timeout: 5)
            async let sshpass = manager.runCapture(args: ["which", "sshpass"], timeout: 5)
            async let bunx = manager.runCapture(args: ["which", "bunx"], timeout: 5)
            async let gmake = manager.runCapture(args: ["which", "gmake"], timeout: 5)
            async let make = manager.runCapture(args: ["which", "make"], timeout: 5)
            async let ubd = manager.run(
                args: ["bunx", "ubd", "--version"],
                workingDirectory: URL(fileURLWithPath: expandedAddons),
                timeout: 10
            )
            let hasPymobiledevice3 = !(await pymobiledevice3).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasSshpass = !(await sshpass).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasBunx = !(await bunx).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasGmake = !(await gmake).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasSystemMake = !(await make).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasMake = hasGmake || hasSystemMake
            let hasUbd = await ubd
            items = [
                ReadinessItem(id: "vphone", title: "vphone-cli", detail: expandedVphone, isReady: AppController.executableValid(expandedVphone), repairCommand: nil),
                ReadinessItem(id: "tweak", title: "Unbound tweak workspace", detail: expandedTweak, isReady: FileManager.default.fileExists(atPath: (expandedTweak as NSString).appendingPathComponent("Makefile")), repairCommand: nil),
                ReadinessItem(id: "addons", title: "Addon workspace", detail: expandedAddons, isReady: FileManager.default.fileExists(atPath: (expandedAddons as NSString).appendingPathComponent("plugins")), repairCommand: nil),
                ReadinessItem(id: "pymobiledevice3", title: "pymobiledevice3", detail: hasPymobiledevice3 ? "Ready" : "Required for device discovery and log streaming", isReady: hasPymobiledevice3, repairCommand: "pipx install pymobiledevice3"),
                ReadinessItem(id: "sshpass", title: "sshpass", detail: hasSshpass ? "Ready" : "Required for SSH deployment", isReady: hasSshpass, repairCommand: "brew install sshpass"),
                ReadinessItem(id: "make", title: "make", detail: hasMake ? "Ready" : "Required to package the tweak", isReady: hasMake, repairCommand: "xcode-select --install"),
                ReadinessItem(id: "bunx", title: "bunx ubd", detail: hasUbd ? "Ready" : hasBunx ? "The addon workspace cannot run ubd" : "Required to build addons", isReady: hasUbd, repairCommand: hasBunx ? "bun install" : "curl -fsSL https://bun.sh/install | bash"),
            ]
            isChecking = false
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppController())
}
