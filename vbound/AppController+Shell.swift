import AppKit

extension AppController {

    func connectShell() {
        guard !isShellConnected else { return }
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
                "-o", "ControlPath=/tmp/vbound-ssh-mux",
                "-o", "ControlPersist=60",
                "mobile@127.0.0.1"
            ]
            p.environment = enrichedEnvironment

            let outPipe = Pipe()
            let inPipe  = Pipe()
            p.standardOutput = outPipe
            p.standardError  = outPipe
            p.standardInput  = inPipe

            // Read output chunks immediately so partial lines (prompts) appear
            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let data = handle.availableData
                guard !data.isEmpty, let raw = String(data: data, encoding: .utf8) else { return }

                // Strip ANSI/terminal control sequences
                let stripped = raw
                    .replacingOccurrences(of: "\u{1B}\\[[\\x20-\\x3f]*[\\x40-\\x7e]", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\u{1B}[^\\[]", with: "", options: .regularExpression)

                DispatchQueue.main.async {
                    // Scan character by character so \r (alone) resets the current line
                    // and only \r\n is treated as a line ending — this hides zsh's EOL
                    // marker (% + spaces + \r) which overwrites itself in a real terminal.
                    var i = stripped.startIndex
                    while i < stripped.endIndex {
                        let c = stripped[i]
                        let ni = stripped.index(after: i)
                        switch c {
                        case "\r":
                            if ni < stripped.endIndex && stripped[ni] == "\n" {
                                self.shellLines.append("")
                                i = stripped.index(after: ni)
                            } else {
                                // Carriage return: reset current line (overwrite mode).
                                // If the line being erased had content (the zsh EOL marker
                                // "% <spaces>\r"), insert a blank separator before the reset
                                // so the next prompt has visual space from the output above.
                                if self.shellLines.isEmpty { self.shellLines.append("") }
                                let hadContent = !self.shellLines[self.shellLines.count - 1].isEmpty
                                self.shellLines[self.shellLines.count - 1] = ""
                                if hadContent && self.shellLines.dropLast().contains(where: { !$0.isEmpty }) {
                                    self.shellLines.insert("", at: self.shellLines.count - 1)
                                }
                                i = ni
                            }
                        case "\n":
                            self.shellLines.append("")
                            i = ni
                        default:
                            if self.shellLines.isEmpty { self.shellLines.append("") }
                            self.shellLines[self.shellLines.count - 1].append(c)
                            i = ni
                        }
                    }
                    if self.shellLines.count > 2000 {
                        self.shellLines = Array(self.shellLines.suffix(2000))
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
        shellProcess?.terminate()
        shellProcess     = nil
        shellInputHandle = nil
        isShellConnected = false
    }
}
