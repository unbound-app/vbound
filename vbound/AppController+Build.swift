import AppKit

extension AppController {

    func buildUnbound(in directory: String) {
        buildTask = Task { [weak self] in
            guard let self else { return }
            if !isStreaming { startLogStream() }

            let dirPath = (directory as NSString).expandingTildeInPath
            let ncpu    = ProcessInfo.processInfo.processorCount

            buildLog = ""; buildProgress = 0; buildPhase = .building
            // Off the main thread: this walks the entire source tree with
            // FileManager.enumerator, and buildTask inherits AppController's MainActor
            // context — called directly, this would run synchronously on the main thread
            // and could visibly hitch the window right as the progress bar tries to appear.
            let totalSteps = await Task.detached {
                AppController.estimateBuildSteps(in: dirPath)
            }.value
            var completedSteps = 0

            let built = await run(args: [
                "/bin/zsh", "-l", "-c",
                "cd '\(dirPath)' && \(makeExecutable) package DEBUG=1 -j\(ncpu) 2>&1"  // #15
            ], onLaunch: { [weak self] p in self?.buildProcess = p }) { [weak self] raw in
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
            // Covers the race where cancelBuild() fires just as the process was already
            // exiting on its own (terminate() has no effect after that) — without this,
            // a cancellation landing in that narrow window would fall through and keep
            // driving the pipeline into upload/install as if nothing happened.
            guard !Task.isCancelled else { return }

            guard let debPath = findDeb(in: dirPath) else { return fail("No .deb found") }
            let debName   = URL(fileURLWithPath: debPath).lastPathComponent
            let remoteDeb = "/tmp/\(debName)"

            await ensurePortForward()
            guard !Task.isCancelled else { return }

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
            ], onLaunch: { [weak self] p in self?.buildProcess = p })
            guard uploaded else { return fail("Upload failed") }
            guard !Task.isCancelled else { return }

            buildPhase = .installing
            let installed = await run(
                ssh: "echo '\(sshPassword)' | sudo -S dpkg -i '\(remoteDeb)'",
                onLaunch: { [weak self] p in self?.buildProcess = p }
            )
            guard installed else { return fail("Install failed") }
            guard !Task.isCancelled else { return }

            buildPhase = .restarting
            let restarted = await restartDiscord()
            guard !Task.isCancelled else { return }
            guard restarted else { return fail("Discord restart failed") }

            buildPhase = .succeeded; buildLog = ""; buildProgress = 0
            NSSound(named: "Glass")?.play()  // audible cue for whenever you've stepped away
            scheduleReset()
        }
    }

    // Terminates whichever child process the pipeline is currently waiting on and marks
    // the Task cancelled so every stage guard above bails instead of advancing to the
    // next step. Only meaningful while a stage is actually running — a stray click once
    // the pipeline already finished is a no-op.
    func cancelBuild() {
        guard buildPhase.isRunning else { return }
        buildTask?.cancel()
        buildProcess?.terminate()
        buildProcess = nil
        buildPhase = .cancelled; buildLog = ""; buildProgress = 0
        scheduleReset()
    }

    func fail(_ message: String) {
        // fail() is only ever called from inside buildUnbound's own Task, so this
        // reflects that Task's cancellation state — suppresses the generic "X failed"
        // toast that would otherwise overwrite the .cancelled state cancelBuild() just set.
        guard !Task.isCancelled else { return }
        buildPhase = .failed(message); buildLog = ""; buildProgress = 0
        NSSound(named: "Basso")?.play()  // audible cue for whenever you've stepped away
    }

    // Auto-dismiss a success/cancelled toast after a few seconds; failures stay until
    // the user dismisses them explicitly (via dismissBuildResult()).
    func scheduleReset() {
        Task {
            try? await Task.sleep(for: .seconds(4))
            switch buildPhase {
            case .succeeded, .cancelled: buildPhase = .idle; buildLog = ""
            default: break
            }
        }
    }

    func dismissBuildResult() {
        switch buildPhase {
        case .succeeded, .failed, .cancelled: buildPhase = .idle; buildLog = ""
        default: break
        }
    }

    // Probe common Homebrew and system paths so the build works whether the user has
    // GNU make or only Apple's /usr/bin/make (#15).
    private var makeExecutable: String {
        ["/opt/homebrew/bin/gmake", "/usr/local/bin/gmake", "/usr/bin/make"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "make"
    }

    // Pure function of dirPath with no actor-isolated state — nonisolated static so it
    // can run on Task.detached's background executor without a MainActor hop, matching
    // the same pattern AppController+LogStream.swift's parseLiveSyslogLine already uses.
    private nonisolated static func estimateBuildSteps(in dirPath: String) -> Int {
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

    // contentsOfDirectory gives no ordering guarantee (not by name, not by date), so
    // picking .first could silently grab a stale .deb left over from a previous version
    // if packages/ isn't cleaned between builds — pick whichever one was written last.
    private func findDeb(in directory: String) -> String? {
        let packagesDir = (directory as NSString).appendingPathComponent("packages")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: packagesDir)
        else { return nil }

        func modificationDate(_ path: String) -> Date {
            ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)
                ?? .distantPast
        }

        return files
            .filter { $0.hasSuffix(".deb") }
            .map    { (packagesDir as NSString).appendingPathComponent($0) }
            .max    { modificationDate($0) < modificationDate($1) }
    }
}
