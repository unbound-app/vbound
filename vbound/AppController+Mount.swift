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

    // Only the FUSE-T-native build (macos-fuse-t/homebrew-cask/fuse-t-sshfs, installs to
    // /usr/local/bin) is known to work here. gromgit/fuse/sshfs-mac — the more commonly
    // recommended formula, installs to /opt/homebrew/bin — is built against classic
    // macFUSE/libfuse headers: against FUSE-T it prints "library too old", exits 0, and
    // never actually attaches the mount, leaving the folder silently empty. Deliberately
    // not falling back to it: /opt/homebrew/bin sits earlier in enrichedEnvironment's
    // PATH than /usr/local/bin, so a bare "sshfs" lookup would prefer the broken one even
    // with the correct package also installed.
    static var sshfsPath: String? {
        let path = "/usr/local/bin/sshfs"
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
            _ = await run(args: [
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
            ])
            isMounting = false
            // Ground-truth check rather than trusting sshfs's exit code — it can exit 0
            // without ever actually attaching the mount (see the FUSE-T note above).
            isMounted = await isPathMounted(AppController.mountPath)
        }
    }

    func unmountVphone() {
        guard isMounted else { return }
        Task { [weak self] in
            guard let self else { return }
            _ = await run(args: ["umount", AppController.mountPath])
            // FUSE-T's NFS-loopback mounts can shrug off a plain umount and stay listed
            // in `mount` — confirmed directly: umount / umount -f both reported success or
            // "not mounted" while the entry stuck around, and only diskutil's forced
            // unmount actually cleared it.
            if await isPathMounted(AppController.mountPath) {
                _ = await run(args: ["diskutil", "unmount", "force", AppController.mountPath])
            }
            isMounted = await isPathMounted(AppController.mountPath)
        }
    }

    func revealMountInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: AppController.mountPath)])
    }

    func isPathMounted(_ path: String) async -> Bool {
        await runCapture(args: ["mount"]).contains(" on \(path) (")
    }
}
