import AppKit

extension AppController {

    func connectShell() {
        guard !isShellConnected else { return }
        shellAutoReconnect = true  // #6: cleared by disconnectShell() for deliberate disconnects
        shellLines = []

        Task { [weak self] in
            guard let self else { return }
            await ensurePortForward()

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [
                "sshpass", "-p", "alpine",
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

                let ansiCsi = /\u{1B}\[[ -?]*[@-~]/
                let ansiEsc = /\u{1B}[^\[]/
                let stripped = raw
                    .replacing(ansiCsi, with: "")
                    .replacing(ansiEsc, with: "")

                // DispatchQueue.main.async puts us on the main thread.
                // assumeIsolated registers that fact with the Swift actor runtime so
                // @Observable property accesses don't trap under Swift 6 (#10).
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        // Work on a local copy — single @Observable mutation at the end (#1)
                        var lines = self.shellLines
                        var i = stripped.startIndex
                        while i < stripped.endIndex {
                            let c  = stripped[i]
                            let ni = stripped.index(after: i)
                            switch c {
                            case "\r":
                                if ni < stripped.endIndex && stripped[ni] == "\n" {
                                    lines.append("")
                                    i = stripped.index(after: ni)
                                } else {
                                    if lines.isEmpty { lines.append("") }
                                    let hadContent = !lines[lines.count - 1].isEmpty
                                    lines[lines.count - 1] = ""
                                    if hadContent && lines.dropLast().contains(where: { !$0.isEmpty }) {
                                        lines.insert("", at: lines.count - 1)
                                    }
                                    i = ni
                                }
                            case "\n":
                                lines.append("")
                                i = ni
                            default:
                                if lines.isEmpty { lines.append("") }
                                lines[lines.count - 1].append(c)
                                i = ni
                            }
                        }
                        // removeFirst avoids a full array copy vs Array(suffix(n)) (#3)
                        if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
                        self.shellLines = lines  // single mutation
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
            await MainActor.run { [weak self] in self?.connectShell() }
        }
    }

    func sendShellInput(_ text: String) {
        guard let handle = shellInputHandle,
              let data   = (text + "\n").data(using: .utf8) else { return }
        handle.write(data)
    }

    func sendShellInterrupt() {
        guard let handle = shellInputHandle else { return }
        handle.write(Data([0x03]))  // ETX = Ctrl+C
    }

    func disconnectShell() {
        shellAutoReconnect = false  // prevent reconnect on deliberate disconnect (#6)
        shellProcess?.terminate()
        shellProcess     = nil
        shellInputHandle = nil
        isShellConnected = false
    }
}
