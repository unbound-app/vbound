import AppKit
import SwiftUI

// MARK: - Attachment image helpers

private func pillImage(label: String, fg: NSColor, bg: NSColor) -> NSImage {
    let font  = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
    let tsz   = (label as NSString).size(withAttributes: attrs)
    let w = tsz.width + 8
    let h: CGFloat = 14
    return NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
        NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 0.5), xRadius: 3, yRadius: 3).then {
            bg.setFill(); $0.fill()
        }
        (label as NSString).draw(
            at: NSPoint(x: (w - tsz.width) / 2, y: (h - tsz.height) / 2),
            withAttributes: attrs)
        return true
    }
}

private func badgeImage() -> NSImage {
    let font  = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
    let label = "{}"
    let fore  = NSColor.systemPurple
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fore]
    let tsz   = (label as NSString).size(withAttributes: attrs)
    let w = tsz.width + 8
    let h: CGFloat = 14
    return NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        NSColor.systemPurple.withAlphaComponent(0.12).setFill(); path.fill()
        path.lineWidth = 0.5
        NSColor.systemPurple.withAlphaComponent(0.35).setStroke(); path.stroke()
        (label as NSString).draw(
            at: NSPoint(x: (w - tsz.width) / 2, y: (h - tsz.height) / 2),
            withAttributes: attrs)
        return true
    }
}

private func makeAttachment(image: NSImage) -> NSAttributedString {
    let att    = NSTextAttachment()
    att.image  = image
    att.bounds = NSRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
    return NSAttributedString(attachment: att)
}

private extension NSBezierPath {
    @discardableResult func then(_ block: (NSBezierPath) -> Void) -> NSBezierPath {
        block(self); return self
    }
}

// MARK: - NSObject detection (mirrors LogEntryRow logic)

private struct NSObjectData {
    let prefix:  String
    let body:    String
    let isEmpty: Bool
}

// Matches `<CapitalCaseName: 0xADDR` — requires a capital-letter class name so it
// doesn't false-positive on URLs, hex color values, or error codes (#14).
private let nsObjPointerPattern = /<[A-Z]\w*(?:\.\w+)*: 0x[0-9a-fA-F]+/

private func detectNSObject(_ message: String) -> NSObjectData? {
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
    // Use a precise Regex instead of the plain `: 0x` substring check (#14)
    if let openRange  = message.range(of: "<"),
       let closeIndex = message.lastIndex(of: ">"),
       closeIndex > openRange.lowerBound,
       message[openRange.lowerBound...].contains(nsObjPointerPattern) {
        let prefix = String(message[..<openRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let body   = String(message[openRange.lowerBound...closeIndex])
        let inner: String = openRange.upperBound < closeIndex
            ? String(message[openRange.upperBound..<closeIndex]).trimmingCharacters(in: .whitespaces)
            : ""
        guard body.contains("; ") else { return nil }
        return NSObjectData(
            prefix:  prefix.isEmpty ? String(body.prefix(40)) + "…" : prefix,
            body:    formatObjCBody(body),
            isEmpty: inner.isEmpty)
    }
    return nil
}

private func formatObjCBody(_ body: String) -> String {
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
            while idx < inner.endIndex && inner[idx] == " " { idx = inner.index(after: idx) }
            continue
        }
        current.append(ch)
        idx = inner.index(after: idx)
    }
    let last = current.trimmingCharacters(in: .whitespaces)
    if !last.isEmpty { parts.append(last) }
    guard parts.count > 1 else { return body }
    return parts[0] + "\n" + parts.dropFirst().map { "    " + $0 }.joined(separator: "\n")
}

private func detectJSON(_ message: String) -> String? {
    let msg = message.trimmingCharacters(in: .whitespaces)
    func pretty(_ raw: String) -> String? {
        guard let d = raw.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d),
              let p = try? JSONSerialization.data(withJSONObject: o,
                                                  options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: p, encoding: .utf8) else { return nil }
        return s
    }
    if msg.hasPrefix("{") || msg.hasPrefix("["), let s = pretty(msg) { return s }
    if let i = msg.firstIndex(of: "{"), let s = pretty(String(msg[i...])) { return s }
    return nil
}

// MARK: - Link tag constants
// Used as the .link attribute value so the delegate can distinguish click targets.
private let kLinkTagTimestamp = "ts"
private let kLinkTagBadge     = "badge"

// MARK: - NSTextView subclass

final class LogNSTextView: NSTextView {
    var entryRanges:    [(range: NSRange, entry: LogEntry)]               = []
    var timestampRanges:[(range: NSRange, fullTime: String)]              = []
    var popoverRanges:  [(range: NSRange, content: String, isCode: Bool)] = []

    var onCopyLine:        ((LogEntry) -> Void)?
    var onFilterToSource:  ((LogEntry) -> Void)?

    // MARK: Row context menu (copy line / filter to source)

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let lm = layoutManager, let tc = textContainer else { return super.menu(for: event) }
        let pt     = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let tcPt   = NSPoint(x: pt.x - origin.x, y: pt.y - origin.y)
        var frac: CGFloat = 0
        let gi = lm.glyphIndex(for: tcPt, in: tc, fractionOfDistanceThroughGlyph: &frac)
        guard gi < lm.numberOfGlyphs else { return super.menu(for: event) }
        let ci = lm.characterIndexForGlyph(at: gi)
        guard let hit = entryRanges.first(where: { NSLocationInRange(ci, $0.range) }),
              !hit.entry.isHeader else { return super.menu(for: event) }

        pendingMenuEntry = hit.entry
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "Copy Line", action: #selector(copyLineAction), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        let filterItem = NSMenuItem(title: "Filter to “\(hit.entry.source)”",
                                     action: #selector(filterToSourceAction), keyEquivalent: "")
        filterItem.target = self
        menu.addItem(filterItem)
        return menu
    }

    private var pendingMenuEntry: LogEntry?

    @objc private func copyLineAction() {
        guard let entry = pendingMenuEntry else { return }
        onCopyLine?(entry)
    }

    @objc private func filterToSourceAction() {
        guard let entry = pendingMenuEntry else { return }
        onFilterToSource?(entry)
    }

    // Keep a single tracking area (recreated whenever AppKit requests it) so
    // we receive mouseMoved events and can set the cursor dynamically.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where (area.options.rawValue &
                NSTrackingArea.Options.mouseMoved.rawValue) != 0 {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let lm = layoutManager, let tc = textContainer else { return }
        let pt   = convert(event.locationInWindow, from: nil)
        let orig = textContainerOrigin
        let tcPt = NSPoint(x: pt.x - orig.x, y: pt.y - orig.y)
        var frac: CGFloat = 0
        let gi = lm.glyphIndex(for: tcPt, in: tc, fractionOfDistanceThroughGlyph: &frac)
        if gi < lm.numberOfGlyphs {
            let ci = lm.characterIndexForGlyph(at: gi)
            if timestampRanges.contains(where: { NSLocationInRange(ci, $0.range) }) ||
               popoverRanges.contains(where:   { NSLocationInRange(ci, $0.range) }) {
                NSCursor.pointingHand.set()
                return
            }
        }
        NSCursor.iBeam.set()
    }
}

// MARK: - SwiftUI wrapper

struct LogTextView: NSViewRepresentable {
    let entries:           [LogEntry]
    let highlightStartIdx: Int
    let scrollVersion:     Int
    var searchQuery:       String = ""
    var onFilterToSource:  ((LogEntry) -> Void)? = nil

    // Tab stops match LogEntryRow SwiftUI fixed-frame layout (textContainerInset.width = 8):
    //   timestamp 58pt frame + 6pt gap  → tab 1 at  64pt (abs  72pt) ✓
    //   level pill ~26pt      + 6pt gap → tab 2 at  96pt (abs 104pt) ✓
    //   source 106pt frame    + 6pt gap → tab 3 at 208pt (abs 216pt) ✓
    private static let paraStyle: NSParagraphStyle = {
        let s = NSMutableParagraphStyle()
        s.tabStops = [
            NSTextTab(textAlignment: .left, location: 64),
            NSTextTab(textAlignment: .left, location: 96),
            NSTextTab(textAlignment: .left, location: 208),
        ]
        s.paragraphSpacingBefore = 3
        s.paragraphSpacing       = 3
        return s
    }()

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller   = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers    = true
        sv.borderType            = .noBorder

        let ts = NSTextStorage()
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width:  CGFloat.greatestFiniteMagnitude,
                                              height: CGFloat.greatestFiniteMagnitude))
        tc.widthTracksTextView = false
        lm.addTextContainer(tc)
        ts.addLayoutManager(lm)

        let tv = LogNSTextView(frame: .zero, textContainer: tc)
        tv.isEditable              = false
        tv.isSelectable            = true
        tv.drawsBackground         = false
        tv.textContainerInset      = NSSize(width: 8, height: 6)
        tv.isVerticallyResizable   = true
        tv.isHorizontallyResizable = true
        tv.maxSize                 = NSSize(width:  CGFloat.greatestFiniteMagnitude,
                                            height: CGFloat.greatestFiniteMagnitude)

        // Suppress NSTextView's default link colouring/underline — our explicit
        // colour/font attributes already style the text correctly.  The pointing-hand
        // cursor on hover is preserved automatically for any .link-attributed range.
        tv.linkTextAttributes = [:]

        tv.delegate = context.coordinator
        sv.documentView = tv
        context.coordinator.textView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv      = sv.documentView as? LogNSTextView,
              let storage = tv.textStorage else { return }
        let c = context.coordinator

        tv.onCopyLine = { entry in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.asString(), forType: .string)
        }
        tv.onFilterToSource = onFilterToSource

        let result = buildContent()
        storage.setAttributedString(result.str)
        tv.entryRanges     = result.entryRanges
        tv.timestampRanges = result.timestampRanges
        tv.popoverRanges   = result.popoverRanges

        let shouldScroll = entries.count > c.lastCount || scrollVersion != c.lastVersion
        c.lastCount   = entries.count
        c.lastVersion = scrollVersion
        if shouldScroll { DispatchQueue.main.async { tv.scrollToEndOfDocument(nil) } }
    }

    // Case-insensitive NSRange occurrences of `query` within `haystack`, in NSString terms.
    private func ranges(of query: String, in haystack: String) -> [NSRange] {
        let ns = haystack as NSString
        var results: [NSRange] = []
        var searchRange = NSRange(location: 0, length: ns.length)
        while searchRange.location < ns.length {
            let found = ns.range(of: query, options: .caseInsensitive, range: searchRange)
            guard found.location != NSNotFound else { break }
            results.append(found)
            searchRange = NSRange(location: found.location + found.length,
                                  length: ns.length - (found.location + found.length))
        }
        return results
    }

    // MARK: - Content builder

    private struct BuildResult {
        let str:            NSAttributedString
        var entryRanges:    [(range: NSRange, entry: LogEntry)]
        var timestampRanges:[(range: NSRange, fullTime: String)]
        var popoverRanges:  [(range: NSRange, content: String, isCode: Bool)]
    }

    private func buildContent() -> BuildResult {
        let monoR = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let monoS = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let body  = NSFont.systemFont(ofSize: 13)

        let out = NSMutableAttributedString()
        var entryRanges:    [(range: NSRange, entry: LogEntry)]               = []
        var timestampRanges:[(range: NSRange, fullTime: String)]              = []
        var popoverRanges:  [(range: NSRange, content: String, isCode: Bool)] = []

        func ns(_ str: String, font: NSFont, color: NSColor,
                bg: NSColor? = nil) -> NSAttributedString {
            var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let bg { a[.backgroundColor] = bg }
            return NSAttributedString(string: str, attributes: a)
        }

        for (i, entry) in entries.enumerated() {
            let rowStart = out.length
            let isNew    = highlightStartIdx >= 0 && i >= highlightStartIdx

            if entry.isHeader {
                out.append(ns(entry.message + "\n", font: monoS, color: .secondaryLabelColor))
            } else {
                // Timestamp — tagged with .link so the delegate fires on click and the
                // cursor changes to a pointing hand on hover automatically.
                let tsStart = out.length
                out.append(ns(String(entry.time.prefix(8)), font: monoR, color: .secondaryLabelColor))
                let tsRange = NSRange(location: tsStart, length: out.length - tsStart)
                out.addAttribute(.link, value: kLinkTagTimestamp, range: tsRange)
                timestampRanges.append((range: tsRange, fullTime: entry.time))
                out.append(ns("\t", font: monoR, color: .clear))

                // Level pill
                if entry.level.isEmpty {
                    out.append(ns("   ", font: monoS, color: .clear))
                } else {
                    let fg: NSColor = entry.level == "ERR" ? .systemRed
                                    : entry.level == "DBG" ? .secondaryLabelColor
                                                           : .systemBlue
                    out.append(makeAttachment(image: pillImage(
                        label: entry.level, fg: fg, bg: fg.withAlphaComponent(0.12))))
                }
                out.append(ns("\t", font: monoR, color: .clear))

                // Source (padded to 18 chars ≈ 106pt at 10pt mono)
                let src    = String(entry.source.prefix(17))
                let padded = src + String(repeating: " ", count: max(0, 18 - src.count))
                out.append(ns(padded, font: monoS, color: .tertiaryLabelColor))
                out.append(ns("\t", font: monoR, color: .clear))

                // Structured-data detection — NSObject first, then JSON (mirrors LogEntryRow)
                let nsObj          = detectNSObject(entry.message)
                let hasBadge:       Bool
                let displayMsg:     String
                let popoverContent: String
                let popoverIsCode:  Bool

                if let obj = nsObj, !obj.isEmpty {
                    hasBadge       = true
                    displayMsg     = obj.prefix
                    popoverContent = obj.body
                    popoverIsCode  = true
                } else if let json = detectJSON(entry.message) {
                    hasBadge       = true
                    let msg        = entry.message
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    displayMsg     = msg.count > 80 ? String(msg.prefix(80)) + "…" : msg
                    popoverContent = json
                    popoverIsCode  = false
                } else {
                    hasBadge       = false
                    displayMsg     = entry.message
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    popoverContent = ""
                    popoverIsCode  = false
                }

                if hasBadge {
                    let badgeStart = out.length
                    out.append(makeAttachment(image: badgeImage()))
                    out.append(ns(" ", font: body, color: .clear))
                    let badgeRange = NSRange(location: badgeStart, length: out.length - badgeStart)
                    // Tag with .link so the pointing-hand cursor and delegate fire on click.
                    out.addAttribute(.link, value: kLinkTagBadge, range: badgeRange)
                    popoverRanges.append((range: badgeRange, content: popoverContent,
                                          isCode: popoverIsCode))
                }

                let msgStart = out.length
                out.append(ns(displayMsg + "\n", font: body, color: .labelColor))
                if !searchQuery.isEmpty {
                    for range in ranges(of: searchQuery, in: displayMsg) {
                        out.addAttribute(.backgroundColor,
                                         value: NSColor.systemYellow.withAlphaComponent(0.4),
                                         range: NSRange(location: msgStart + range.location, length: range.length))
                    }
                }
            }

            let rowRange = NSRange(location: rowStart, length: out.length - rowStart)
            out.addAttribute(.paragraphStyle, value: Self.paraStyle, range: rowRange)
            if isNew && !entry.isHeader {
                out.addAttribute(.backgroundColor,
                                 value: NSColor.controlAccentColor.withAlphaComponent(0.13),
                                 range: rowRange)
            }
            entryRanges.append((range: rowRange, entry: entry))
        }

        return BuildResult(str: out, entryRanges: entryRanges,
                           timestampRanges: timestampRanges,
                           popoverRanges: popoverRanges)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: LogNSTextView?
        var lastCount   = 0
        var lastVersion = 0
        private var popover: NSPopover?

        // MARK: NSTextViewDelegate — link clicks

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let tv  = textView as? LogNSTextView,
                  let tag = link as? String else { return false }

            // Compute an anchor rect from the clicked glyph so the popover appears
            // right at the click location rather than at some off-screen coordinate.
            let anchor = glyphRect(at: charIndex, in: tv)

            switch tag {
            case kLinkTagTimestamp:
                guard let ts = tv.timestampRanges
                    .first(where: { NSLocationInRange(charIndex, $0.range) })
                else { return false }
                showTimestampPopover(time: ts.fullTime, in: tv, anchor: anchor)
                return true

            case kLinkTagBadge:
                guard let hit = tv.popoverRanges
                    .first(where: { NSLocationInRange(charIndex, $0.range) })
                else { return false }
                if hit.isCode { showCodePopover(code: hit.content, in: tv, anchor: anchor) }
                else          { showJSONPopover(json: hit.content, in: tv, anchor: anchor) }
                return true

            default:
                return false
            }
        }

        // Convert a character index to a small rect in the text view's coordinate system.
        private func glyphRect(at charIndex: Int, in tv: NSTextView) -> NSRect {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else {
                return NSRect(x: 10, y: 10, width: 4, height: 16)
            }
            let gr     = lm.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1),
                                        actualCharacterRange: nil)
            let rect   = lm.boundingRect(forGlyphRange: gr, in: tc)
            let origin = tv.textContainerOrigin
            // The rect is in text-container coordinates; shift to text-view coordinates.
            return rect.offsetBy(dx: origin.x, dy: origin.y)
        }

        // MARK: Popover presenters

        func showJSONPopover(json: String, in view: NSView, anchor: NSRect) {
            popover?.close()
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
            tv.isEditable = false; tv.isSelectable = true
            tv.backgroundColor    = .textBackgroundColor
            tv.textContainerInset = NSSize(width: 12, height: 10)
            tv.textStorage?.setAttributedString(JSONHighlighter.highlightNS(json))
            let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
            sv.documentView        = tv
            sv.hasVerticalScroller = true; sv.hasHorizontalScroller = true
            let vc = NSViewController(); vc.view = sv
            let p  = NSPopover()
            p.contentViewController = vc
            p.contentSize = NSSize(width: 500, height: 320)
            p.behavior    = .transient
            p.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
            popover = p
        }

        func showCodePopover(code: String, in view: NSView, anchor: NSRect) {
            popover?.close()
            let font  = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.labelColor
            ]
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
            tv.isEditable = false; tv.isSelectable = true
            tv.backgroundColor    = .textBackgroundColor
            tv.textContainerInset = NSSize(width: 12, height: 10)
            tv.textStorage?.setAttributedString(NSAttributedString(string: code, attributes: attrs))
            let lineH: CGFloat = 17
            let lines  = CGFloat(code.components(separatedBy: "\n").count)
            let h      = min(lines * lineH + 20, 320)
            let widest = code.components(separatedBy: "\n")
                .map { ($0 as NSString).size(withAttributes: attrs).width }
                .max() ?? 120
            let w = min(widest + 32, 520)
            let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            sv.documentView        = tv
            sv.hasVerticalScroller = true; sv.hasHorizontalScroller = true
            let vc = NSViewController(); vc.view = sv
            let p  = NSPopover()
            p.contentViewController = vc
            p.contentSize = NSSize(width: w, height: h)
            p.behavior    = .transient
            p.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
            popover = p
        }

        func showTimestampPopover(time: String, in view: NSView, anchor: NSRect) {
            guard !time.isEmpty else { return }
            popover?.close()
            let label = NSTextField(labelWithString: time)
            label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            label.sizeToFit()
            let pad: CGFloat = 10
            let frame = NSRect(x: 0, y: 0,
                               width:  label.frame.width  + pad * 2,
                               height: label.frame.height + pad * 2)
            let container = NSView(frame: frame)
            label.frame   = label.frame.offsetBy(dx: pad, dy: pad)
            container.addSubview(label)
            let vc = NSViewController(); vc.view = container
            let p  = NSPopover()
            p.contentViewController = vc
            p.contentSize = frame.size
            p.behavior    = .transient
            p.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
            popover = p
        }
    }
}
