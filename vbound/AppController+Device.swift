import AppKit

extension AppController {

    func bootVphone(in directory: String) {
        bootedVphone = true
        let dirPath = (directory as NSString).expandingTildeInPath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c",
                       "cd '\(dirPath)' && nohup make boot > /dev/null 2>&1 & disown $!"]
        try? p.run()
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
        Task {
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
