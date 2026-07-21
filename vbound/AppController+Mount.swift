import AppKit
import UniformTypeIdentifiers

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
        NSWorkspace.shared.setIcon(badgedFolderIcon, forFile: path)
        return path
    }()

    // The standard folder icon with a small phone badge in the corner (mirrors how
    // Finder badges iCloud/shared folders) — reads as "a folder" first, "vphone's"
    // second, rather than replacing the folder glyph outright with a bare phone icon.
    private nonisolated static var badgedFolderIcon: NSImage {
        let size = NSSize(width: 256, height: 256)
        let image = NSImage(size: size)
        image.lockFocus()
        NSWorkspace.shared.icon(for: .folder).draw(in: NSRect(origin: .zero, size: size))
        let badgeRect = NSRect(x: 132, y: 8, width: 116, height: 116)
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()
        let ring = NSBezierPath(ovalIn: badgeRect.insetBy(dx: 1, dy: 1))
        NSColor.white.setStroke()
        ring.lineWidth = 4
        ring.stroke()
        if let phone = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 60, weight: .medium)) {
            phone.isTemplate = true
            NSColor.white.set()
            phone.draw(in: badgeRect.insetBy(dx: 28, dy: 20), from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        image.unlockFocus()
        return image
    }

    // Targets macFUSE, not FUSE-T: FUSE-T has an open, unfixed upstream bug
    // (macos-fuse-t/fuse-t#63 — "Improper use of offset in readdir") where it doesn't
    // honor the FUSE readdir offset contract, so any directory listing that doesn't fit
    // in a single response silently breaks — confirmed directly against a live device,
    // on directories as small as 14 entries. That's not fixable from vbound's side.
    // gromgit/fuse/sshfs-mac (installs to /opt/homebrew/bin) is the sshfs build meant to
    // pair with macFUSE, which implements the real FUSE spec correctly.
    static var sshfsPath: String? {
        let path = "/opt/homebrew/bin/sshfs"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    var sshfsAvailable: Bool { AppController.sshfsPath != nil }

    func mountVphone() {
        guard !isMounted, !isMounting, let sshfsPath = AppController.sshfsPath else { return }
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

            // Not routed through the shared run(args:) helper — with -o reconnect, sshfs
            // never daemonizes; it stays in the foreground as the FUSE server for as long
            // as the mount is alive (confirmed directly: the process was still running
            // minutes after a successful mount). Awaiting its exit would hang forever, so
            // it's launched and tracked like shellProcess/logStreamProcess instead, and
            // mount success is polled via ground truth rather than the process lifecycle.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [
                "sshpass", "-p", sshPassword,
                sshfsPath,
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
            ]
            p.environment = enrichedEnvironment
            do {
                try p.run()
                mountProcess = p
            } catch {
                isMounting = false
                return
            }

            for _ in 0..<25 {  // ~5s at 200ms — sshfs attaches almost immediately once it does
                if await isPathMounted(AppController.mountPath) {
                    isMounting = false; isMounted = true
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            isMounting = false
            isMounted = false
        }
    }

    func unmountVphone() {
        guard isMounted else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await run(args: ["umount", AppController.mountPath])
            // Fall back to a forced unmount if the mount is still listed afterward —
            // observed directly against a wedged FUSE-T mount during earlier testing
            // (umount / umount -f both no-opped while `mount` still listed the entry);
            // kept as a defensive fallback regardless of backend.
            if await isPathMounted(AppController.mountPath) {
                _ = await run(args: ["diskutil", "unmount", "force", AppController.mountPath])
            }
            isMounted = await isPathMounted(AppController.mountPath)
            if !isMounted {
                mountProcess?.terminate()
                mountProcess = nil
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
