import Foundation

enum MCPInstaller {
    static let serverName = "vbound"

    static var installURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/bin/vbound-mcp")
    }

    static var isInstalled: Bool {
        let codexURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/config.toml")
        let claudeURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
        let codex = (try? String(contentsOf: codexURL))?.contains("[mcp_servers.\(serverName)]") ?? false
        let claude = (try? String(contentsOf: claudeURL))?.contains("\"\(serverName)\"") ?? false
        return codex && claude && FileManager.default.isExecutableFile(atPath: installURL.path)
    }

    static func install(using manager: AppController, onOutput: @escaping ([String]) -> Void) async -> Bool {
        guard let serverURL = Bundle.main.url(forResource: "vbound-mcp", withExtension: "py") else { return false }
        do {
            try FileManager.default.createDirectory(at: installURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: installURL.path) {
                try FileManager.default.removeItem(at: installURL)
            }
            try FileManager.default.copyItem(at: serverURL, to: installURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installURL.path)
        } catch {
            return false
        }
        _ = await manager.run(args: ["codex", "mcp", "remove", serverName])
        guard await manager.run(args: ["codex", "mcp", "add", serverName, "--", installURL.path], onOutput: onOutput) else { return false }
        _ = await manager.run(args: ["claude", "mcp", "remove", serverName])
        return await manager.run(args: ["claude", "mcp", "add", serverName, "--", installURL.path], onOutput: onOutput)
    }
}
