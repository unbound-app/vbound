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
                "cd '\(dirPath)' && \(makeExecutable) package DEBUG=1 -j\(ncpu) 2>&1"  // #15
            ]) { [weak self] raw in
                let line = raw.replacing(/\u{1B}\[[0-9;]*[A-Za-z]/, with: "")  // #2 — inline literal escapes SE-0401
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
                "sshpass", "-p", sshPassword, "scp",
                "-P", "2222",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(AppController.sshControlPath)",  // #8
                "-o", "ControlPersist=60",
                debPath, "mobile@127.0.0.1:\(remoteDeb)"
            ])
            guard uploaded else { return fail("Upload failed") }

            buildPhase = .installing
            let installed = await run(ssh: "echo '\(sshPassword)' | sudo -S dpkg -i '\(remoteDeb)'")
            guard installed else { return fail("Install failed") }

            buildPhase = .restarting
            _ = await restartDiscord()

            buildPhase = .succeeded; buildLog = ""; buildProgress = 0
            scheduleReset()
        }
    }

    func fail(_ message: String) {
        buildPhase = .failed(message); buildLog = ""; buildProgress = 0
    }

    // Auto-dismiss a success toast after a few seconds; failures stay until the
    // user dismisses them explicitly (via dismissBuildResult()).
    func scheduleReset() {
        Task {
            try? await Task.sleep(for: .seconds(4))
            if case .succeeded = buildPhase { buildPhase = .idle; buildLog = "" }
        }
    }

    func dismissBuildResult() {
        switch buildPhase {
        case .succeeded, .failed: buildPhase = .idle; buildLog = ""
        default: break
        }
    }

    // Probe common Homebrew and system paths so the build works whether the user has
    // GNU make or only Apple's /usr/bin/make (#15).
    private var makeExecutable: String {
        ["/opt/homebrew/bin/gmake", "/usr/local/bin/gmake", "/usr/bin/make"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "make"
    }

    private func estimateBuildSteps(in dirPath: String) -> Int {
        guard let e = FileManager.default.enumerator(
            at: URL(fileURLWithPath: dirPath),
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return 50 }
        let skipDirs: Set<String> = [".theos", "packages", "vendor", "node_modules"]
        var logosCount = 0, objcCount = 0, swiftCount = 0
        for case let url as URL in e {
            if url.hasDirectoryPath && skipDirs.contains(url.lastPathComponent) {
                e.skipDescendants(); continue
            }
            switch url.pathExtension {
            case "x", "xm": logosCount += 1  // Logos: preprocess + compile (~3 make steps each)
            case "m", "mm":  objcCount  += 1  // ObjC: compile (~2 make steps each)
            case "swift":    swiftCount += 1  // Swift: compile (~2 make steps each) (#16)
            default: break
            }
        }
        // Overhead: link + stage + package + sign + metadata ≈ 8 steps
        return max(logosCount * 3 + (objcCount + swiftCount) * 2 + 8, 20)
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
