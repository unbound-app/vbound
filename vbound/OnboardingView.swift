import SwiftUI

private enum HostSecurityPath: String, CaseIterable, Identifiable {
    case amfiDisabled
    case amfidont

    var id: String { rawValue }
    var title: String { self == .amfiDisabled ? "AMFI disabled" : "Use vphone-amfidont" }
    var detail: String {
        self == .amfiDisabled
            ? "Requires SIP disabled and amfi_get_out_of_my_way=1 after rebooting from Recovery."
            : "Requires SIP debug relaxation and research guests in Recovery, then allowlists vphone-cli."
    }
}

struct OnboardingView: View {
    @Environment(AppController.self) private var manager
    @Binding var isPresented: Bool
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("vphoneCliPath") private var vphoneCliPath = AppController.defaultVphoneCLIPath
    @AppStorage("vphoneVMName") private var vphoneVMName = AppController.defaultVphoneVMName
    @State private var securityPath: HostSecurityPath = .amfidont
    @State private var recoveryConfirmed = false
    @State private var amfidontConfigured = false
    @State private var isWorking = false
    @State private var setupOutput = ""

    private var legacyVMURL: URL { URL(fileURLWithPath: NSHomeDirectory() + "/vphone-cli/vm") }
    private var vmURL: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.vphone/VMs/\(vphoneVMName)") }
    private var hasLegacyVM: Bool { FileManager.default.fileExists(atPath: legacyVMURL.path) }
    private var hasVM: Bool { FileManager.default.fileExists(atPath: vmURL.path) }
    private var hasCLI: Bool { AppController.executableValid(vphoneCliPath) }
    private var hasMCP: Bool { MCPInstaller.isInstalled }
    private var hasLaunchWatcher: Bool { VphoneLaunchAgent.isInstalled }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("Set up vbound").font(.headline)
                Text(hasLegacyVM && !hasVM ? "Your legacy vphone must be migrated before vbound can continue." : "vbound needs a Homebrew vphone-cli installation and a configured VM.")
                    .font(.footnote).foregroundStyle(.secondary)
                GroupBox("Host security path") {
                    Picker("Host security path", selection: $securityPath) {
                        ForEach(HostSecurityPath.allCases) { path in Text(path.title).tag(path) }
                    }
                    .pickerStyle(.radioGroup)
                    Text(securityPath.detail).font(.footnote).foregroundStyle(.secondary)
                    Toggle("I completed the required Recovery-mode steps and rebooted", isOn: $recoveryConfirmed)
                }
                GroupBox("vphone") {
                    TextField("VM name", text: $vphoneVMName)
                    if hasLegacyVM && !hasVM {
                        Button("Migrate legacy VM") { migrateLegacyVM() }.disabled(isWorking)
                    } else if !hasCLI {
                        Button("Install vphone-cli and dependencies") { installDependencies() }.disabled(isWorking || !recoveryConfirmed)
                    } else if !hasVM {
                        Button("Create jailbroken VM") { createVM() }.disabled(isWorking || !recoveryConfirmed)
                    } else {
                        Label("vphone is ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                if securityPath == .amfidont, hasCLI {
                    if amfidontConfigured {
                        Label("vphone-amfidont configured", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Run vphone-amfidont") { allowlistVphone() }.disabled(isWorking || !recoveryConfirmed)
                    }
                }
                GroupBox("Coding agents") {
                    Text("Install vbound's MCP server into Codex and Claude Code so both agents can control the VM, device, builds, logs, and shell.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if hasMCP {
                        Label("MCP server installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Install MCP server") { installMCP() }.disabled(isWorking || !hasCLI || !hasVM)
                    }
                }
                GroupBox("Vphone automation") {
                    Text("Launch vbound whenever a vphone starts and enlarge the phone window without entering full screen.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if hasLaunchWatcher {
                        Label("Launch watcher installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Install launch watcher") { installLaunchWatcher() }.disabled(isWorking || !hasCLI || !hasVM)
                    }
                }
                if !setupOutput.isEmpty { Text(setupOutput).font(.caption.monospaced()).lineLimit(5) }
                Button("Continue") { complete() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasCLI || !hasVM || !hasMCP || !hasLaunchWatcher || !recoveryConfirmed || (securityPath == .amfidont && !amfidontConfigured) || isWorking)
            }
            .padding(20).frame(width: 480)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func migrateLegacyVM() {
        isWorking = true
        try? FileManager.default.createDirectory(at: vmURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        Task {
            let ok = await manager.run(args: ["/bin/cp", "-cR", legacyVMURL.path, vmURL.path], onOutput: { lines in setupOutput = lines.suffix(5).joined(separator: "\n") })
            isWorking = false
            if !ok { setupOutput = "Migration failed." }
        }
    }

    private func installDependencies() {
        isWorking = true
        Task {
            let packages = ["python@3.13", "aria2", "wget", "gnu-tar", "openssl@3", "ldid-procursus", "sshpass", "keystone", "libusb", "ipsw", "zstd", "make", "pipx"]
            let tools = await manager.run(args: ["brew", "install"] + packages, onOutput: { lines in setupOutput = lines.suffix(5).joined(separator: "\n") })
            guard tools else { isWorking = false; setupOutput = "Dependency setup failed."; return }
            let cli = await manager.run(args: ["brew", "install", "zqxwce/tap/vphone-cli"], onOutput: { lines in setupOutput = lines.suffix(5).joined(separator: "\n") })
            guard cli else { isWorking = false; setupOutput = "Dependency setup failed."; return }
            let pmd = await manager.run(args: ["pipx", "install", "pymobiledevice3"], onOutput: { lines in setupOutput = lines.suffix(5).joined(separator: "\n") })
            guard pmd else { isWorking = false; setupOutput = "Dependency setup failed."; return }
            let setup = await manager.run(args: [AppController.defaultVphoneCLIPath, "setup"], onOutput: { lines in setupOutput = lines.suffix(5).joined(separator: "\n") })
            isWorking = false
            if !setup { setupOutput = "Dependency setup failed." }
        }
    }

    private func allowlistVphone() {
        isWorking = true
        Task {
            let ok = await manager.run(args: ["vphone-amfidont"], onOutput: { lines in
                setupOutput = lines.suffix(5).joined(separator: "\n")
            })
            isWorking = false
            amfidontConfigured = ok
            if !ok { setupOutput = "vphone-amfidont failed." }
        }
    }
    private func createVM() { run([vphoneCliPath, "vm", "create", vphoneVMName, "--variant", "jb"]) }
    private func installMCP() {
        isWorking = true
        Task {
            let ok = await MCPInstaller.install(using: manager) { lines in
                setupOutput = lines.suffix(5).joined(separator: "\n")
            }
            isWorking = false
            if !ok { setupOutput = "MCP installation failed. Ensure Codex and Claude Code are installed." }
        }
    }
    private func installLaunchWatcher() {
        isWorking = true
        let installed = VphoneLaunchAgent.install()
        isWorking = false
        if !installed { setupOutput = "Could not install the vphone launch watcher." }
    }
    private func run(_ args: [String]) { isWorking = true; Task { let ok = await manager.run(args: args, onOutput: { lines in setupOutput = lines.suffix(5).joined(separator: "\n") }); isWorking = false; if !ok { setupOutput = "Setup command failed." } } }
    private func complete() { hasCompletedOnboarding = true; isPresented = false }
}
