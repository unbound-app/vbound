import Foundation

enum LogTab: Equatable {
    case unbound, reactNative, shell
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

enum BuildPhase {
    case idle, building, uploading, installing, restarting, finishing

    var isActive: Bool { self != .idle }

    var isRunning: Bool {
        switch self {
        case .building, .uploading, .installing, .restarting: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle, .finishing: return ""
        case .building:         return "Building…"
        case .uploading:        return "Uploading…"
        case .installing:       return "Installing…"
        case .restarting:       return "Restarting Discord…"
        }
    }
}
