import AppKit

extension AppController {

    func startLogStream() {
        guard !isStreaming else { return }
        isStreaming = true
        logLines = []

        logStreamTask = Task { [weak self] in
            guard let self else { return }

            let (udid, diag) = await self.resolveVphoneUDID()
            guard let udid else {
                DispatchQueue.main.async { [diag] in
                    self.logLines = diag
                    self.isStreaming = false
                }
                return
            }

            DispatchQueue.main.async {
                self.logLines.append(LogEntry(time: "", level: "", source: "",
                                              message: ">> streaming from vphone \(udid)",
                                              subsystem: nil))
            }

            var lastMach: Double = 0

            while !Task.isCancelled {
                let startTime = Int(Date().timeIntervalSince1970) - 5
                let events = await self.collectLogEvents(udid: udid, startTime: startTime)

                let fresh = events
                    .filter  { ($0["machTimestamp"] as? Double ?? 0) > lastMach }
                    .sorted  { ($0["machTimestamp"] as? Double ?? 0) < ($1["machTimestamp"] as? Double ?? 0) }

                if let newest = fresh.last?["machTimestamp"] as? Double { lastMach = newest }

                if !fresh.isEmpty {
                    let entries = fresh.compactMap { self.makeLogEntry($0) }
                    if !entries.isEmpty {
                        DispatchQueue.main.async {
                            self.logLines.append(contentsOf: entries)
                            if self.logLines.count > 2000 {
                                self.logLines = Array(self.logLines.suffix(2000))
                            }
                        }
                    }
                }

                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }

            DispatchQueue.main.async { [weak self] in self?.isStreaming = false }
        }
    }

    func stopLogStream() {
        logStreamTask?.cancel()
        logStreamTask = nil
        isStreaming = false
    }

    // MARK: - Private helpers

    private func collectLogEvents(udid: String, startTime: Int) async -> [[String: Any]] {
        // .logarchive suffix silences pymobiledevice3 warning; runCapture discards its stderr
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbound-\(UUID().uuidString).logarchive")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        _ = await runCapture(args: [
            "pymobiledevice3", "syslog", "collect",
            "--udid", udid,
            "--start-time", "\(startTime)",
            tmpURL.path
        ])

        let pred = #"subsystem == "app.unbound" OR subsystem == "com.facebook.react.log""#
        let raw  = await runCapture(args: [
            "/usr/bin/log", "show",
            "--archive", tmpURL.path,
            "--predicate", pred,
            "--info", "--debug",
            "--style", "ndjson"
        ])

        return raw.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["eventMessage"] is String
            else { return nil }
            return json
        }
    }

    private func makeLogEntry(_ e: [String: Any]) -> LogEntry? {
        guard var msg = e["eventMessage"] as? String, !msg.isEmpty else { return nil }
        let ts        = e["timestamp"]   as? String ?? ""
        let subsystem = e["subsystem"]   as? String ?? ""
        let category  = e["category"]    as? String ?? ""
        let level     = e["messageType"] as? String ?? ""

        let parts = ts.components(separatedBy: " ")
        let time  = parts.count >= 2 ? String(parts[1].prefix(12)) : String(ts.prefix(12))

        let lvl: String
        switch level {
        case "Error", "Fault": lvl = "ERR"
        case "Debug":          lvl = "DBG"
        case "Info":           lvl = "INF"
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

        let listRaw = await runCapture(args: ["pymobiledevice3", "usbmux", "list"])

        guard !listRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data    = listRaw.data(using: .utf8),
              let devices = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            let which = await runCapture(args: ["which", "pymobiledevice3"])
            if which.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (nil, [err("pymobiledevice3 not found — pip install pymobiledevice3")])
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
                DispatchQueue.main.async { self.vphoneUDID = identifier }
                return (identifier, [])
            }
        }
        diag.append(err("no iPhone99,11 found among connected devices"))
        return (nil, diag)
    }
}
