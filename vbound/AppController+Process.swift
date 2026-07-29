import AppKit

nonisolated final class ProcessLineBuffer: @unchecked Sendable {
    private var pending = ""

    func take(_ chunk: String) -> [String] {
        pending += chunk
        var parts = pending.components(separatedBy: "\n")
        pending = parts.removeLast()
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func flush() -> [String] {
        let rest = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        pending = ""
        return rest.isEmpty ? [] : [rest]
    }
}

extension AppController {

    static let defaultVphoneCLIPath = "/opt/homebrew/bin/vphone-cli"
    static let defaultVphoneVMName = "vphone"

    // Device SSH/sudo password — configurable in Settings, defaults to vphone's stock "alpine".
    // Trimmed because a pasted password with a trailing newline/space (easy to pick up
    // from a copied terminal line or text file) would otherwise silently fail SSH/sudo
    // auth with no indication that invisible whitespace was the actual cause.
    var sshPassword: String {
        let stored = UserDefaults.standard.string(forKey: "sshPassword")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stored?.isEmpty == false) ? stored! : "alpine"
    }

    static func pathValid(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath)
    }

    static func executableValid(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: (path as NSString).expandingTildeInPath)
    }

    var autoAttachEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoAttachEnabled") as? Bool ?? true
    }

    // Off by default — auto-starting a persistent stream/session without an explicit
    // click is a bigger behavioral surprise than auto-attach, so this is opt-in.
    var autoStartLogStreamEnabled: Bool {
        UserDefaults.standard.bool(forKey: "autoStartLogStreamEnabled")
    }

    var autoConnectShellEnabled: Bool {
        UserDefaults.standard.bool(forKey: "autoConnectShellEnabled")
    }

    var logBufferSize: Int {
        let v = UserDefaults.standard.integer(forKey: "logBufferSize")
        return v > 0 ? v : 2000
    }

    // Separate from logBufferSize: they cap two unrelated things (streamed Unbound/React
    // Native entries vs. shell scrollback) and shouldn't share one setting silently.
    var shellBufferSize: Int {
        let v = UserDefaults.standard.integer(forKey: "shellBufferSize")
        return v > 0 ? v : 2000
    }

    var globalHotkeyEnabled: Bool {
        UserDefaults.standard.bool(forKey: "globalHotkeyEnabled")
    }

    var buildSoundsEnabled: Bool {
        UserDefaults.standard.object(forKey: "buildSoundsEnabled") as? Bool ?? true
    }

    var buildNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: "buildNotificationsEnabled") as? Bool ?? true
    }

    var enrichedEnvironment: [String: String] {
        var env  = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = "/opt/homebrew/bin:/usr/local/bin:\(home)/.bun/bin:\(home)/.local/bin"
        env["PATH"] = "\(extra):\(env["PATH"] ?? "/usr/bin:/bin")"
        return env
    }

    func run(
        args: [String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        onLaunch: ((Process) -> Void)? = nil,
        onOutput: (([String]) -> Void)? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL       = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments           = args
            p.environment         = enrichedEnvironment
            p.currentDirectoryURL = workingDirectory

            let outputPipe: Pipe? = onOutput == nil ? nil : Pipe()
            let buffer = ProcessLineBuffer()
            if let onOutput, let pipe = outputPipe {
                p.standardOutput = pipe
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    let lines = buffer.take(text)
                    guard !lines.isEmpty else { return }
                    DispatchQueue.main.async { onOutput(lines) }
                }
            }

            p.terminationHandler = { proc in
                if let outputPipe, let onOutput {
                    outputPipe.fileHandleForReading.readabilityHandler = nil
                    let tail = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    var lines = tail.isEmpty ? [] : buffer.take(String(decoding: tail, as: UTF8.self))
                    lines += buffer.flush()
                    if !lines.isEmpty { DispatchQueue.main.async { onOutput(lines) } }
                }
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do {
                try p.run()
                onLaunch?(p)
                // Unlike the SSH calls (which get -o ConnectTimeout=5), plain pymobiledevice3
                // invocations have no built-in timeout — if the device is in a bad USB state,
                // this would otherwise hang the awaiting Task forever with no way to cancel.
                if let timeout {
                    Task {
                        try? await Task.sleep(for: .seconds(timeout))
                        if p.isRunning { p.terminate() }
                    }
                }
            } catch { continuation.resume(returning: false) }
        }
    }

    func run(
        ssh command: String,
        timeout: TimeInterval? = nil,
        onLaunch: ((Process) -> Void)? = nil
    ) async -> Bool {
        await run(args: [
            "sshpass", "-p", sshPassword,
            "ssh",
            "-p", "2222",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "PubkeyAuthentication=no",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(sshControlPath)",  // #8
            "-o", "ControlPersist=60",
            "mobile@127.0.0.1",
            command
        ], timeout: timeout, onLaunch: onLaunch)
    }

    func runCapturingOutput(
        args: [String],
        timeout: TimeInterval? = nil,
        onLaunch: ((Process) -> Void)? = nil
    ) async -> (ok: Bool, output: String) {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments     = args
            p.environment   = enrichedEnvironment

            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError  = pipe

            let q = DispatchQueue(label: "vbound.run-output")
            var buf = Data()

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let d = handle.availableData
                guard !d.isEmpty else { return }
                q.async { buf.append(d) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let tail = pipe.fileHandleForReading.readDataToEndOfFile()
                let succeeded = proc.terminationStatus == 0
                q.async {
                    if !tail.isEmpty { buf.append(tail) }
                    continuation.resume(returning: (succeeded, String(data: buf, encoding: .utf8) ?? ""))
                }
            }
            do {
                try p.run()
                onLaunch?(p)
                if let timeout {
                    Task {
                        try? await Task.sleep(for: .seconds(timeout))
                        if p.isRunning { p.terminate() }
                    }
                }
            } catch { continuation.resume(returning: (false, "")) }
        }
    }

    func runCapture(args: [String], timeout: TimeInterval? = nil) async -> String {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments     = args
            p.environment   = enrichedEnvironment
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError  = pipe

            let q = DispatchQueue(label: "vbound.capture")
            var buf = Data()

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let d = handle.availableData
                guard !d.isEmpty else { return }
                q.async { buf.append(d) }
            }
            p.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                let tail = pipe.fileHandleForReading.readDataToEndOfFile()
                q.async {
                    if !tail.isEmpty { buf.append(tail) }
                    continuation.resume(returning: String(data: buf, encoding: .utf8) ?? "")
                }
            }
            do {
                try p.run()
                // See run(args:timeout:) — pymobiledevice3 has no built-in timeout of its own.
                if let timeout {
                    Task {
                        try? await Task.sleep(for: .seconds(timeout))
                        if p.isRunning { p.terminate() }
                    }
                }
            } catch { continuation.resume(returning: "") }
        }
    }

    func closeSSHControlMaster(at controlPath: String? = nil) async {
        _ = await run(args: [
            "ssh", "-O", "exit",
            "-o", "ControlPath=\(controlPath ?? sshControlPath)",
            "mobile@127.0.0.1"
        ], timeout: 5)
    }

    @discardableResult
    func ensurePortForward() async -> Bool {
        let reachable = await run(args: ["nc", "-z", "-w", "1", "127.0.0.1", "2222"])
        if reachable, forwardProcess?.isRunning == true { return true }

        forwardProcess?.terminate()
        forwardProcess = nil
        await closeSSHControlMaster()
        try? await Task.sleep(for: .milliseconds(250))

        var udid = vphoneUDID
        if udid == nil {
            udid = await resolveVphoneUDID().0
            vphoneUDID = udid
        }
        guard let udid else { return false }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments     = ["pymobiledevice3", "usbmux", "forward", "2222", "22", "--udid", udid]
        p.environment   = enrichedEnvironment
        // Assign only on success so forwardProcess never holds a ref to a process that
        // failed to launch (#5)
        do {
            try p.run()
            forwardProcess = p
        } catch {
            return false
        }

        for _ in 0..<20 {
            guard p.isRunning else { break }
            if await run(args: ["nc", "-z", "-w", "1", "127.0.0.1", "2222"]) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        if p.isRunning { p.terminate() }
        if forwardProcess === p { forwardProcess = nil }
        return false
    }
}
