import AppKit
import UserNotifications

extension AppController {

    func toggleTweakBuild(in directory: String) {
        guard !buildPhase.isRunning || activeBuildTarget == .tweak else { return }
        if buildPhase.isRunning {
            cancelBuild()
        } else {
            buildUnbound(in: directory)
        }
    }

    func toggleAddonsBuild(in directory: String) {
        guard !buildPhase.isRunning || activeBuildTarget == .plugins else { return }
        if buildPhase.isRunning {
            cancelBuild()
        } else {
            buildPlugins(in: directory)
        }
    }

    func buildPlugins(in directory: String) {
        buildTask = Task { [weak self] in
            guard let self else { return }
            if !isStreaming { startLogStream() }

            let dirPath = (directory as NSString).expandingTildeInPath
            let addonNames = findAddonNames(in: dirPath)
            lastPluginsWorkDir = dirPath
            lastFailedPlugins = []
            buildLog = ""; buildLogFull = ""; buildProgress = 0; buildPhase = .buildingPlugins; activeBuildTarget = .plugins
            var buildFailureLines: [String] = []
            var builtAddonNames = Set<String>()
            var skippedAddonNames = Set<String>()
            let built = await run(args: [
                "/bin/zsh", "-l", "-c",
                "cd \(Self.shellQuoted(dirPath)) && bunx ubd build 2>&1"
            ], onLaunch: { [weak self] p in self?.buildProcess = p }) { [weak self] lines in
                guard let self else { return }
                for raw in lines {
                    let line = Self.strippingANSI(raw)
                    appendBuildLog(line)
                    if Self.looksLikeBuildFailure(line) { buildFailureLines.append(line) }
                    if let name = Self.addonBuildStarting(in: line) {
                        let position = min(builtAddonNames.count + skippedAddonNames.count + 1, max(addonNames.count, 1))
                        buildLog = "Building addon \(position)/\(max(addonNames.count, 1)): \(name)"
                    } else if let name = Self.addonBuildFinished(in: line) {
                        builtAddonNames.insert(name)
                        if !addonNames.isEmpty {
                            let completed = builtAddonNames.count + skippedAddonNames.count
                            buildProgress = Double(completed) / Double(addonNames.count)
                            buildLog = "Built addon \(completed)/\(addonNames.count): \(name)"
                        } else {
                            buildLog = "Built addon: \(name)"
                        }
                    } else if let name = Self.addonBuildSkipped(in: line) {
                        skippedAddonNames.insert(name)
                        if !addonNames.isEmpty {
                            let completed = builtAddonNames.count + skippedAddonNames.count
                            buildProgress = Double(completed) / Double(addonNames.count)
                            buildLog = "Skipped static addon \(completed)/\(addonNames.count): \(name)"
                        } else {
                            buildLog = "Skipped static addon: \(name)"
                        }
                    } else if line == "All addons built." {
                        buildProgress = 1
                        buildLog = "Built \(builtAddonNames.count) addon(s), skipped \(skippedAddonNames.count) static"
                    }
                }
            }
            guard built else {
                return fail(Self.buildFailureMessage(prefix: "Addon build failed", from: buildFailureLines))
            }
            guard !Task.isCancelled else { return }

            let pluginDists = findPluginDists(in: dirPath)
            guard !pluginDists.isEmpty else { return fail("No addon dist folders found") }

            guard await ensurePortForward() else { return fail("Could not connect to vphone over SSH") }
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
            guard await ensurePortForward() else { return fail("Could not connect to vphone over SSH") }
            guard !Task.isCancelled else { return }
            await deployPlugins(toRetry)
        }
    }

    private func deployPlugins(_ pluginDists: [(name: String, path: String)]) async {
        activeProcesses = []
        buildProgress = 0
        buildLog = "Deploying 0 of \(pluginDists.count) addons…"
        guard await primeSSHControlMaster() else {
            return fail("Could not connect to vphone over SSH")
        }
        guard !Task.isCancelled else { return }

        var results: [(name: String, path: String, ok: Bool)] = []
        for (index, plugin) in pluginDists.enumerated() {
            guard !Task.isCancelled else { return }
            buildLog = "Deploying addon \(index + 1)/\(pluginDists.count): \(plugin.name)"
            let ok = await deployOnePlugin(name: plugin.name, distPath: plugin.path)
            results.append((plugin.name, plugin.path, ok))
            buildProgress = Double(results.count) / Double(pluginDists.count)
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
        let restarted = await runBuildSSH(
            "echo '\(sshPassword)' | sudo -S killall -9 Discord; uiopen --bundleid com.hammerandchisel.discord",
            label: "restarting Discord"
        )
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

    // ensurePortForward()'s own readiness check is a raw TCP probe (nc -z) against the
    // locally forwarded port — it can succeed before the usbmux tunnel is actually ready
    // to carry a full SSH handshake through to the device's sshd, right after the forward
    // first comes up. A single attempt here would then fail outright (matching the old
    // "works on the second click" symptom); retry a few times instead so deployPlugins
    // doesn't need a manual re-click to ride out that warm-up window.
    func primeSSHControlMaster() async -> Bool {
        for attempt in 0..<3 {
            if await run(ssh: "true", timeout: 10) { return true }
            guard !Task.isCancelled else { return false }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(750)) }
        }
        return false
    }

    private func deployOnePlugin(name: String, distPath: String) async -> Bool {
        for attempt in 1...3 {
            guard !Task.isCancelled else { return false }
            if attempt > 1 {
                buildLog = "Retrying addon \(name) (\(attempt)/3)…"
                await closeSSHControlMaster()
                guard await ensurePortForward(), await primeSSHControlMaster() else { continue }
                try? await Task.sleep(for: .milliseconds(700))
            }
            let stagingPath = "/tmp/vbound-plugin-\(UUID().uuidString)"
            let uploaded = await run(args: [
                "sshpass", "-p", sshPassword, "scp",
                "-r",
                "-P", "2222",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "PubkeyAuthentication=no",
                "-o", "ConnectTimeout=8",
                "-o", "ServerAliveInterval=5",
                "-o", "ServerAliveCountMax=3",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(sshControlPath)",
                "-o", "ControlPersist=60",
                distPath, "mobile@127.0.0.1:\(stagingPath)"
            ], timeout: 45, onLaunch: { [weak self] p in self?.activeProcesses.append(p) })
            guard uploaded, !Task.isCancelled else { continue }

            let deployed = await run(
                ssh: pluginDeploymentCommand(name: name, stagingPath: stagingPath),
                timeout: 30,
                onLaunch: { [weak self] p in self?.activeProcesses.append(p) }
            )
            if deployed { return true }
        }
        return false
    }

    private func uploadDeb(from localPath: String, to remotePath: String) async -> String? {
        var lastError = ""
        for attempt in 0..<3 {
            guard !Task.isCancelled else { return nil }
            if attempt > 0 {
                buildLog = "Retrying upload (\(attempt + 1)/3)…"
                await closeSSHControlMaster()
                guard await ensurePortForward() else {
                    lastError = "could not reach vphone over SSH"
                    continue
                }
            }
            guard await primeSSHControlMaster() else {
                lastError = "could not open an SSH session to vphone"
                continue
            }
            guard !Task.isCancelled else { return nil }

            let (uploaded, output) = await runCapturingOutput(args: [
                "sshpass", "-p", sshPassword, "scp",
                "-P", "2222",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "PubkeyAuthentication=no",
                "-o", "ConnectTimeout=5",
                "-o", "ServerAliveInterval=5",
                "-o", "ServerAliveCountMax=2",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(sshControlPath)",  // #8
                "-o", "ControlPersist=60",
                localPath, "mobile@127.0.0.1:\(remotePath)"
            ], timeout: 180, onLaunch: { [weak self] p in self?.buildProcess = p })
            if uploaded { return nil }

            appendBuildLog(output)
            lastError = Self.lastMeaningfulLine(of: output)
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(750)) }
        }
        return lastError
    }

    private nonisolated static func lastMeaningfulLine(of output: String) -> String {
        let noisePrefixes = ["Warning: Permanently added", "Pseudo-terminal", "Connection to "]
        let line = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && !noisePrefixes.contains(where: $0.hasPrefix) } ?? ""
        return truncatedForDisplay(line)
    }

    private nonisolated static func truncatedForDisplay(_ line: String) -> String {
        line.count > 120 ? String(line.prefix(120)) + "…" : line
    }

    nonisolated static func strippingANSI(_ line: String) -> String {
        line.replacing(/\u{1B}\[[0-9;]*[A-Za-z]/, with: "")  // #2 — inline literal escapes SE-0401
    }

    private nonisolated static func looksLikeBuildFailure(_ line: String) -> Bool {
        let markers = ["Failed to build", "command not found", "error:", "fatal error:", "make: ***"]
        return markers.contains { line.localizedCaseInsensitiveContains($0) }
    }

    private nonisolated static func buildFailureMessage(prefix: String, from lines: [String]) -> String {
        let summary = lines.last { $0.hasPrefix("Failed to build") } ?? lines.last
        guard let summary, !summary.isEmpty else { return prefix }
        return "\(prefix) — \(truncatedForDisplay(summary))"
    }

    func buildUnbound(in directory: String) {
        buildTask = Task { [weak self] in
            guard let self else { return }
            if !isStreaming { startLogStream() }

            let dirPath = (directory as NSString).expandingTildeInPath
            let ncpu    = ProcessInfo.processInfo.processorCount
            var buildFailureLines: [String] = []

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
            ], onLaunch: { [weak self] p in self?.buildProcess = p }) { [weak self] lines in
                guard let self else { return }
                for raw in lines {
                    let line = Self.strippingANSI(raw)
                    appendBuildLog(line)
                    if Self.looksLikeBuildFailure(line) { buildFailureLines.append(line) }
                    guard line.hasPrefix("==>") || line.hasPrefix("> M") || line.hasPrefix("dm.pl:")
                    else { continue }
                    completedSteps += 1
                    if completedSteps > totalSteps { totalSteps = completedSteps + max(5, totalSteps / 10) }
                    if totalSteps > 0 {
                        let fraction = Double(completedSteps) / Double(totalSteps)
                        buildProgress = min(fraction, Self.buildProgressSoftCap)
                    }
                    var display = line
                    if      display.hasPrefix("==> ")    { display = String(display.dropFirst(4)) }
                    else if display.hasPrefix("> ")       { display = String(display.dropFirst(2)) }
                    else if display.hasPrefix("dm.pl: ") { display = String(display.dropFirst(7)) }
                    buildLog = display
                }
            }
            guard built else {
                return fail(Self.buildFailureMessage(prefix: "Build failed", from: buildFailureLines))
            }
            // Covers the race where cancelBuild() fires just as the process was already
            // exiting on its own (terminate() has no effect after that) — without this,
            // a cancellation landing in that narrow window would fall through and keep
            // driving the pipeline into upload/install as if nothing happened.
            guard !Task.isCancelled else { return }

            guard let debPath = findDeb(in: dirPath) else { return fail("No .deb found") }
            let debName   = URL(fileURLWithPath: debPath).lastPathComponent
            let remoteDeb = "/tmp/\(debName)"

            guard await ensurePortForward() else { return fail("Could not connect to vphone over SSH") }
            guard !Task.isCancelled else { return }

            buildPhase = .uploading; buildLog = ""; buildProgress = 0
            if let uploadError = await uploadDeb(from: debPath, to: remoteDeb) {
                return fail(uploadError.isEmpty ? "Upload failed" : "Upload failed — \(uploadError)")
            }
            guard !Task.isCancelled else { return }

            buildPhase = .installing
            let installed = await runBuildSSH(
                "echo '\(sshPassword)' | sudo -S dpkg -i '\(remoteDeb)'",
                label: "installing the tweak"
            )
            guard installed else { return fail("Install failed") }
            guard !Task.isCancelled else { return }

            buildPhase = .restarting
            let restarted = await runBuildSSH(
                "echo '\(sshPassword)' | sudo -S killall -9 Discord; uiopen --bundleid com.hammerandchisel.discord",
                label: "restarting Discord"
            )
            guard !Task.isCancelled else { return }
            guard restarted else { return fail("Discord restart failed") }

            lastTweakResult = BuildResultSummary(succeeded: true, date: Date())
            buildPhase = .succeeded; buildLog = ""; buildProgress = 0
            playBuildSound(success: true)
            notifyBuildCompletion(target: "Tweak", succeeded: true, message: "Build installed.")
            scheduleReset()
        }
    }

    private func runBuildSSH(_ command: String, label: String) async -> Bool {
        for attempt in 1...3 {
            guard !Task.isCancelled else { return false }
            if attempt > 1 {
                buildLog = "Retrying \(label) (\(attempt)/3)…"
                await closeSSHControlMaster()
                guard await ensurePortForward(), await primeSSHControlMaster() else { continue }
            }
            if await run(ssh: command, timeout: 30, onLaunch: { [weak self] p in self?.buildProcess = p }) {
                return true
            }
            if attempt < 3 { try? await Task.sleep(for: .milliseconds(700)) }
        }
        return false
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
        pluginDirectories(in: directory).compactMap { pluginDirectory in
            let distDirectory = pluginDirectory.appending(path: "dist")
            guard (try? distDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return (pluginDirectory.lastPathComponent, distDirectory.path)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func findAddonNames(in directory: String) -> [String] {
        pluginDirectories(in: directory)
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "manifest.json").path) }
            .map(\.lastPathComponent)
    }

    private func pluginDirectories(in directory: String) -> [URL] {
        let pluginsDirectory = URL(fileURLWithPath: directory).appending(path: "plugins")
        guard let pluginDirectories = try? FileManager.default.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return pluginDirectories
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private nonisolated static func addonBuildStarting(in line: String) -> String? {
        guard line.hasPrefix("Building "), line.hasSuffix("…") else { return nil }
        return String(line.dropFirst("Building ".count).dropLast())
    }

    private nonisolated static func addonBuildFinished(in line: String) -> String? {
        guard line.hasPrefix("Built "), line.hasSuffix(".") else { return nil }
        return String(line.dropFirst("Built ".count).dropLast())
    }

    private nonisolated static func addonBuildSkipped(in line: String) -> String? {
        let suffix = " (static addon)."
        guard line.hasPrefix("Skipping "), line.hasSuffix(suffix) else { return nil }
        return String(line.dropFirst("Skipping ".count).dropLast(suffix.count))
    }

    private func pluginDeploymentCommand(name: String, stagingPath: String) -> String {
        let script = """
        metadata="$(grep -l -m 1 'com.hammerandchisel.discord' /private/var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist 2>/dev/null | head -n 1)"
        [ -n "$metadata" ] || exit 1
        container="$(dirname "$metadata")"
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
