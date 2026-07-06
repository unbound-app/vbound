import AppKit
import QuartzCore
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

// MARK: - NSObject/ObjC description detection

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

// MARK: - Link tag constants
// Used as the .link attribute value so the delegate can distinguish click targets.
private let kLinkTagTimestamp = "ts"
private let kLinkTagBadge     = "badge"

// MARK: - NSTextView subclass

final class LogNSTextView: NSTextView {
    var entryRanges:    [(range: NSRange, entry: LogEntry)]               = []
    var timestampRanges:[(range: NSRange, fullTime: String)]              = []
    var popoverRanges:  [(range: NSRange, content: String)] = []

    var onCopyLine:        ((LogEntry) -> Void)?
    var onFilterToSource:  ((LogEntry) -> Void)?
    var onUserInteraction: (() -> Void)?
    var onReachedBottom:   (() -> Void)?

    // Any direct click disengages auto-scroll, even one that doesn't move the
    // scroll position (e.g. clicking to place the cursor while already at the bottom).
    override func mouseDown(with event: NSEvent) {
        onUserInteraction?()
        super.mouseDown(with: event)
    }

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

    // Timestamps and the {} object badge are clickable, but they still read as plain
    // text — show the ordinary arrow cursor over them instead of a pointing hand;
    // everywhere else keeps the iBeam since the body text is selectable.
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
                NSCursor.arrow.set()
                return
            }
        }
        NSCursor.iBeam.set()
    }
}

// MARK: - SwiftUI wrapper

struct LogTextView: NSViewRepresentable {
    let entries:           [LogEntry]
    let scrollVersion:     Int
    var autoScroll:        Bool = true
    var searchQuery:       String = ""
    var focusedEntryID:    LogEntry.ID? = nil
    var onFilterToSource:  ((LogEntry) -> Void)? = nil
    var onUserInteraction: (() -> Void)? = nil
    var onReachedBottom:   (() -> Void)? = nil

    // Tab stops match this row's fixed-frame column layout (textContainerInset.width = 8):
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

    struct DisplayRow {
        let entry:     LogEntry
        let count:     Int
        let lastIndex: Int
    }

    // Cheap stand-in for "would buildContent() actually produce something different."
    // NSViewRepresentable.updateNSView fires on every SwiftUI re-render that touches this
    // view, not just when entries/searchQuery/focusedEntryID themselves changed — this
    // view sits inside ContentView, which has plenty of unrelated @State (shellInput,
    // shellHistoryIndex, etc.) whose changes would otherwise trigger a full rebuild of
    // the attributed string (an O(n) pass — collapsing, NSObject-detection regex, and
    // search-highlight scanning over every buffered line) for no reason. First/last id
    // + count is enough to distinguish "genuinely different content" from "same content,
    // unrelated state changed elsewhere" without comparing the whole array.
    struct RenderInputs: Equatable {
        let count:          Int
        let firstID:        LogEntry.ID?
        let lastID:         LogEntry.ID?
        let searchQuery:    String
        let focusedEntryID: LogEntry.ID?
    }

    // The raw syslog line can carry incidental trailing whitespace/newlines that vary
    // between otherwise-identical occurrences (invisible once rendered, since the
    // message is trimmed for display) — normalize before comparing so that noise
    // doesn't defeat duplicate detection (#19).
    private static func normalizedMessage(_ message: String) -> String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Groups immediately-consecutive rows that share source/level/message so a device
    // logging the same line in a tight loop renders as one row with a "×N" counter
    // instead of N separately-flashing rows.
    static func collapseConsecutive(_ entries: [LogEntry]) -> [DisplayRow] {
        var rows: [DisplayRow] = []
        for (i, entry) in entries.enumerated() {
            if !entry.isHeader,
               let last = rows.last, !last.entry.isHeader,
               normalizedMessage(last.entry.message) == normalizedMessage(entry.message),
               last.entry.source == entry.source,
               last.entry.level == entry.level {
                rows[rows.count - 1] = DisplayRow(entry: entry, count: last.count + 1, lastIndex: i)
            } else {
                rows.append(DisplayRow(entry: entry, count: 1, lastIndex: i))
            }
        }
        return rows
    }

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

        // Distinguishes a user-initiated scroll (scroll wheel, dragging the scrollbar)
        // from bounds changes we caused ourselves — either directly (our own
        // scrollToEndOfDocument(_:) calls) or indirectly (AppKit's own initial layout
        // pass fires this same notification once when the clip view is first sized,
        // and TextKit can settle the scroll position on a later runloop tick after a
        // fresh scrollToEndOfDocument, once glyph layout catches up). A single
        // synchronous before/after flag only caught the direct case and was still
        // seeing these as "user interaction," silently disengaging auto-scroll before
        // the user ever touched anything (#18).
        sv.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: sv.contentView, queue: .main
        ) { [weak sv, weak coordinator = context.coordinator] _ in
            guard let c = coordinator else { return }
            guard c.hasSeenInitialLayout else { c.hasSeenInitialLayout = true; return }
            guard Date() >= c.ignoreInteractionUntil else { return }
            // Scrolling back down to the bottom yourself is treated the same as clicking
            // the pin — it means you want to resume following the live tail again.
            if let sv, let docView = sv.documentView,
               sv.contentView.bounds.maxY >= docView.frame.height - 2 {
                c.textView?.onReachedBottom?()
            } else {
                c.textView?.onUserInteraction?()
            }
        }

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
        tv.onFilterToSource  = onFilterToSource
        tv.onUserInteraction = onUserInteraction
        tv.onReachedBottom   = onReachedBottom

        let currentInputs = RenderInputs(
            count: entries.count,
            firstID: entries.first?.id,
            lastID: entries.last?.id,
            searchQuery: searchQuery,
            focusedEntryID: focusedEntryID
        )

        if currentInputs != c.lastRenderInputs {
            let result = buildContent()
            storage.setAttributedString(result.str)
            tv.entryRanges     = result.entryRanges
            tv.timestampRanges = result.timestampRanges
            tv.popoverRanges   = result.popoverRanges
            c.lastRenderInputs = currentInputs

            // Jump to a specific search match (⌘G / next-match button). Gated on the
            // target actually changing so this doesn't re-scroll while the same match
            // is still focused — note this can only fire inside this branch anyway,
            // since focusedEntryID is itself part of the fingerprint above.
            if let focusedEntryID, focusedEntryID != c.lastFocusedEntryID,
               let hit = result.entryRanges.first(where: { $0.entry.id == focusedEntryID }) {
                c.lastFocusedEntryID = focusedEntryID
                tv.scrollRangeToVisible(hit.range)
            } else if focusedEntryID == nil {
                c.lastFocusedEntryID = nil
            }
        }

        let shouldScroll = autoScroll && (entries.count > c.lastCount || scrollVersion != c.lastVersion)
        c.lastCount   = entries.count
        c.lastVersion = scrollVersion
        if shouldScroll {
            DispatchQueue.main.async {
                // A generous grace window, not just a before/after flag around this one
                // call — TextKit can still be settling layout for content set moments
                // ago, and a follow-up bounds notification can land after this closure
                // already returns.
                c.ignoreInteractionUntil = Date().addingTimeInterval(0.3)

                // Let scrollToEndOfDocument figure out the correct target position (it
                // knows about TextKit layout we'd otherwise have to recompute by hand),
                // then replay that same move as an animation instead of an instant jump —
                // a smooth glide reads as "a line arrived" instead of the view snapping.
                let clipView     = sv.contentView
                let priorOrigin  = clipView.bounds.origin
                tv.scrollToEndOfDocument(nil)
                let targetOrigin = clipView.bounds.origin
                guard targetOrigin != priorOrigin else { return }
                clipView.setBoundsOrigin(priorOrigin)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration       = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    clipView.animator().setBoundsOrigin(targetOrigin)
                }
            }
        }
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
        var popoverRanges:  [(range: NSRange, content: String)]
    }

    private func buildContent() -> BuildResult {
        let monoR = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let monoS = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let body  = NSFont.systemFont(ofSize: 13)

        let out = NSMutableAttributedString()
        var entryRanges:    [(range: NSRange, entry: LogEntry)]               = []
        var timestampRanges:[(range: NSRange, fullTime: String)]              = []
        var popoverRanges:  [(range: NSRange, content: String)] = []

        // Collapse immediately-consecutive identical lines (same source/level/message)
        // into one row with a "×N" counter, à la Console.app, instead of flooding the
        // view with N separate rows for a device logging the same status in a loop.
        let rows = Self.collapseConsecutive(entries)

        func ns(_ str: String, font: NSFont, color: NSColor,
                bg: NSColor? = nil) -> NSAttributedString {
            var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let bg { a[.backgroundColor] = bg }
            return NSAttributedString(string: str, attributes: a)
        }

        for row in rows {
            let entry    = row.entry
            let rowStart = out.length

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

                // Structured-data detection — NSObject/ObjC description dumps
                let nsObj          = detectNSObject(entry.message)
                let hasBadge:       Bool
                let displayMsg:     String
                let popoverContent: String

                if let obj = nsObj, !obj.isEmpty {
                    hasBadge       = true
                    displayMsg     = obj.prefix
                    popoverContent = obj.body
                } else {
                    hasBadge       = false
                    displayMsg     = entry.message
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    popoverContent = ""
                }

                if hasBadge {
                    let badgeStart = out.length
                    out.append(makeAttachment(image: badgeImage()))
                    out.append(ns(" ", font: body, color: .clear))
                    let badgeRange = NSRange(location: badgeStart, length: out.length - badgeStart)
                    // Tag with .link so the pointing-hand cursor and delegate fire on click.
                    out.addAttribute(.link, value: kLinkTagBadge, range: badgeRange)
                    popoverRanges.append((range: badgeRange, content: popoverContent))
                }

                let msgStart = out.length
                out.append(ns(displayMsg, font: body, color: .labelColor))
                if !searchQuery.isEmpty {
                    // The row currently targeted by find-next/previous gets a stronger
                    // color than the rest of the matches so it's obvious which one you
                    // just jumped to among possibly many highlighted occurrences.
                    let isFocusedRow    = entry.id == focusedEntryID
                    let highlightColor  = isFocusedRow
                        ? NSColor.systemOrange.withAlphaComponent(0.55)
                        : NSColor.systemYellow.withAlphaComponent(0.4)
                    for range in ranges(of: searchQuery, in: displayMsg) {
                        out.addAttribute(.backgroundColor,
                                         value: highlightColor,
                                         range: NSRange(location: msgStart + range.location, length: range.length))
                    }
                }
                if row.count > 1 {
                    out.append(ns(" ", font: body, color: .clear))
                    out.append(makeAttachment(image: pillImage(
                        label: "×\(row.count)",
                        fg: .secondaryLabelColor,
                        bg: NSColor.secondaryLabelColor.withAlphaComponent(0.12))))
                }
                out.append(ns("\n", font: body, color: .labelColor))
            }

            let rowRange = NSRange(location: rowStart, length: out.length - rowStart)
            out.addAttribute(.paragraphStyle, value: Self.paraStyle, range: rowRange)
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
        var lastFocusedEntryID: LogEntry.ID?
        var lastRenderInputs: RenderInputs?
        var hasSeenInitialLayout = false
        var ignoreInteractionUntil = Date.distantPast
        private var popover: NSPopover?
        // Backs the one shared copy button both popovers use — text is selectable in
        // showCodePopover's NSTextView already, but there was no one-click way to grab
        // it, unlike every other output surface in the app (log/shell toolbars both
        // have a dedicated copy button).
        private var pendingPopoverCopyText: String?

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
                showCodePopover(code: hit.content, in: tv, anchor: anchor)
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

            // Overlaid on top of the scroll view rather than a separate header row —
            // simpler than resizing the popover to make room, and the generous width
            // padding above already keeps it clear of most content.
            let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
            container.addSubview(sv)
            let copyImage = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy") ?? NSImage()
            let copyButton = NSButton(image: copyImage, target: self, action: #selector(copyPendingPopoverText))
            copyButton.isBordered = false
            copyButton.toolTip = "Copy"
            copyButton.frame = NSRect(x: w - 24, y: h - 22, width: 18, height: 18)
            container.addSubview(copyButton)
            pendingPopoverCopyText = code

            let vc = NSViewController(); vc.view = container
            let p  = NSPopover()
            p.contentViewController = vc
            p.contentSize = NSSize(width: w, height: h)
            p.behavior    = .transient
            p.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
            popover = p
        }

        @objc private func copyPendingPopoverText() {
            guard let text = pendingPopoverCopyText else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        func showTimestampPopover(time: String, in view: NSView, anchor: NSRect) {
            guard !time.isEmpty else { return }
            popover?.close()
            let label = NSTextField(labelWithString: time)
            label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            label.sizeToFit()

            let copyImage = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy") ?? NSImage()
            let copyButton = NSButton(image: copyImage, target: self, action: #selector(copyPendingPopoverText))
            copyButton.isBordered = false
            copyButton.toolTip = "Copy"
            copyButton.frame = NSRect(x: 0, y: 0, width: 16, height: 16)

            let pad: CGFloat = 10
            let gap: CGFloat = 6
            let contentHeight = max(label.frame.height, copyButton.frame.height)
            let frame = NSRect(x: 0, y: 0,
                               width:  label.frame.width + gap + copyButton.frame.width + pad * 2,
                               height: contentHeight + pad * 2)
            let container = NSView(frame: frame)
            label.frame   = label.frame.offsetBy(dx: pad, dy: pad + (contentHeight - label.frame.height) / 2)
            copyButton.frame = copyButton.frame.offsetBy(
                dx: pad + label.frame.width + gap,
                dy: pad + (contentHeight - copyButton.frame.height) / 2)
            container.addSubview(label)
            container.addSubview(copyButton)
            pendingPopoverCopyText = time

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
