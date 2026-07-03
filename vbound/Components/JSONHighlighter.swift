import SwiftUI
import AppKit

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
