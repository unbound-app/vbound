import AppKit

extension AppController {

    var enrichedEnvironment: [String: String] {
        var env  = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin"
        env["PATH"] = "\(extra):\(env["PATH"] ?? "/usr/bin:/bin")"
        return env
    }

    func run(
        args: [String],
        workingDirectory: URL? = nil,
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
            do { try p.run() } catch { continuation.resume(returning: false) }
        }
    }

    func run(ssh command: String) async -> Bool {
        await run(args: [
            "sshpass", "-p", "alpine",
            "ssh",
            "-p", "2222",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=/tmp/vbound-ssh-mux",
            "-o", "ControlPersist=60",
            "mobile@127.0.0.1",
            command
        ])
    }

    func runCapture(args: [String]) async -> String {
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
            do { try p.run() } catch { continuation.resume(returning: "") }
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
        try? p.run()
        forwardProcess = p

        try? await Task.sleep(for: .milliseconds(1500))
    }
}
