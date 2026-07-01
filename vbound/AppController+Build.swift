import AppKit

extension AppController {

    func buildUnbound(in directory: String) {
        Task {
            if !isStreaming { startLogStream() }

            let dirPath = (directory as NSString).expandingTildeInPath
            let ncpu    = ProcessInfo.processInfo.processorCount

            buildLog = ""; buildProgress = 0; buildPhase = .building
            let totalSteps     = estimateBuildSteps(in: dirPath)
            var completedSteps = 0

            let built = await run(args: [
                "/bin/zsh", "-l", "-c",
                "cd '\(dirPath)' && gmake package DEBUG=1 -j\(ncpu) 2>&1"
            ]) { [weak self = self] raw in
                let line = raw.replacingOccurrences(
                    of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
                guard line.hasPrefix("==>") || line.hasPrefix("> M") || line.hasPrefix("dm.pl:")
                else { return }
                completedSteps += 1
                if totalSteps > 0 {
                    self?.buildProgress = min(Double(completedSteps) / Double(totalSteps), 1.0)
                }
                var display = line
                if      display.hasPrefix("==> ")    { display = String(display.dropFirst(4)) }
                else if display.hasPrefix("> ")       { display = String(display.dropFirst(2)) }
                else if display.hasPrefix("dm.pl: ") { display = String(display.dropFirst(7)) }
                self?.buildLog = display
            }
            guard built else { return fail("Build failed") }

            guard let debPath = findDeb(in: dirPath) else { return fail("No .deb found") }
            let debName   = URL(fileURLWithPath: debPath).lastPathComponent
            let remoteDeb = "/tmp/\(debName)"

            await ensurePortForward()

            buildPhase = .uploading; buildLog = ""; buildProgress = 0
            let uploaded = await run(args: [
                "sshpass", "-p", "alpine", "scp",
                "-P", "2222",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=/tmp/vbound-ssh-mux",
                "-o", "ControlPersist=60",
                debPath, "mobile@127.0.0.1:\(remoteDeb)"
            ])
            guard uploaded else { return fail("Upload failed") }

            buildPhase = .installing
            let installed = await run(ssh: "echo 'alpine' | sudo -S dpkg -i '\(remoteDeb)'")
            guard installed else { return fail("Install failed") }

            buildPhase = .restarting
            _ = await run(ssh: "echo 'alpine' | sudo -S killall -9 Discord; "
                            + "uiopen --bundleid com.hammerandchisel.discord")

            buildPhase = .idle; buildLog = ""; buildProgress = 0
        }
    }

    func fail(_ message: String) {
        buildPhase = .finishing; buildLog = message; buildProgress = 0
        scheduleReset()
    }

    func scheduleReset() {
        Task {
            try? await Task.sleep(for: .seconds(3))
            buildPhase = .idle; buildLog = ""
        }
    }

    private func estimateBuildSteps(in dirPath: String) -> Int {
        guard let e = FileManager.default.enumerator(
            at: URL(fileURLWithPath: dirPath),
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return 50 }
        let skipDirs: Set<String> = [".theos", "packages", "vendor", "node_modules"]
        var xCount = 0, mCount = 0
        for case let url as URL in e {
            if url.hasDirectoryPath && skipDirs.contains(url.lastPathComponent) {
                e.skipDescendants(); continue
            }
            switch url.pathExtension {
            case "x", "xm": xCount += 1
            case "m", "mm": mCount += 1
            default: break
            }
        }
        return xCount * 4 + mCount * 2 + 13
    }

    private func findDeb(in directory: String) -> String? {
        let packagesDir = (directory as NSString).appendingPathComponent("packages")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: packagesDir)
        else { return nil }
        return files
            .filter { $0.hasSuffix(".deb") }
            .map    { (packagesDir as NSString).appendingPathComponent($0) }
            .first
    }
}
