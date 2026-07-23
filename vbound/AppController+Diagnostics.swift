import AppKit

extension AppController {

    func testSSHConnection() {
        guard sshTestState != .testing else { return }
        sshTestState = .testing
        Task { [weak self] in
            guard let self else { return }
            let forwarded = await ensurePortForward()
            let ok = forwarded ? await run(ssh: "echo vbound-ok") : false
            sshTestState = ok ? .success : .failure("Couldn't reach mobile@127.0.0.1:2222 — check the device password and that vphone is running")
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            sshTestState = .idle
        }
    }

    func copyDiagnosticInfo() {
        Task { [weak self] in
            guard let self else { return }
            let info = await gatherDiagnosticInfo()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(info, forType: .string)
        }
    }

    private func gatherDiagnosticInfo() async -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        let vphoneCliPath = UserDefaults.standard.string(forKey: "vphoneCliPath")
            ?? (NSHomeDirectory() + "/vphone-cli")
        let unboundPath = UserDefaults.standard.string(forKey: "unboundPath")
            ?? (NSHomeDirectory() + "/Developer/loader-ios")
        let unboundPluginsPath = UserDefaults.standard.string(forKey: "unboundPluginsPath")
            ?? (NSHomeDirectory() + "/Developer/unbound-plugins")

        let pymobiledevice3Path = await runCapture(args: ["which", "pymobiledevice3"], timeout: 5)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sshpassPath = await runCapture(args: ["which", "sshpass"], timeout: 5)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        func status(_ valid: Bool) -> String { valid ? "found" : "missing" }

        return """
        vbound \(version) (\(build))
        macOS \(osVersion)

        vphone-cli path: \(vphoneCliPath) — \(status(AppController.pathValid(vphoneCliPath)))
        Unbound Tweak path: \(unboundPath) — \(status(AppController.pathValid(unboundPath)))
        Addon Workspace path: \(unboundPluginsPath) — \(status(AppController.pathValid(unboundPluginsPath)))

        pymobiledevice3: \(pymobiledevice3Path.isEmpty ? "not found" : pymobiledevice3Path)
        sshpass: \(sshpassPath.isEmpty ? "not found" : sshpassPath)
        sshfs: \(AppController.sshfsPath ?? "not found")

        vphone detected: \(vphoneDetected)
        vphone UDID: \(vphoneUDID ?? "unresolved")
        Attached: \(isAttached)
        Mounted: \(isMounted)
        """
    }
}
