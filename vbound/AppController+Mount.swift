import AppKit

extension AppController {

    // Fixed, visible mount point — mounting here is a manual, opt-in action rather than
    // an auto-managed path like the Settings folder pickers, so there's nothing to
    // configure. Custom icon is best-effort: it lands on the local directory itself, so
    // it still shows in Finder even before the first mount (and after unmounting).
    nonisolated static let mountPath: String = {
        let path = NSHomeDirectory() + "/vphone"
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        if let icon = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil) {
            NSWorkspace.shared.setIcon(icon, forFile: path)
        }
        return path
    }()

    // sshfs (from FUSE-T + gromgit/fuse/sshfs-mac) isn't guaranteed to be on PATH inside
    // enrichedEnvironment the way brew's own bin dirs are, so this checks the same known
    // Homebrew locations `makeExecutable` already probes for gmake (#15).
    var sshfsAvailable: Bool {
        ["/opt/homebrew/bin/sshfs", "/usr/local/bin/sshfs"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func mountVphone() {
        guard !isMounted, !isMounting, sshfsAvailable else { return }
        isMounting = true
        Task { [weak self] in
            guard let self else { return }
            // Covers the case where a previous session (or a crash) left the mount in
            // place — retrying sshfs against an already-mounted point just fails.
            if await isPathMounted(AppController.mountPath) {
                isMounting = false; isMounted = true
                return
            }
            await ensurePortForward()
            let mounted = await run(args: [
                "sshpass", "-p", sshPassword,
                "sshfs",
                "-p", "2222",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "PubkeyAuthentication=no",
                "-o", "reconnect",
                "-o", "ServerAliveInterval=15",
                "-o", "ServerAliveCountMax=3",
                "-o", "volname=vphone",
                "mobile@127.0.0.1:/var/mobile",
                AppController.mountPath
            ])
            isMounting = false
            isMounted  = mounted
        }
    }

    func unmountVphone() {
        guard isMounted else { return }
        Task { [weak self] in
            guard let self else { return }
            if await run(args: ["umount", AppController.mountPath]) {
                isMounted = false
            }
        }
    }

    func revealMountInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: AppController.mountPath)])
    }

    func isPathMounted(_ path: String) async -> Bool {
        await runCapture(args: ["mount"]).contains(" on \(path) (")
    }
}
