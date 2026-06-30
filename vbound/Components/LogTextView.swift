import AppKit
import SwiftUI

// MARK: - Layout manager that draws full-width row dividers

final class LogLayoutManager: NSLayoutManager {

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let container = textContainers.first,
              let storage   = textStorage else { return }

        let nsStr  = storage.string as NSString
        let cRange = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        var idx    = cRange.location
        let end    = NSMaxRange(cRange)

        NSColor.separatorColor.withAlphaComponent(0.18).setFill()

        while idx < end {
            let paraRange = nsStr.paragraphRange(for: NSRange(location: idx, length: 0))
            let glRange   = glyphRange(forCharacterRange: paraRange, actualCharacterRange: nil)
            let rect      = boundingRect(forGlyphRange: glRange, in: container)

            // Draw a 0.5pt line spanning the full view width at the bottom of this paragraph.
            // x=0 / width=9999 is clipped to the text view's bounds automatically.
            NSBezierPath.fill(NSRect(x: 0,
                                     y: origin.y + rect.maxY - 0.5,
                                     width: 9999,
                                     height: 0.5))
            idx = NSMaxRange(paraRange)
        }
    }
}

// MARK: - NSTextView subclass — left-click JSON popup + right-click context menu

final class LogNSTextView: NSTextView {
    var entryRanges: [(range: NSRange, entry: LogEntry)] = []
    var onShowJSON:  ((String, NSView) -> Void)?

    private var wasDragging = false

    // Track drags so a single click doesn't falsely trigger the JSON popup.
    override func mouseDragged(with event: NSEvent) {
        wasDragging = true
        super.mouseDragged(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        wasDragging = false
        super.mouseDown(with: event)
    }

    // Left single-click on a JSON entry → show popup.
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard event.clickCount == 1, !wasDragging else { return }
        let pt  = convert(event.locationInWindow, from: nil)
        let idx = characterIndex(for: pt)
        guard idx != NSNotFound,
              let hit  = entryRanges.first(where: { NSLocationInRange(idx, $0.range) }),
              !hit.entry.isHeader,
              let json = jsonPretty(hit.entry.message)
        else { return }
        onShowJSON?(json, self)
    }

    // Right-click context menu keeps "View as JSON…" for discoverability.
    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event) ?? NSMenu()
        let pt   = convert(event.locationInWindow, from: nil)
        let idx  = characterIndex(for: pt)
        guard idx != NSNotFound,
              let hit  = entryRanges.first(where: { NSLocationInRange(idx, $0.range) }),
              !hit.entry.isHeader,
              let json = jsonPretty(hit.entry.message)
        else { return base }

        let item = NSMenuItem(title: "View as JSON…",
                              action: #selector(handleJSON(_:)),
                              keyEquivalent: "")
        item.representedObject = json
        item.target = self
        base.insertItem(NSMenuItem.separator(), at: 0)
        base.insertItem(item, at: 0)
        return base
    }

    @objc private func handleJSON(_ sender: NSMenuItem) {
        guard let json = sender.representedObject as? String else { return }
        onShowJSON?(json, self)
    }

    private func jsonPretty(_ message: String) -> String? {
        let msg = message.trimmingCharacters(in: .whitespaces)
        if msg.hasPrefix("{") || msg.hasPrefix("["), let s = parse(msg) { return s }
        if let i = msg.firstIndex(of: "{"), let s = parse(String(msg[i...])) { return s }
        return nil
    }

    private func parse(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data),
              let out  = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let str  = String(data: out, encoding: .utf8)
        else { return nil }
        return str
    }
}

// MARK: - SwiftUI wrapper

struct LogTextView: NSViewRepresentable {
    let entries:          [LogEntry]
    let highlightStartIdx: Int
    let scrollVersion:    Int

    // Tab-stop positions in typographic points.
    // Chosen to align with the original SwiftUI column widths at 13pt.
    private static let colLevel:  CGFloat = 96   // after "HH:MM:SS.xxx  "
    private static let colSource: CGFloat = 130  // after "INF  "
    private static let colMsg:    CGFloat = 218  // after source column (max ~13 chars mono)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller   = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers    = true
        sv.borderType            = .noBorder

        // Build a custom text stack so we can inject LogLayoutManager.
        // Use an unlimited-width container (widthTracksTextView = false) so the text
        // view expands to fit content rather than wrapping at the viewport width.
        // This avoids a zero-width layout when the view is first created (frame: .zero).
        let ts = NSTextStorage()
        let lm = LogLayoutManager()
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

        sv.documentView = tv
        tv.onShowJSON   = { [weak coord = context.coordinator] json, view in
            coord?.showJSONPopover(json: json, relativeTo: view)
        }
        context.coordinator.textView = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv      = sv.documentView as? LogNSTextView,
              let storage = tv.textStorage else { return }
        let c = context.coordinator

        let (attrStr, ranges) = buildContent()
        storage.setAttributedString(attrStr)
        tv.entryRanges = ranges

        let shouldScroll = entries.count > c.lastCount || scrollVersion != c.lastVersion
        c.lastCount   = entries.count
        c.lastVersion = scrollVersion
        if shouldScroll {
            DispatchQueue.main.async { tv.scrollToEndOfDocument(nil) }
        }
    }

    // MARK: - Content builder

    private func buildContent() -> (NSAttributedString, [(range: NSRange, entry: LogEntry)]) {
        let monoR = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let monoB = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let prop  = NSFont.systemFont(ofSize: 13)

        // Paragraph style shared by all log rows:
        //   - Tab stops position each column
        //   - headIndent = colMsg so wrapped message lines align with the message column
        //   - byTruncatingTail clips any overflow on the last visible line
        let rowStyle = NSMutableParagraphStyle()
        rowStyle.tabStops = [
            NSTextTab(textAlignment: .left, location: Self.colLevel),
            NSTextTab(textAlignment: .left, location: Self.colSource),
            NSTextTab(textAlignment: .left, location: Self.colMsg),
        ]
        rowStyle.headIndent          = Self.colMsg
        rowStyle.firstLineHeadIndent = 0
        rowStyle.lineBreakMode       = .byTruncatingTail
        rowStyle.paragraphSpacing    = 1   // breathing room above the divider line

        let hdrStyle = NSMutableParagraphStyle()
        hdrStyle.lineBreakMode = .byTruncatingTail

        var buf  = ""
        struct Seg { var range: NSRange; var fg: NSColor; var font: NSFont; var bg: NSColor? }
        var segs:        [Seg]                               = []
        var hlRanges:    [NSRange]                           = []
        var entryRanges: [(range: NSRange, entry: LogEntry)] = []

        func push(_ s: String, fg: NSColor, font: NSFont, bg: NSColor? = nil) {
            let loc = buf.utf16.count
            buf += s
            segs.append(Seg(range: NSRange(location: loc, length: buf.utf16.count - loc),
                            fg: fg, font: font, bg: bg))
        }

        for (idx, entry) in entries.enumerated() {
            let rowStart = buf.utf16.count
            let isNew    = highlightStartIdx >= 0 && idx >= highlightStartIdx

            if entry.isHeader {
                push(entry.message + "\n", fg: .secondaryLabelColor, font: monoR)
            } else {
                // Timestamp → tab
                push(entry.time + "\t", fg: .secondaryLabelColor, font: monoR)

                // Level badge: background covers only the 3-letter text, not the trailing tab
                let lvl      = entry.level.isEmpty ? "   " : entry.level
                let lvlFg: NSColor = entry.level == "ERR" ? .systemRed
                                   : entry.level == "DBG" ? .secondaryLabelColor
                                                           : .systemBlue
                let lvlBg: NSColor? = entry.level.isEmpty ? nil : lvlFg.withAlphaComponent(0.14)
                push(lvl,  fg: lvlFg, font: entry.level.isEmpty ? monoR : monoB, bg: lvlBg)
                push("\t", fg: .secondaryLabelColor, font: monoR)

                // Source (truncated to keep it in its column) → tab
                let maxSrc = 13
                let src    = entry.source.count > maxSrc
                    ? String(entry.source.prefix(maxSrc - 1)) + "…"
                    : entry.source
                push(src + "\t", fg: .tertiaryLabelColor, font: monoR)

                // Message (JSON abbreviated; newlines collapsed; soft 2-line cap)
                push(displayMessage(entry.message) + "\n", fg: .labelColor, font: prop)
            }

            let rowRange = NSRange(location: rowStart, length: buf.utf16.count - rowStart)
            entryRanges.append((range: rowRange, entry: entry))
            if isNew { hlRanges.append(rowRange) }
        }

        let result = NSMutableAttributedString(string: buf)

        // Apply paragraph style to each full row range
        for (rowRange, entry) in entryRanges {
            result.addAttribute(.paragraphStyle,
                               value: entry.isHeader ? hdrStyle : rowStyle,
                               range: rowRange)
        }

        // Apply per-segment font / colour / badge background
        for seg in segs {
            result.addAttribute(.font,            value: seg.font, range: seg.range)
            result.addAttribute(.foregroundColor, value: seg.fg,   range: seg.range)
            if let bg = seg.bg {
                result.addAttribute(.backgroundColor, value: bg, range: seg.range)
            }
        }

        // New-entry highlight (applied last so it doesn't get overridden)
        for hl in hlRanges {
            result.addAttribute(.backgroundColor,
                               value: NSColor.controlAccentColor.withAlphaComponent(0.13),
                               range: hl)
        }

        return (result, entryRanges)
    }

    // Collapses embedded newlines; abbreviates JSON so it doesn't flood the row.
    // Non-JSON messages are shown in full — byTruncatingTail clips any tail that
    // overflows the 2nd wrapped line, and horizontal scroll reveals extreme widths.
    private func displayMessage(_ raw: String) -> String {
        let oneLiner = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)

        // Valid JSON → show only the first 80 chars; full object via right-click
        if oneLiner.hasPrefix("{") || oneLiner.hasPrefix("[") {
            if let data = oneLiner.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                let limit = 80
                return oneLiner.count > limit
                    ? String(oneLiner.prefix(limit)) + "…"
                    : oneLiner
            }
        }

        return oneLiner
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        weak var textView: NSTextView?
        var lastCount   = 0
        var lastVersion = 0
        private var popover: NSPopover?

        func showJSONPopover(json: String, relativeTo view: NSView) {
            popover?.close()

            let innerTV = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
            innerTV.isEditable         = false
            innerTV.isSelectable       = true
            innerTV.backgroundColor    = .textBackgroundColor
            innerTV.textContainerInset = NSSize(width: 12, height: 10)
            innerTV.textStorage?.setAttributedString(JSONHighlighter.highlightNS(json))

            let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 340))
            sv.documentView          = innerTV
            sv.hasVerticalScroller   = true
            sv.hasHorizontalScroller = true

            let vc    = NSViewController()
            vc.view   = sv
            let p     = NSPopover()
            p.contentViewController = vc
            p.contentSize = NSSize(width: 500, height: 340)
            p.behavior    = .transient
            p.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
            popover = p
        }
    }
}
