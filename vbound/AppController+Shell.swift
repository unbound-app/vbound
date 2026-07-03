import AppKit

extension AppController {

    func connectShell() {
        guard !isShellConnected else { return }
        shellBuffer.reset()
        shellLines = shellBuffer.lines
        beginShellConnection()
    }

    // Split out from connectShell() so auto-reconnect can re-enter here directly —
    // reconnecting after a transient drop shouldn't wipe the scrollback you were just
    // looking at; only a fresh, user-initiated Connect click does.
    private func beginShellConnection() {
        shellAutoReconnect = true  // #6: cleared by disconnectShell() for deliberate disconnects

        Task { [weak self] in
            guard let self else { return }
            await ensurePortForward()

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [
                "sshpass", "-p", sshPassword,
                "ssh", "-tt",
                "-p", "2222",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(AppController.sshControlPath)",  // #8
                "-o", "ControlPersist=60",
                "mobile@127.0.0.1"
            ]
            p.environment = enrichedEnvironment

            let outPipe = Pipe()
            let inPipe  = Pipe()
            p.standardOutput = outPipe
            p.standardError  = outPipe
            p.standardInput  = inPipe

            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let data = handle.availableData
                guard !data.isEmpty, let raw = String(data: data, encoding: .utf8) else { return }

                // DispatchQueue.main.async puts us on the main thread.
                // assumeIsolated registers that fact with the Swift actor runtime so
                // @Observable property accesses don't trap under Swift 6 (#10).
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        self.shellBuffer.feed(raw, maxLines: self.shellBufferSize)
                        self.shellLines = self.shellBuffer.lines  // single mutation
                    }
                }
            }

            do { try p.run() } catch { return }

            DispatchQueue.main.async {
                self.shellProcess     = p
                self.shellInputHandle = inPipe.fileHandleForWriting
                self.isShellConnected = true
            }

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                p.terminationHandler = { _ in cont.resume() }
            }

            outPipe.fileHandleForReading.readabilityHandler = nil

            DispatchQueue.main.async { [weak self] in
                self?.shellProcess     = nil
                self?.shellInputHandle = nil
                self?.isShellConnected = false
            }

            // Auto-reconnect on unexpected drops; suppressed when disconnectShell() clears the flag (#6)
            guard self.shellAutoReconnect, !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, self.shellAutoReconnect else { return }
            await MainActor.run { [weak self] in self?.beginShellConnection() }
        }
    }

    func sendShellInput(_ text: String) {
        guard let handle = shellInputHandle,
              let data   = (text + "\n").data(using: .utf8) else { return }
        handle.write(data)
    }

    func sendShellControlByte(_ byte: UInt8) {
        guard let handle = shellInputHandle else { return }
        handle.write(Data([byte]))
    }

    func disconnectShell() {
        shellAutoReconnect = false  // prevent reconnect on deliberate disconnect (#6)
        shellProcess?.terminate()
        shellProcess     = nil
        shellInputHandle = nil
        isShellConnected = false
    }
}
