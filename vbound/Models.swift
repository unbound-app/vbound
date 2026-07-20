import Foundation
import SwiftUI

enum LogTab: Equatable {
    case unbound, reactNative, shell
}

enum UnreadLevel: Equatable {
    case none, info, error
}

enum LogSubsystem: String, CaseIterable {
    case unbound     = "app.unbound"
    case reactNative = "com.facebook.react.log"

    var label: String {
        switch self {
        case .unbound:     return "Unbound"
        case .reactNative: return "React Native"
        }
    }
}

struct LogEntry: Identifiable {
    let id        = UUID()
    let time      : String
    let level     : String
    let source    : String
    let message   : String
    let subsystem : LogSubsystem?

    var isHeader: Bool { time.isEmpty }

    func asString() -> String {
        isHeader ? message : "\(time)  \(level.isEmpty ? "   " : level)  [\(source)]  \(message)"
    }
}

// MARK: - Shell output (ANSI-aware)

struct ShellSegment: Equatable {
    var text: String
    var color: Color?
    var bold: Bool = false
}

struct ShellLine: Equatable {
    var segments: [ShellSegment] = [ShellSegment(text: "")]

    var plain: String { segments.map(\.text).joined() }
    var isEmpty: Bool { plain.isEmpty }

    mutating func append(_ char: Character, color: Color?, bold: Bool) {
        if var last = segments.last, last.color == color, last.bold == bold {
            last.text.append(char)
            segments[segments.count - 1] = last
        } else {
            segments.append(ShellSegment(text: String(char), color: color, bold: bold))
        }
    }
}

// Parses incoming terminal bytes into lines while tracking SGR (color/bold) escape
// codes so shell output renders with real color instead of raw escape sequences.
// Non-SGR CSI/ESC sequences (cursor movement, clear-line, etc.) are consumed and
// dropped — full cursor-addressable terminal emulation is out of scope here.
final class ANSILineBuffer {
    private(set) var lines: [ShellLine] = [ShellLine()]

    private var currentColor: Color?
    private var currentBold = false

    func reset() {
        lines = [ShellLine()]
        currentColor = nil
        currentBold = false
    }

    func feed(_ raw: String, maxLines: Int) {
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c == "\u{1B}" {
                i = consumeEscape(raw, from: i)
                continue
            }
            let ni = raw.index(after: i)
            switch c {
            case "\r":
                if ni < raw.endIndex, raw[ni] == "\n" {
                    lines.append(ShellLine())
                    i = raw.index(after: ni)
                } else {
                    if lines.isEmpty { lines.append(ShellLine()) }
                    let hadContent = !lines[lines.count - 1].isEmpty
                    lines[lines.count - 1] = ShellLine()
                    if hadContent && lines.dropLast().contains(where: { !$0.isEmpty }) {
                        lines.insert(ShellLine(), at: lines.count - 1)
                    }
                    i = ni
                }
            case "\n":
                lines.append(ShellLine())
                i = ni
            default:
                if lines.isEmpty { lines.append(ShellLine()) }
                lines[lines.count - 1].append(c, color: currentColor, bold: currentBold)
                i = ni
            }
        }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    // Consumes one escape sequence starting at `start` (pointing at ESC) and returns
    // the index just past it. Only plain SGR (`ESC [ Pm m`) sequences have an effect —
    // private-mode sequences like `ESC [ ? 2004 h` (bracketed paste) are recognized and
    // dropped rather than falling through to the digit scanner, which previously left
    // their trailing digits ("2004h") behind as literal text.
    private func consumeEscape(_ raw: String, from start: String.Index) -> String.Index {
        var i = raw.index(after: start)
        guard i < raw.endIndex else { return i }
        guard raw[i] == "[" else { return raw.index(after: i) }  // lone ESC + one char
        i = raw.index(after: i)  // past '['

        // Parameter bytes per ECMA-48: 0-9 : ; < = > ?
        let paramsStart = i
        while i < raw.endIndex, let v = raw[i].asciiValue, (0x30...0x3F).contains(v) {
            i = raw.index(after: i)
        }
        let paramsEnd = i
        // Intermediate bytes: space through '/'
        while i < raw.endIndex, let v = raw[i].asciiValue, (0x20...0x2F).contains(v) {
            i = raw.index(after: i)
        }
        guard i < raw.endIndex else { return i }
        let final  = raw[i]
        let params = raw[paramsStart..<paramsEnd]
        let next   = raw.index(after: i)
        let isPrivate = params.first.map { !("0"..."9").contains($0) } ?? false
        if final == "m", !isPrivate { applySGR(params) }
        return next
    }

    private func applySGR(_ params: Substring) {
        let codes = params.isEmpty ? [0] : params.split(separator: ";").compactMap { Int($0) }
        for code in codes {
            switch code {
            case 0:  currentColor = nil; currentBold = false
            case 1:  currentBold = true
            case 22: currentBold = false
            case 30: currentColor = .black
            case 31: currentColor = .red
            case 32: currentColor = .green
            case 33: currentColor = .yellow
            case 34: currentColor = .blue
            case 35: currentColor = .purple
            case 36: currentColor = .cyan
            case 37: currentColor = .white
            case 39: currentColor = nil
            case 90: currentColor = .gray
            case 91: currentColor = .red.opacity(0.8)
            case 92: currentColor = .green.opacity(0.8)
            case 93: currentColor = .yellow.opacity(0.8)
            case 94: currentColor = .blue.opacity(0.8)
            case 95: currentColor = .purple.opacity(0.8)
            case 96: currentColor = .cyan.opacity(0.8)
            case 97: currentColor = .white.opacity(0.8)
            default: break
            }
        }
    }
}

enum BuildPhase: Equatable {
    case idle, building, buildingPlugins, uploading, installing, deployingPlugins, restarting
    case succeeded, pluginsDeployed
    case cancelled
    case failed(String)

    var isActive: Bool { self != .idle }

    var isRunning: Bool {
        switch self {
        case .building, .buildingPlugins, .uploading, .installing, .deployingPlugins, .restarting: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle:            return ""
        case .building:        return "Building…"
        case .buildingPlugins: return "Building plugins…"
        case .uploading:       return "Uploading…"
        case .installing:      return "Installing…"
        case .deployingPlugins:return "Deploying plugins…"
        case .restarting:      return "Restarting Discord…"
        case .succeeded:       return "Build installed"
        case .pluginsDeployed: return "Plugins deployed"
        case .cancelled:       return "Build cancelled"
        case .failed(let msg): return msg
        }
    }
}
