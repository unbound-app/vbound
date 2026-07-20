import AppKit

extension AppController {

    func bootVphone(in directory: String) {
        // vphoneDetected doesn't flip true until the VM actually finishes booting (which
        // takes a while), and the toolbar button is only disabled by vphoneDetected — a
        // few impatient clicks in that window would otherwise spawn multiple concurrent
        // `make boot` processes (port conflicts, duplicate VM instances, ...).
        guard !isBooting, !vphoneDetected else { return }
        isBooting = true
        bootedVphone = true
        let dirPath = (directory as NSString).expandingTildeInPath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c",
                       "cd '\(dirPath)' && nohup make boot > /dev/null 2>&1 & disown $!"]
        try? p.run()

        // Booting can fail silently (wrong path deeper than the top-level directory
        // check, missing dependencies, etc.) — without this, a failed boot would leave
        // isBooting stuck true forever, since only actual detection in checkAndAttach()
        // clears it, permanently disabling the button short of relaunching the app.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, self.isBooting, !self.vphoneDetected else { return }
            self.isBooting = false
        }
    }

    func shutdownVphone() {
        Task {
            var udid = vphoneUDID
            if udid == nil { udid = await resolveVphoneUDID().0 }
            guard let udid else { return }
            // Otherwise the log stream and shell session just lose their connection when
            // the device actually goes offline, and both auto-reconnect straight into a
            // retry-every-2-seconds loop against a device we just told it to shut down.
            stopLogStream()
            disconnectShell()
            unmountVphone()
            // The port-forward daemon is a local TCP listener independent of whether the
            // device on the other end is actually still there — left running, the next
            // ensurePortForward() call would see the local port still answering and skip
            // re-establishing it, so Build/Shell/Discord would fail against a dead tunnel
            // instead of cleanly reconnecting once vphone is back.
            forwardProcess?.terminate()
            forwardProcess = nil
            _ = await run(args: ["pymobiledevice3", "diagnostics", "shutdown", "--udid", udid], timeout: 10)
        }
    }

    func launchDiscord() {
        // Same class of gap as bootVphone() — without this, double-clicking before the
        // first attempt finishes would fire overlapping SSH restart commands.
        guard !isLaunchingDiscord else { return }
        isLaunchingDiscord = true
        Task {
            defer { isLaunchingDiscord = false }
            if !isStreaming { startLogStream() }
            await ensurePortForward()
            let restarted = await restartDiscord()
            discordLaunchFailed = !restarted
            // Auto-clears like the build result toasts do — a stale red badge with no
            // way to dismiss it would just linger forever until the next Discord click.
            guard !restarted else { return }
            try? await Task.sleep(for: .seconds(4))
            discordLaunchFailed = false
        }
    }

    // Shared by launchDiscord() and the build pipeline's post-install restart, so the
    // bundle ID / restart mechanism only needs to change in one place.
    @discardableResult
    func restartDiscord() async -> Bool {
        await run(ssh: "echo '\(sshPassword)' | sudo -S killall -9 Discord; "
                     + "uiopen --bundleid com.hammerandchisel.discord")
    }
}
