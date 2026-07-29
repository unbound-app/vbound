import Foundation

enum VphoneLaunchAgent {
    static let identifier = "dev.adrian.vbound.vphone-watch"

    static var agentURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(identifier).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func install() -> Bool {
        guard let watcher = Bundle.main.url(forResource: "vbound-vphone-watch", withExtension: "sh") else { return false }
        let watcherURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/lib/vbound-vphone-watch")
        do {
            try FileManager.default.createDirectory(at: watcherURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: watcherURL.path) { try FileManager.default.removeItem(at: watcherURL) }
            try FileManager.default.copyItem(at: watcher, to: watcherURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: watcherURL.path)
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist: [String: Any] = ["Label": identifier, "ProgramArguments": [watcherURL.path, Bundle.main.bundleURL.path], "RunAtLoad": true, "StartInterval": 2]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL, options: .atomic)
            let uid = String(getuid())
            let bootout = Process()
            bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootout.arguments = ["bootout", "gui/\(uid)", agentURL.path]
            try? bootout.run()
            let bootstrap = Process()
            bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootstrap.arguments = ["bootstrap", "gui/\(uid)", agentURL.path]
            try bootstrap.run()
            return true
        } catch {
            return false
        }
    }
}
