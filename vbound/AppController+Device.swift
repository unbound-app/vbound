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
            _ = await run(args: ["pymobiledevice3", "diagnostics", "shutdown", "--udid", udid])
        }
    }

    func launchDiscord() {
        Task {
            if !isStreaming { startLogStream() }
            await ensurePortForward()
            _ = await run(ssh: "echo '\(sshPassword)' | sudo -S killall -9 Discord; "
                             + "uiopen --bundleid com.hammerandchisel.discord")
        }
    }
}
