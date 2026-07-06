import AppKit

// Boxes the readabilityHandler's accumulating byte buffer in a reference type so it can
// be captured as a `let` — a captured `var` mutated inside an escaping, non-actor-isolated
// closure is exactly what Swift 6 flags as unsafe. Access is manually verified serial
// (FileHandle never invokes readabilityHandler concurrently for a given handle), matching
// the same @unchecked Sendable reasoning already applied to AppController itself.
private final class LineBuffer: @unchecked Sendable {
    nonisolated(unsafe) var data = Data()
}

extension AppController {

    func startLogStream() {
        guard !isStreaming else { return }
        logLines = []
        beginLogStreamTask()
    }

    // Split out from startLogStream() so auto-reconnect can re-enter here directly —
    // reconnecting after a transient drop (USB blip, vphone restart) shouldn't wipe the
    // history you were just looking at; only a fresh, user-initiated Stream click does.
    private func beginLogStreamTask(isReconnect: Bool = false) {
        isStreaming = true
        isStreamConnecting = true  // cleared once the UDID resolves (or fails) below
        logStreamAutoReconnect = true  // cleared by stopLogStream() for deliberate stops

        logStreamTask = Task { [weak self] in
            guard let self else { return }

            let (udid, diag) = await self.resolveVphoneUDID()
            guard let udid else {
                await MainActor.run {  // #10
                    self.logLines = diag
                    self.isStreaming = false
                    self.isStreamConnecting = false
                }
                return
            }

            await MainActor.run {  // #10
                self.isStreamConnecting = false
                // Since history now survives reconnects, a flapping connection would
                // otherwise show the same ">> streaming from" banner repeating for no
                // apparent reason — tag it explicitly so a flaky session is obvious.
                let message = isReconnect
                    ? ">> reconnected to vphone \(udid)"
                    : ">> streaming from vphone \(udid)"
                self.logLines.append(LogEntry(time: "", level: "", source: "",
                                              message: message, subsystem: nil))
            }

            await self.runLiveSyslog(udid: udid)

            await MainActor.run { [weak self] in self?.isStreaming = false }  // #10

            // The device dropping mid-stream (USB blip, vphone restart) otherwise leaves
            // the tab silently dead with no indication anything went wrong — auto-reconnect
            // mirrors the same pattern already used for the shell connection.
            guard self.logStreamAutoReconnect, !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, self.logStreamAutoReconnect else { return }
            await MainActor.run { [weak self] in self?.beginLogStreamTask(isReconnect: true) }
        }
    }

    func stopLogStream() {
        logStreamAutoReconnect = false  // prevent reconnect on deliberate stop
        logStreamTask?.cancel()
        logStreamTask = nil
        logStreamProcess?.terminate()
        logStreamProcess = nil
        isStreaming = false
        isStreamConnecting = false
    }

    // MARK: - Private helpers

    // `pymobiledevice3 syslog collect` + `log show --archive` (the previous approach here)
    // silently returns zero events on some pymobiledevice3/iOS combinations — the collected
    // archive comes back empty even though the device is actively logging, which made the
    // whole Logs tab look permanently broken. `syslog live --format json` streams events
    // directly off the device in real time with no intermediate archive, so it doesn't hit
    // that gap. Filtering by subsystem has to happen here in-process: the CLI's --match/
    // --regex filters are documented as ignored in JSON mode.
    private func runLiveSyslog(udid: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments     = ["pymobiledevice3", "syslog", "live",
                               "--udid", udid, "--format", "json"]
            p.environment   = enrichedEnvironment

            let pipe = Pipe()
            p.standardOutput = pipe

            // FileHandle invokes readabilityHandler serially for a given handle — never
            // concurrently — so a boxed buffer with manually-verified single-threaded
            // access is safe here; a captured local `var` is what Swift 6 actually flags.
            let buffer = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let data = handle.availableData
                guard !data.isEmpty else { return }
                buffer.data.append(data)

                while let newline = buffer.data.firstIndex(of: 0x0A) {
                    let lineData = buffer.data.subdata(in: buffer.data.startIndex..<newline)
                    buffer.data.removeSubrange(buffer.data.startIndex...newline)
                    guard !lineData.isEmpty,
                          let line = String(data: lineData, encoding: .utf8),
                          let entry = Self.parseLiveSyslogLine(line)
                    else { continue }

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.logLines.append(entry)
                            let limit = self.logBufferSize
                            if self.logLines.count > limit {
                                self.logLines.removeFirst(self.logLines.count - limit)  // #3
                            }
                        }
                    }
                }
            }

            p.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume()
            }

            do {
                try p.run()
                DispatchQueue.main.async { [weak self] in self?.logStreamProcess = p }
            } catch {
                continuation.resume()
            }
        }
    }

    // Matches the `syslog live --format json` timestamp format "2026-07-02T21:15:45.624234"
    // and captures the HH:mm:ss.SSS portion.
    private nonisolated static let liveTsRegex = /T(\d{2}:\d{2}:\d{2}\.\d{3})/

    // Pure parse-and-filter with no actor-isolated state — called directly from the
    // readabilityHandler's background thread, not hopped to the main actor, since the
    // vast majority of lines get discarded here and shouldn't cost a main-thread round trip.
    private nonisolated static func parseLiveSyslogLine(_ line: String) -> LogEntry? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let label     = json["label"] as? [String: Any]
        let subsystem = label?["subsystem"] as? String ?? ""
        guard subsystem == "app.unbound" || subsystem == "com.facebook.react.log" else { return nil }

        guard var msg = json["message"] as? String, !msg.isEmpty else { return nil }
        let ts       = json["timestamp"] as? String ?? ""
        let category = label?["category"] as? String ?? ""
        let level    = json["level"]      as? String ?? ""

        let time: String
        if let m = ts.firstMatch(of: Self.liveTsRegex) {
            time = String(m.1)
        } else {
            time = String(ts.prefix(12))
        }

        let lvl: String
        switch level {
        case "ERROR", "FAULT": lvl = "ERR"
        case "DEBUG":          lvl = "DBG"
        case "INFO":           lvl = "INF"
        default:               lvl = ""
        }

        let isReact = subsystem.contains("facebook.react")
        if msg.hasPrefix("[Unbound] ") { msg = String(msg.dropFirst(10)) }
        let src = category.isEmpty ? (isReact ? "JS" : "native") : "\(isReact ? "JS" : "native")/\(category)"

        return LogEntry(time: time, level: lvl, source: src, message: msg,
                        subsystem: isReact ? .reactNative : .unbound)
    }

    func resolveVphoneUDID() async -> (String?, [LogEntry]) {
        func hdr(_ m: String) -> LogEntry { LogEntry(time: "", level: "",    source: "",       message: m, subsystem: nil) }
        func err(_ m: String) -> LogEntry { LogEntry(time: "", level: "ERR", source: "vbound", message: m, subsystem: nil) }

        let listRaw = await runCapture(args: ["pymobiledevice3", "usbmux", "list"], timeout: 10)

        guard !listRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data    = listRaw.data(using: .utf8),
              let devices = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            let which = await runCapture(args: ["which", "pymobiledevice3"], timeout: 5)
            if which.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (nil, [err("pymobiledevice3 not found — pipx install pymobiledevice3")])
            }
            return (nil, [err("no devices found — is vphone running?")])
        }

        if devices.isEmpty {
            return (nil, [err("no devices connected — is vphone running?")])
        }

        var diag: [LogEntry] = [hdr(">> probing \(devices.count) device(s):")]
        for device in devices {
            let identifier  = (device["Identifier"]  as? String) ?? (device["UniqueDeviceID"] as? String) ?? ""
            let productType = (device["ProductType"] as? String) ?? ""
            guard !identifier.isEmpty else { continue }
            diag.append(hdr("   \(identifier)  →  \(productType.isEmpty ? "(no response)" : productType)"))
            if productType == "iPhone99,11" {
                await MainActor.run { self.vphoneUDID = identifier }  // #10
                return (identifier, [])
            }
        }
        diag.append(err("no iPhone99,11 found among connected devices"))
        return (nil, diag)
    }
}
