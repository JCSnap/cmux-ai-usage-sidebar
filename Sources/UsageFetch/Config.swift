import Foundation
import UsageModels

/// One configured account. Only the fields for its own provider are used.
public struct AccountConfig: Codable, Sendable {
    public let id: String
    public let provider: UsageProvider
    public let displayName: String
    /// Claude: keychain service name that holds the OAuth blob.
    public let keychainService: String?
    /// Codex: directory that holds `auth.json` (the `CODEX_HOME` value).
    public let codexHome: String?
    /// Antigravity: the `HOME` the account runs under.
    public let home: String?

    public init(
        id: String,
        provider: UsageProvider,
        displayName: String,
        keychainService: String? = nil,
        codexHome: String? = nil,
        home: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.keychainService = keychainService
        self.codexHome = codexHome
        self.home = home
    }
}

public struct Config: Codable, Sendable {
    public var port: UInt16
    public var refreshSeconds: Int
    public var accounts: [AccountConfig]

    public init(port: UInt16 = 47823, refreshSeconds: Int = 300, accounts: [AccountConfig]) {
        self.port = port
        self.refreshSeconds = refreshSeconds
        self.accounts = accounts
    }

    public static let path = NSString(string: "~/.config/ai-usage/config.json").expandingTildeInPath

    /// Matches the cc1/cc2, c1/c2, agy1/agy2 layout set up in `~/.zshrc`.
    /// The Claude suffix is derived by Claude Code from `CLAUDE_CONFIG_DIR`.
    public static let bundled = Config(accounts: [
        .init(id: "cc1", provider: .claude, displayName: "cc1",
              keychainService: "Claude Code-credentials"),
        .init(id: "cc2", provider: .claude, displayName: "cc2",
              keychainService: "Claude Code-credentials-950212fc"),
        .init(id: "c1", provider: .codex, displayName: "c1", codexHome: "~/.codex"),
        .init(id: "c2", provider: .codex, displayName: "c2", codexHome: "~/.codex-2"),
        .init(id: "agy1", provider: .antigravity, displayName: "agy1", home: "~"),
        .init(id: "agy2", provider: .antigravity, displayName: "agy2", home: "~/.agy-home-2"),
    ])

    /// Reads the config file. Writes the bundled default first if none exists.
    public static func load() throws -> Config {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(bundled).write(to: url)
            return bundled
        }
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }
}

extension String {
    var expandedPath: String { NSString(string: self).expandingTildeInPath }
}
