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
                let events = await self.pullLogEvents(udid: udid, ageSecs: 5)
                let fresh  = events
                    .filter  { ($0["machTimestamp"] as? Double ?? 0) > lastMach }
                    .sorted  { ($0["machTimestamp"] as? Double ?? 0) < ($1["machTimestamp"] as? Double ?? 0) }

                if let newest = fresh.last?["machTimestamp"] as? Double { lastMach = newest }

                let entries = fresh.compactMap { self.makeLogEntry($0) }
                if !entries.isEmpty {
                    DispatchQueue.main.async {
                        self.logLines.append(contentsOf: entries)
                        if self.logLines.count > 2000 {
                            self.logLines = Array(self.logLines.suffix(2000))
                        }
                    }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
            DispatchQueue.main.async { self.isStreaming = false }
        }
    }

    func stopLogStream() {
        logStreamTask?.cancel()
        logStreamTask = nil
        isStreaming = false
    }

    func resolveVphoneUDID() async -> (String?, [LogEntry]) {
        func hdr(_ m: String) -> LogEntry { LogEntry(time: "", level: "",    source: "",       message: m, subsystem: nil) }
        func err(_ m: String) -> LogEntry { LogEntry(time: "", level: "ERR", source: "vbound", message: m, subsystem: nil) }

        let raw   = await runCapture(args: ["idevice_id", "-l"])
        let udids = raw.components(separatedBy: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("[") else { return nil }
            return t.components(separatedBy: " ").first
        }

        if udids.isEmpty {
            let which = await runCapture(args: ["which", "idevice_id"])
            if which.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (nil, [err("idevice_id not found — brew install libimobiledevice")])
            }
            return (nil, [err("idevice_id found but no devices listed — is vphone trusted?")])
        }

        var diag: [LogEntry] = [hdr(">> probing \(udids.count) device(s):")]
        for udid in udids {
            let pt = await runCapture(args: ["ideviceinfo", "-u", udid, "-k", "ProductType"])
            let productType = pt.trimmingCharacters(in: .whitespacesAndNewlines)
            diag.append(hdr("   \(udid)  →  \(productType.isEmpty ? "(no response)" : productType)"))
            if productType == "iPhone99,11" { return (udid, []) }
        }
        diag.append(err("no iPhone99,11 found among connected devices"))
        return (nil, diag)
    }

    private func pullLogEvents(udid: String, ageSecs: Int) async -> [[String: Any]] {
        let base    = FileManager.default.temporaryDirectory
                        .appendingPathComponent("vbound-\(UUID().uuidString)").path
        let tar     = base + ".tar"
        let archive = base + ".logarchive"
        defer {
            try? FileManager.default.removeItem(atPath: tar)
            try? FileManager.default.removeItem(atPath: archive)
        }

        guard await run(args: ["idevicesyslog", "-u", udid, "archive", tar,
                               "--age-limit", "\(ageSecs)"]) else { return [] }
        try? FileManager.default.createDirectory(atPath: archive, withIntermediateDirectories: true)
        guard await run(args: ["tar", "-xf", tar, "-C", archive]) else { return [] }

        let predicate = #"subsystem == "app.unbound" OR subsystem == "com.facebook.react.log""#
        let ndjson = await runCapture(args: [
            "/usr/bin/log", "show",
            "--archive", archive,
            "--predicate", predicate,
            "--info", "--debug",
            "--style", "ndjson"
        ])

        return ndjson.components(separatedBy: "\n").compactMap { line in
            guard let data = line.trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return json
        }
    }

    func makeLogEntry(_ e: [String: Any]) -> LogEntry? {
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
        let src     = isReact ? "JS" : "native"
        let tag     = category.isEmpty ? src : "\(src)/\(category)"

        if msg.hasPrefix("[Unbound] ") { msg = String(msg.dropFirst(10)) }

        return LogEntry(time: time, level: lvl, source: tag, message: msg,
                        subsystem: isReact ? .reactNative : .unbound)
    }
}
