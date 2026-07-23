import AppKit

extension AppController {

    func connectShell() {
        // Also guards against double-invocation while already mid-handshake — without
        // isShellConnecting here, a second click before isShellConnected flips true would
        // spawn a second concurrent ssh process on top of the first.
        guard !isShellConnected, !isShellConnecting else { return }
        shellBuffer.reset()
        shellLines = shellBuffer.lines
        beginShellConnection()
    }

    // Split out from connectShell() so auto-reconnect can re-enter here directly —
    // reconnecting after a transient drop shouldn't wipe the scrollback you were just
    // looking at; only a fresh, user-initiated Connect click does.
    private func beginShellConnection() {
        shellAutoReconnect = true  // #6: cleared by disconnectShell() for deliberate disconnects
        isShellConnecting  = true  // cleared once the ssh process actually launches (or fails) below

        Task { [weak self] in
            guard let self else { return }
            guard await ensurePortForward() else {
                await retryShellConnectionIfNeeded()
                return
            }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [
                "sshpass", "-p", sshPassword,
                "ssh", "-tt",
                "-p", "2222",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "PubkeyAuthentication=no",
                "-o", "ConnectTimeout=5",
                "-o", "ServerAliveInterval=5",
                "-o", "ServerAliveCountMax=2",
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

            do { try p.run() } catch {
                await retryShellConnectionIfNeeded()
                return
            }

            DispatchQueue.main.async {
                self.shellProcess     = p
                self.shellInputHandle = inPipe.fileHandleForWriting
                self.isShellConnected = true
                self.isShellConnecting = false
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
            await retryShellConnectionIfNeeded()
        }
    }

    private func retryShellConnectionIfNeeded() async {
        guard shellAutoReconnect, !Task.isCancelled else {
            isShellConnecting = false
            return
        }
        isShellConnecting = true
        try? await Task.sleep(for: .seconds(2))
        guard shellAutoReconnect, !Task.isCancelled else {
            isShellConnecting = false
            return
        }
        beginShellConnection()
    }

    func sendShellInput(_ text: String) {
        guard let handle = shellInputHandle,
              let data   = (text + "\n").data(using: .utf8) else { return }
        handle.write(data)
    }

    // Single bytes (^C, ^D, …) and multi-byte ANSI escape sequences (arrow keys are
    // ESC [ A / ESC [ B, not one byte) both go through here.
    func sendShellControlBytes(_ bytes: [UInt8]) {
        guard let handle = shellInputHandle else { return }
        handle.write(Data(bytes))
    }

    func disconnectShell() {
        shellAutoReconnect = false  // prevent reconnect on deliberate disconnect (#6)
        isShellConnecting  = false
        shellProcess?.terminate()
        shellProcess     = nil
        shellInputHandle = nil
        isShellConnected = false
    }
}
