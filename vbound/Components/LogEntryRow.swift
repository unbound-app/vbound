import SwiftUI
import AppKit

struct LogEntryRow: View {
    let entry: LogEntry
    let isNew: Bool

    // All detection and splitting is precomputed in init so body stays cheap.
    private let nsObj:   NSObjectData?
    private let jsonStr: String?
    private let split:   (first: String, second: String)

    @State private var showPopover   = false
    @State private var showTimestamp = false

    init(entry: LogEntry, isNew: Bool) {
        self.entry  = entry
        self.isNew  = isNew

        if entry.isHeader {
            nsObj   = nil
            jsonStr = nil
            split   = ("", "")
        } else {
            let ns  = Self.detectNSObject(entry.message)
            nsObj   = ns
            let js  = ns == nil ? Self.detectJSON(entry.message) : nil
            jsonStr = js
            split   = (ns == nil && js == nil) ? Self.computeSplit(entry.message) : ("", "")
        }
    }

    // Badge is only relevant when there is non-empty structured content to display.
    private var hasBadge: Bool {
        if let ns = nsObj { return !ns.isEmpty }
        return jsonStr != nil
    }

    var body: some View {
        Group {
            if entry.isHeader {
                Text(entry.message)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    // Timestamp: shows HH:MM:SS, click for a small popup with full precision
                    Button { showTimestamp.toggle() } label: {
                        Text(String(entry.time.prefix(8)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 58, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showTimestamp, arrowEdge: .bottom) {
                        Text(entry.time)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(Color(.textBackgroundColor))
                    }

                    // Level pill — transparent placeholder when empty keeps column alignment
                    Text(entry.level.isEmpty ? "   " : entry.level)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(entry.level.isEmpty ? .clear : levelColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(entry.level.isEmpty ? Color.clear : levelColor.opacity(0.12))
                        )

                    // Source — 10pt keeps it compact; 106pt holds up to 17 chars at 6pt/char
                    Text(entry.source)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(width: 106, alignment: .leading)

                    // Structured-data badge — comes BEFORE the message text, left-click to open
                    if hasBadge {
                        Button { showPopover.toggle() } label: {
                            Text("{}")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.purple.opacity(0.12))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 3)
                                                .strokeBorder(Color.purple.opacity(0.35), lineWidth: 0.5)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                            popoverContent
                        }
                    }

                    // Message text (content varies by detection result)
                    messageText
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isNew && !entry.isHeader) ? Color.accentColor.opacity(0.13) : Color.clear)
        .animation(.easeOut(duration: 0.7), value: isNew)
    }

    // MARK: - Popover content

    @ViewBuilder
    private var popoverContent: some View {
        if let ns = nsObj, !ns.isEmpty {
            CodePopoverView(content: ns.body)
        } else if let json = jsonStr {
            JSONPopoverView(jsonString: json)
        }
    }

    // MARK: - Message text

    @ViewBuilder
    private var messageText: some View {
        if let ns = nsObj {
            // NS-style object: the prefix is the readable part
            Text(ns.prefix)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        } else if jsonStr != nil {
            // JSON: abbreviated text, full view via badge
            Text(truncated(entry.message, to: 80))
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        } else if split.second.isEmpty {
            // Short message — single line, fills available width
            Text(split.first.isEmpty ? entry.message : split.first)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Longer message — line 1 wraps to column, line 2 extends right without wrapping
            VStack(alignment: .leading, spacing: 0) {
                Text(split.first)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(split.second)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    // MARK: - Helpers

    private var levelColor: Color {
        switch entry.level {
        case "ERR": return .red
        case "DBG": return .secondary
        default:    return .blue
        }
    }

    private func truncated(_ s: String, to limit: Int) -> String {
        let clean = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
    }

    // MARK: - NS-style object detection

    struct NSObjectData {
        let prefix: String
        let body:   String
        let isEmpty: Bool
    }

    private static func detectNSObject(_ message: String) -> NSObjectData? {
        // ── Curly-brace style: "NSError Domain (code) {\n  key = val;\n}" ──
        if message.contains("\n"),
           let openIdx  = message.firstIndex(of: "{"),
           let closeIdx = message.lastIndex(of: "}"),
           closeIdx > openIdx {

            let prefix = String(message[..<openIdx]).trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty {
                let inner = String(message[message.index(after: openIdx)..<closeIdx])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let body  = String(message[openIdx...closeIdx])
                return NSObjectData(prefix: prefix, body: body, isEmpty: inner.isEmpty)
            }
        }

        // ── Angle-bracket style: "<ClassName: 0x…; key = val; …>" ──
        // Search from the front so nested objects are included in the captured body.
        if let openRange  = message.range(of: "<"),
           let closeIndex = message.lastIndex(of: ">"),
           closeIndex > openRange.lowerBound,
           message[openRange.lowerBound...].contains(": 0x") {

            let prefix = String(message[..<openRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            // body = "<...>" inclusive, using safe index arithmetic
            let body   = String(message[openRange.lowerBound...closeIndex])
            let inner: String = openRange.upperBound < closeIndex
                ? String(message[openRange.upperBound..<closeIndex]).trimmingCharacters(in: .whitespaces)
                : ""

            // Require at least one "; " to confirm this is an ObjC object description
            guard body.contains("; ") else { return nil }

            return NSObjectData(
                prefix: prefix.isEmpty ? String(body.prefix(40)) + "…" : prefix,
                body:   formatObjCBody(body),
                isEmpty: inner.isEmpty
            )
        }

        return nil
    }

    // Formats "<ClassName: 0x…; prop = val; …>" into one property per line.
    // Uses a depth counter so values like "frame = (0 0; 430 932)" are not split.
    private static func formatObjCBody(_ body: String) -> String {
        guard body.hasPrefix("<"), body.hasSuffix(">"), body.count > 2 else { return body }
        let inner = String(body.dropFirst().dropLast())

        var parts: [String] = []
        var current = ""
        var depth = 0
        var idx = inner.startIndex

        while idx < inner.endIndex {
            let ch = inner[idx]
            if ch == "(" || ch == "<" { depth += 1 }
            else if ch == ")" || ch == ">" { if depth > 0 { depth -= 1 } }

            if ch == ";" && depth == 0 {
                let part = current.trimmingCharacters(in: .whitespaces)
                if !part.isEmpty { parts.append(part) }
                current = ""
                idx = inner.index(after: idx)
                // skip whitespace after the semicolon
                while idx < inner.endIndex && inner[idx] == " " { idx = inner.index(after: idx) }
                continue
            }
            current.append(ch)
            idx = inner.index(after: idx)
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { parts.append(last) }

        guard parts.count > 1 else { return body }
        // First part: "ClassName: 0xADDR", rest: indented properties
        return parts[0] + "\n" + parts.dropFirst().map { "    " + $0 }.joined(separator: "\n")
    }

    // MARK: - JSON detection

    private static func detectJSON(_ message: String) -> String? {
        let msg = message.trimmingCharacters(in: .whitespaces)
        if msg.hasPrefix("{") || msg.hasPrefix("[") {
            if let s = prettyJSON(msg) { return s }
        }
        if let i = msg.firstIndex(of: "{"), let s = prettyJSON(String(msg[i...])) { return s }
        return nil
    }

    private static func prettyJSON(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data),
              let out  = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let str  = String(data: out, encoding: .utf8)
        else { return nil }
        return str
    }

    // MARK: - Message line split
    // Measures text at 13pt to find the natural word-wrap point for the message column.
    // Line 1 gets as many whole words as fit; line 2 receives the remainder (extends right).

    // Column width = content width (584pt) minus fixed columns and gaps:
    // 58 (time) + 6 + ~26 (pill) + 6 + 106 (src) + 6 = 208pt  →  584 - 208 = 376pt
    // Using 370 as a conservative constant to avoid occasional single-char overflow.
    private static let msgColWidth: CGFloat = 370

    private static func computeSplit(_ message: String) -> (first: String, second: String) {
        let msg  = message.replacingOccurrences(of: "\n", with: " ")
                          .trimmingCharacters(in: .whitespaces)
        let font = NSFont.systemFont(ofSize: 13)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let colW = msgColWidth

        guard (msg as NSString).size(withAttributes: attrs).width > colW else {
            return (msg, "")
        }

        let words = msg.components(separatedBy: " ")
        var line1 = ""
        var n     = 0
        for word in words {
            let candidate = line1.isEmpty ? word : line1 + " " + word
            if (candidate as NSString).size(withAttributes: attrs).width <= colW {
                line1 = candidate; n += 1
            } else { break }
        }

        if line1.isEmpty {
            // First word alone is wider than the column — show it on line 1 anyway
            return (words.first ?? msg, words.dropFirst().joined(separator: " "))
        }
        return (line1, words.dropFirst(n).joined(separator: " "))
    }
}

// MARK: - NS-object popover

private struct CodePopoverView: View {
    let content: String

    var body: some View {
        ScrollView(.vertical) {
            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: fittingWidth(content, max: 520),
               height: fittingHeight(content, lineH: 17, max: 320))
        .background(Color(.textBackgroundColor))
    }
}

// MARK: - JSON popover

private struct JSONPopoverView: View {
    let jsonString: String

    var body: some View {
        ScrollView(.vertical) {
            Text(JSONHighlighter.highlight(jsonString))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: fittingWidth(jsonString, max: 520),
               height: fittingHeight(jsonString, lineH: 17, max: 400))
        .background(Color(.textBackgroundColor))
    }
}

// Width that fits the longest line without wrapping, plus padding. Capped at `max`.
private func fittingWidth(_ text: String, max maxW: CGFloat) -> CGFloat {
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let widest = text.components(separatedBy: "\n")
        .map { ($0 as NSString).size(withAttributes: attrs).width }
        .max() ?? 120
    return Swift.min(widest + 32, maxW)   // 32 = 10pt padding × 2 + 12pt margin
}

// Height that fits the line count. Capped at `max`.
private func fittingHeight(_ text: String, lineH: CGFloat, max maxH: CGFloat) -> CGFloat {
    let lines = CGFloat(text.components(separatedBy: "\n").count)
    return Swift.min(lines * lineH + 20, maxH)
}

// MARK: - JSON syntax highlighter

enum JSONHighlighter {
    static func highlight(_ json: String) -> AttributedString {
        let ns   = NSMutableAttributedString(string: json)
        let full = NSRange(json.startIndex..., in: json)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        ns.addAttribute(.font,            value: font,               range: full)
        ns.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        apply(NSColor.systemPurple,        #"-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#, ns, json)
        apply(NSColor.systemOrange,        #"\b(?:true|false|null)\b"#,            ns, json)
        apply(NSColor.systemGreen,         #""(?:[^"\\]|\\.)*""#,                  ns, json)
        apply(NSColor.systemCyan,          #""(?:[^"\\]|\\.)*"(?=\s*:)"#,          ns, json)
        apply(NSColor.secondaryLabelColor, #"[{}\[\],:]"#,                         ns, json)
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(json)
    }

    static func highlightNS(_ json: String) -> NSAttributedString {
        let ns   = NSMutableAttributedString(string: json)
        let full = NSRange(json.startIndex..., in: json)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        ns.addAttribute(.font,            value: font,               range: full)
        ns.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        apply(NSColor.systemPurple,        #"-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#, ns, json)
        apply(NSColor.systemOrange,        #"\b(?:true|false|null)\b"#,            ns, json)
        apply(NSColor.systemGreen,         #""(?:[^"\\]|\\.)*""#,                  ns, json)
        apply(NSColor.systemCyan,          #""(?:[^"\\]|\\.)*"(?=\s*:)"#,          ns, json)
        apply(NSColor.secondaryLabelColor, #"[{}\[\],:]"#,                         ns, json)
        return ns
    }

    private static func apply(_ color: NSColor, _ pattern: String,
                               _ ns: NSMutableAttributedString, _ json: String) {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
        let full = NSRange(json.startIndex..., in: json)
        re.enumerateMatches(in: json, range: full) { m, _, _ in
            guard let r = m?.range else { return }
            ns.addAttribute(.foregroundColor, value: color, range: r)
        }
    }
}
