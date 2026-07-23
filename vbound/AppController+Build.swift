import AppKit
import UserNotifications

extension AppController {

    func buildPlugins(in directory: String) {
        buildTask = Task { [weak self] in
            guard let self else { return }
            if !isStreaming { startLogStream() }

            let dirPath = (directory as NSString).expandingTildeInPath
            lastPluginsWorkDir = dirPath
            lastFailedPlugins = []
            buildLog = ""; buildLogFull = ""; buildProgress = 0; buildPhase = .buildingPlugins; activeBuildTarget = .plugins
            let built = await run(args: [
                "/bin/zsh", "-l", "-c",
                "cd \(Self.shellQuoted(dirPath)) && bunx ubd build"
            ], onLaunch: { [weak self] p in self?.buildProcess = p }) { [weak self] line in
                self?.buildLog = line
                self?.appendBuildLog(line)
            }
            guard built else { return fail("Addon build failed") }
            guard !Task.isCancelled else { return }

            let pluginDists = findPluginDists(in: dirPath)
            guard !pluginDists.isEmpty else { return fail("No addon dist folders found") }

            await ensurePortForward()
            guard !Task.isCancelled else { return }

            buildPhase = .deployingPlugins
            await deployPlugins(pluginDists)
        }
    }

    func retryFailedPlugins() {
        guard !lastFailedPlugins.isEmpty, !buildPhase.isRunning else { return }
        let toRetry = lastFailedPlugins.map { (name: $0.name, path: $0.path) }
        buildTask = Task { [weak self] in
            guard let self else { return }
            if !isStreaming { startLogStream() }
            buildLog = ""; buildLogFull = ""; buildProgress = 0
            buildPhase = .deployingPlugins; activeBuildTarget = .plugins
            await ensurePortForward()
            guard !Task.isCancelled else { return }
            await deployPlugins(toRetry)
        }
    }

    private func deployPlugins(_ pluginDists: [(name: String, path: String)]) async {
        activeProcesses = []
        let results: [(name: String, path: String, ok: Bool)] = await withTaskGroup(of: (String, String, Bool).self) { group in
            for (name, distPath) in pluginDists {
                group.addTask { [weak self] in
                    guard let self else { return (name, distPath, false) }
                    let ok = await self.deployOnePlugin(name: name, distPath: distPath)
                    return (name, distPath, ok)
                }
            }
            var collected: [(String, String, Bool)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        guard !Task.isCancelled else { return }

        let succeededNames = results.filter(\.ok).map(\.name)
        let failed = results.filter { !$0.ok }.map { FailedPlugin(name: $0.name, path: $0.path) }
        lastFailedPlugins = failed

        guard !succeededNames.isEmpty else {
            return fail(failed.count == pluginDists.count
                ? "All \(failed.count) addon(s) failed to deploy"
                : "Addon deployment failed")
        }

        buildPhase = .restarting
        let restarted = await restartDiscord()
        guard !Task.isCancelled else { return }
        guard restarted else { return fail("Discord restart failed") }

        lastAddonsResult = BuildResultSummary(succeeded: failed.isEmpty, date: Date())
        if failed.isEmpty {
            buildPhase = .pluginsDeployed; buildLog = ""; buildProgress = 0
            playBuildSound(success: true)
            notifyBuildCompletion(target: "Addons", succeeded: true, message: "All addons deployed.")
            scheduleReset()
        } else {
            let names = failed.map(\.name).joined(separator: ", ")
            buildPhase = .failed("Deployed \(succeededNames.count)/\(pluginDists.count) addons — failed: \(names)")
            buildLog = ""; buildProgress = 0
            playBuildSound(success: false)
            notifyBuildCompletion(target: "Addons", succeeded: false, message: "Failed: \(names)")
        }
    }

    private func deployOnePlugin(name: String, distPath: String) async -> Bool {
        let stagingPath = "/tmp/vbound-plugin-\(UUID().uuidString)"
        buildLog = "Deploying addon \(name)…"
        let uploaded = await run(args: [
            "sshpass", "-p", sshPassword, "scp",
            "-r",
            "-P", "2222",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "PubkeyAuthentication=no",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(AppController.sshControlPath)",
            "-o", "ControlPersist=60",
            distPath, "mobile@127.0.0.1:\(stagingPath)"
        ], onLaunch: { [weak self] p in self?.activeProcesses.append(p) })
        guard uploaded, !Task.isCancelled else { return false }

        let deployed = await run(
            ssh: pluginDeploymentCommand(name: name, stagingPath: stagingPath),
            onLaunch: { [weak self] p in self?.activeProcesses.append(p) }
        )
        return deployed && !Task.isCancelled
    }

    func buildUnbound(in directory: String) {
        buildTask = Task { [weak self] in
            guard let self else { return }
            if !isStreaming { startLogStream() }

            let dirPath = (directory as NSString).expandingTildeInPath
            let ncpu    = ProcessInfo.processInfo.processorCount

            buildLog = ""; buildLogFull = ""; buildProgress = 0; buildPhase = .building; activeBuildTarget = .tweak
            // Off the main thread: this walks the entire source tree with
            // FileManager.enumerator, and buildTask inherits AppController's MainActor
            // context — called directly, this would run synchronously on the main thread
            // and could visibly hitch the window right as the progress bar tries to appear.
            var totalSteps = await Task.detached {
                AppController.estimateBuildSteps(in: dirPath)
            }.value
            var completedSteps = 0

            let built = await run(args: [
                "/bin/zsh", "-l", "-c",
                "cd '\(dirPath)' && \(makeExecutable) package DEBUG=1 -j\(ncpu) 2>&1"  // #15
            ], onLaunch: { [weak self] p in self?.buildProcess = p }) { [weak self] raw in
                let line = raw.replacing(/\u{1B}\[[0-9;]*[A-Za-z]/, with: "")  // #2 — inline literal escapes SE-0401
                self?.appendBuildLog(line)
                guard line.hasPrefix("==>") || line.hasPrefix("> M") || line.hasPrefix("dm.pl:")
                else { return }
                completedSteps += 1
                if completedSteps > totalSteps { totalSteps = completedSteps + max(5, totalSteps / 10) }
                if totalSteps > 0 {
                    let fraction = Double(completedSteps) / Double(totalSteps)
                    self?.buildProgress = min(fraction, Self.buildProgressSoftCap)
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
                "-o", "PubkeyAuthentication=no",
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

            lastTweakResult = BuildResultSummary(succeeded: true, date: Date())
            buildPhase = .succeeded; buildLog = ""; buildProgress = 0
            playBuildSound(success: true)
            notifyBuildCompletion(target: "Tweak", succeeded: true, message: "Build installed.")
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
        activeProcesses.forEach { $0.terminate() }
        activeProcesses = []
        buildPhase = .cancelled; buildLog = ""; buildProgress = 0
        activeBuildTarget = nil
        scheduleReset()
    }

    func fail(_ message: String) {
        // fail() is only ever called from inside buildUnbound's own Task, so this
        // reflects that Task's cancellation state — suppresses the generic "X failed"
        // toast that would otherwise overwrite the .cancelled state cancelBuild() just set.
        guard !Task.isCancelled else { return }
        switch activeBuildTarget {
        case .tweak:   lastTweakResult  = BuildResultSummary(succeeded: false, date: Date())
        case .plugins: lastAddonsResult = BuildResultSummary(succeeded: false, date: Date())
        case nil: break
        }
        buildPhase = .failed(message); buildLog = ""; buildProgress = 0
        playBuildSound(success: false)
        notifyBuildCompletion(
            target: activeBuildTarget == .plugins ? "Addons" : "Tweak",
            succeeded: false, message: message)
    }

    // Auto-dismiss a success/cancelled toast after a few seconds; failures stay until
    // the user dismisses them explicitly (via dismissBuildResult()).
    func scheduleReset() {
        Task {
            try? await Task.sleep(for: .seconds(4))
            switch buildPhase {
            case .succeeded, .pluginsDeployed, .cancelled: buildPhase = .idle; buildLog = ""; activeBuildTarget = nil
            default: break
            }
        }
    }

    func dismissBuildResult() {
        switch buildPhase {
        case .succeeded, .pluginsDeployed, .failed, .cancelled: buildPhase = .idle; buildLog = ""; activeBuildTarget = nil
        default: break
        }
    }

    func saveBuildLog() {
        guard !buildLogFull.isEmpty else { return }
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "vbound-build-\(formatter.string(from: Date())).log"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? buildLogFull.write(to: url, atomically: true, encoding: .utf8)
    }

    private func appendBuildLog(_ line: String) {
        buildLogFull += line + "\n"
        let limit = 300_000
        if buildLogFull.utf8.count > limit { buildLogFull = String(buildLogFull.suffix(limit)) }
    }

    private func playBuildSound(success: Bool) {
        guard buildSoundsEnabled else { return }
        NSSound(named: success ? "Glass" : "Basso")?.play()  // audible cue for whenever you've stepped away
    }

    private func notifyBuildCompletion(target: String, succeeded: Bool, message: String) {
        guard buildNotificationsEnabled, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(target) \(succeeded ? "build succeeded" : "build failed")"
        content.body  = message
        content.sound = nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static let buildProgressSoftCap = 0.92

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

    private func findPluginDists(in directory: String) -> [(name: String, path: String)] {
        let pluginsDirectory = URL(fileURLWithPath: directory).appending(path: "plugins")
        guard let pluginDirectories = try? FileManager.default.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return pluginDirectories.compactMap { pluginDirectory in
            guard (try? pluginDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let distDirectory = pluginDirectory.appending(path: "dist")
            guard (try? distDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return (pluginDirectory.lastPathComponent, distDirectory.path)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func pluginDeploymentCommand(name: String, stagingPath: String) -> String {
        let script = """
        container="$(for metadata in /private/var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist; do
            [ -f "$metadata" ] || continue
            if grep -q 'com.hammerandchisel.discord' "$metadata"; then
                dirname "$metadata"
                break
            fi
        done)"
        [ -n "$container" ] || exit 1
        plugins="$container/Documents/Unbound/Plugins"
        mkdir -p "$plugins"
        rm -rf "$plugins"/\(Self.shellQuoted(name))
        mv \(Self.shellQuoted(stagingPath)) "$plugins"/\(Self.shellQuoted(name))
        """
        let encodedScript = Data(script.utf8).base64EncodedString()
        return "{ printf '%s\\n' \(Self.shellQuoted(sshPassword)); "
             + "printf '%s' \(Self.shellQuoted(encodedScript)) | /var/jb/usr/bin/base64 -d; "
             + "} | sudo -S /var/jb/usr/bin/sh"
    }

    // Not private: AppController+Mount.swift's root-sftp provisioning script needs the
    // same remote-shell quoting.
    nonisolated static func shellQuoted(_ value: String) -> String {
        "'\(value.replacing("'", with: "'\\\"'\\\"'"))'"
    }
}
