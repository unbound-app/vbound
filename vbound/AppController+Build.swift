import AppKit
import CryptoKit
import UserNotifications

private struct PluginDistribution {
    let name: String
    let label: String
    let path: String
    let sourceFingerprint: String
}

private struct PluginSource {
    let name: String
    let label: String
    let path: String
    let sourceFingerprint: String
}

private struct DeployedPlugin {
    let sourceFingerprint: String?
}

private struct PluginManifest: Decodable {
    let id: String?
}

private struct AddonWorkspaceConfig: Decodable {
    let build: String?
    let output: String?
}

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
            lastPluginsWorkDir = dirPath
            lastFailedPlugins = []
            buildLog = ""; buildLogFull = ""; buildProgress = 0; buildPhase = .buildingPlugins; activeBuildTarget = .plugins
            guard await ensurePortForward() else { return fail("Could not connect to vphone over SSH") }
            guard !Task.isCancelled else { return }

            guard let workspaceConfig = addonWorkspaceConfig(in: dirPath) else {
                return fail("Could not read unbound.config.json")
            }
            guard var deployedPlugins = await deployedPlugins() else {
                return fail("Could not read deployed addon state")
            }
            let outputDirectory = workspaceConfig.output ?? "dist"
            let sources = findPluginSources(in: dirPath, outputDirectory: outputDirectory)
            guard !sources.isEmpty else { return fail("No addon folders found") }
            let sourcesToAdopt = sources.filter {
                deployedPlugins[$0.name].map { $0.sourceFingerprint == nil } ?? false
            }
            if !sourcesToAdopt.isEmpty {
                guard await adoptPluginFingerprints(sourcesToAdopt) else {
                    return fail("Could not register deployed addons")
                }
                for source in sourcesToAdopt {
                    deployedPlugins[source.name] = DeployedPlugin(sourceFingerprint: source.sourceFingerprint)
                }
            }
            let changedSources = sources.filter {
                deployedPlugins[$0.name]?.sourceFingerprint != $0.sourceFingerprint
            }
            guard !changedSources.isEmpty else {
                return await restartDiscordAfterAddonDeployment(message: "All addons are already deployed.")
            }

            let built = await buildChangedPlugins(changedSources, command: workspaceConfig.build ?? "bun run build")
            guard built else { return }
            guard !Task.isCancelled else { return }

            let pluginDists = pluginDistributions(
                from: changedSources,
                outputDirectory: outputDirectory
            )
            guard pluginDists.count == changedSources.count else {
                return fail("A changed addon did not produce a dist folder")
            }

            buildPhase = .deployingPlugins
            await deployPlugins(pluginDists)
        }
    }

    func retryFailedPlugins() {
        guard !lastFailedPlugins.isEmpty, !buildPhase.isRunning else { return }
        let toRetry = lastFailedPlugins.map {
            PluginDistribution(
                name: $0.name,
                label: $0.label,
                path: $0.path,
                sourceFingerprint: $0.sourceFingerprint
            )
        }
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

    private func deployPlugins(_ pluginDists: [PluginDistribution]) async {
        activeProcesses = []
        buildProgress = 0
        buildLog = "Deploying 0 of \(pluginDists.count) addons…"
        guard await primeSSHControlMaster() else {
            return fail("Could not connect to vphone over SSH")
        }
        guard !Task.isCancelled else { return }

        var results: [(plugin: PluginDistribution, ok: Bool)] = []
        for (index, plugin) in pluginDists.enumerated() {
            guard !Task.isCancelled else { return }
            buildLog = "Deploying addon \(index + 1)/\(pluginDists.count): \(plugin.label)"
            let ok = await deployOnePlugin(
                name: plugin.name,
                label: plugin.label,
                distPath: plugin.path,
                sourceFingerprint: plugin.sourceFingerprint
            )
            results.append((plugin, ok))
            buildProgress = Double(results.count) / Double(pluginDists.count)
        }
        guard !Task.isCancelled else { return }

        let succeededNames = results.filter(\.ok).map(\.plugin.label)
        let failed = results.filter { !$0.ok }.map {
            FailedPlugin(
                name: $0.plugin.name,
                label: $0.plugin.label,
                path: $0.plugin.path,
                sourceFingerprint: $0.plugin.sourceFingerprint
            )
        }
        lastFailedPlugins = failed

        guard !succeededNames.isEmpty else {
            return fail(failed.count == pluginDists.count
                ? "All \(failed.count) addon(s) failed to deploy"
                : "Addon deployment failed")
        }

        if failed.isEmpty {
            await restartDiscordAfterAddonDeployment(message: "All addons deployed.")
        } else {
            let names = failed.map(\.label).joined(separator: ", ")
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

    private func deployOnePlugin(
        name: String,
        label: String,
        distPath: String,
        sourceFingerprint: String
    ) async -> Bool {
        for attempt in 1...3 {
            guard !Task.isCancelled else { return false }
            if attempt > 1 {
                buildLog = "Retrying addon \(label) (\(attempt)/3)…"
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
                ssh: pluginDeploymentCommand(
                    name: name,
                    stagingPath: stagingPath,
                    sourceFingerprint: sourceFingerprint
                ),
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

    private func addonWorkspaceConfig(in directory: String) -> AddonWorkspaceConfig? {
        let configURL = URL(fileURLWithPath: directory).appending(path: "unbound.config.json")
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(AddonWorkspaceConfig.self, from: data)
    }

    private func findPluginSources(in directory: String, outputDirectory: String) -> [PluginSource] {
        let workspaceDirectory = URL(fileURLWithPath: directory)
        return pluginDirectories(in: directory).compactMap { pluginDirectory in
            let manifestURL = pluginDirectory.appending(path: "manifest.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path),
                  let sourceFingerprint = Self.addonSourceFingerprint(
                    at: pluginDirectory,
                    workspaceDirectory: workspaceDirectory,
                    outputDirectory: outputDirectory
                  )
            else { return nil }
            let name = pluginDirectory.lastPathComponent
            let manifest = try? JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: manifestURL))
            let manifestID = manifest?.id?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (manifestID?.isEmpty == false) ? manifestID! : name
            return PluginSource(name: name, label: label, path: pluginDirectory.path, sourceFingerprint: sourceFingerprint)
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private func buildChangedPlugins(_ sources: [PluginSource], command: String) async -> Bool {
        for (index, source) in sources.enumerated() {
            guard !Task.isCancelled else { return false }
            buildLog = "Building addon \(index + 1)/\(sources.count): \(source.label)"
            var failureLines: [String] = []
            let built = await run(args: [
                "/bin/zsh", "-l", "-c",
                "cd \(Self.shellQuoted(source.path)) && \(command) 2>&1"
            ], onLaunch: { [weak self] process in self?.buildProcess = process }) { [weak self] lines in
                guard let self else { return }
                for raw in lines {
                    let line = Self.strippingANSI(raw)
                    appendBuildLog(line)
                    if Self.looksLikeBuildFailure(line) { failureLines.append(line) }
                    buildLog = line
                }
            }
            guard built else {
                fail(Self.buildFailureMessage(prefix: "Addon build failed: \(source.label)", from: failureLines))
                return false
            }
            buildProgress = Double(index + 1) / Double(sources.count) * 0.5
        }
        return true
    }

    private func pluginDistributions(
        from sources: [PluginSource],
        outputDirectory: String
    ) -> [PluginDistribution] {
        sources.compactMap { source in
            let output = URL(fileURLWithPath: source.path).appending(path: outputDirectory)
            guard (try? output.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return PluginDistribution(
                name: source.name,
                label: source.label,
                path: output.path,
                sourceFingerprint: source.sourceFingerprint
            )
        }
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

    private func restartDiscordAfterAddonDeployment(message: String) async {
        buildPhase = .restarting
        let restarted = await runBuildSSH(
            "echo '\(sshPassword)' | sudo -S killall -9 Discord; uiopen --bundleid com.hammerandchisel.discord",
            label: "restarting Discord"
        )
        guard !Task.isCancelled else { return }
        guard restarted else { return fail("Discord restart failed") }
        lastAddonsResult = BuildResultSummary(succeeded: true, date: Date())
        buildPhase = .pluginsDeployed; buildLog = ""; buildProgress = 0
        playBuildSound(success: true)
        notifyBuildCompletion(target: "Addons", succeeded: true, message: message)
        scheduleReset()
    }

    private func deployedPlugins() async -> [String: DeployedPlugin]? {
        let script = """
        metadata="$(grep -l -m 1 'com.hammerandchisel.discord' /private/var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist 2>/dev/null | head -n 1)"
        [ -n "$metadata" ] || exit 1
        container="$(dirname "$metadata")"
        plugins="$container/Documents/Unbound/Plugins"
        [ -d "$plugins" ] || exit 0
        for plugin in "$plugins"/*; do
          [ -d "$plugin" ] || continue
          fingerprint="$plugin/.vbound-source-sha256"
          value=""
          [ -f "$fingerprint" ] && value="$(cat "$fingerprint")"
          printf '%s\\t%s\\n' "$(basename "$plugin")" "$value"
        done
        """
        let result = await runCapturingOutput(
            args: sshArguments(for: rootShellCommand(script)),
            timeout: 30,
            onLaunch: { [weak self] process in self?.buildProcess = process }
        )
        guard result.ok else { return nil }
        return Dictionary(uniqueKeysWithValues: result.output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let parts = line.split(
                    separator: "\t",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                ).map(String.init)
                guard parts.count == 2, !parts[0].isEmpty else { return nil }
                let fingerprint = parts[1].isEmpty ? nil : parts[1]
                return (parts[0], DeployedPlugin(sourceFingerprint: fingerprint))
            })
    }

    private func adoptPluginFingerprints(_ sources: [PluginSource]) async -> Bool {
        let writes = sources.map {
            "printf '%s\\n' \(Self.shellQuoted($0.sourceFingerprint)) > \"$plugins\"/\(Self.shellQuoted($0.name))/.vbound-source-sha256"
        }.joined(separator: "\n")
        let script = """
        metadata="$(grep -l -m 1 'com.hammerandchisel.discord' /private/var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist 2>/dev/null | head -n 1)"
        [ -n "$metadata" ] || exit 1
        container="$(dirname "$metadata")"
        plugins="$container/Documents/Unbound/Plugins"
        \(writes)
        """
        return await run(
            ssh: rootShellCommand(script),
            timeout: 30,
            onLaunch: { [weak self] process in self?.buildProcess = process }
        )
    }

    private func sshArguments(for command: String) -> [String] {
        [
            "sshpass", "-p", sshPassword,
            "ssh",
            "-p", "2222",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "PubkeyAuthentication=no",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(sshControlPath)",
            "-o", "ControlPersist=60",
            "mobile@127.0.0.1",
            command
        ]
    }

    private func rootShellCommand(_ script: String) -> String {
        let encodedScript = Data(script.utf8).base64EncodedString()
        return "{ printf '%s\\n' \(Self.shellQuoted(sshPassword)); "
             + "printf '%s' \(Self.shellQuoted(encodedScript)) | /var/jb/usr/bin/base64 -d; "
             + "} | sudo -S /var/jb/usr/bin/sh"
    }

    private nonisolated static func addonSourceFingerprint(
        at sourceDirectory: URL,
        workspaceDirectory: URL,
        outputDirectory: String
    ) -> String? {
        var fileURLs: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        ) else { return nil }
        let ignoredDirectories: Set<String> = [outputDirectory, "node_modules", ".git"]
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true, ignoredDirectories.contains(fileURL.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if values?.isRegularFile == true { fileURLs.append(fileURL) }
        }
        for name in ["unbound.config.json", "package.json", "bun.lock"] {
            let fileURL = workspaceDirectory.appending(path: name)
            if FileManager.default.fileExists(atPath: fileURL.path) { fileURLs.append(fileURL) }
        }
        var hasher = SHA256()
        for fileURL in fileURLs.sorted(by: { $0.path < $1.path }) {
            guard let contents = try? Data(contentsOf: fileURL) else { return nil }
            let relativePath: String
            if fileURL.path.hasPrefix(sourceDirectory.path + "/") {
                relativePath = String(fileURL.path.dropFirst(sourceDirectory.path.count + 1))
            } else {
                relativePath = "workspace/\(fileURL.lastPathComponent)"
            }
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: contents)
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func pluginDeploymentCommand(name: String, stagingPath: String, sourceFingerprint: String) -> String {
        let script = """
        metadata="$(grep -l -m 1 'com.hammerandchisel.discord' /private/var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist 2>/dev/null | head -n 1)"
        [ -n "$metadata" ] || exit 1
        container="$(dirname "$metadata")"
        plugins="$container/Documents/Unbound/Plugins"
        mkdir -p "$plugins"
        rm -rf "$plugins"/\(Self.shellQuoted(name))
        mv \(Self.shellQuoted(stagingPath)) "$plugins"/\(Self.shellQuoted(name))
        printf '%s\\n' \(Self.shellQuoted(sourceFingerprint)) > "$plugins"/\(Self.shellQuoted(name))/.vbound-source-sha256
        """
        return rootShellCommand(script)
    }

    // Not private: AppController+Mount.swift's root-sftp provisioning script needs the
    // same remote-shell quoting.
    nonisolated static func shellQuoted(_ value: String) -> String {
        "'\(value.replacing("'", with: "'\\\"'\\\"'"))'"
    }
}
