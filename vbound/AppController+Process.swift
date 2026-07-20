import AppKit

extension AppController {

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
        onOutput: ((String) -> Void)? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL       = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments           = args
            p.environment         = enrichedEnvironment
            p.currentDirectoryURL = workingDirectory

            if let onOutput {
                let pipe = Pipe()
                p.standardOutput = pipe
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    let lines = text.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if let last = lines.last { DispatchQueue.main.async { onOutput(last) } }
                }
            }

            p.terminationHandler = { proc in
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

    func run(ssh command: String, onLaunch: ((Process) -> Void)? = nil) async -> Bool {
        await run(args: [
            "sshpass", "-p", sshPassword,
            "ssh",
            "-p", "2222",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(AppController.sshControlPath)",  // #8
            "-o", "ControlPersist=60",
            "mobile@127.0.0.1",
            command
        ], onLaunch: onLaunch)
    }

    func runCapture(args: [String], timeout: TimeInterval? = nil) async -> String {
        await withCheckedContinuation { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments     = args
            p.environment   = enrichedEnvironment
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError  = Pipe()

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

    func ensurePortForward() async {
        let reachable = await run(args: ["nc", "-z", "-w", "1", "127.0.0.1", "2222"])
        if reachable { return }

        forwardProcess?.terminate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments     = ["pymobiledevice3", "usbmux", "forward", "2222", "22"]
        p.environment   = enrichedEnvironment
        // Assign only on success so forwardProcess never holds a ref to a process that
        // failed to launch (#5)
        do { try p.run(); forwardProcess = p } catch {}

        try? await Task.sleep(for: .milliseconds(1500))
    }
}
