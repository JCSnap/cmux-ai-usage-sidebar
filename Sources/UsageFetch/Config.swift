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

    /// The accounts that exist on this machine.
    ///
    /// A shipped account list only ever fits the machine it was written on,
    /// because every agent CLI names its second account store by hand. Read the
    /// machine instead. `Discovery` explains what it looks at.
    public static func discovered() -> Config { Config(accounts: Discovery.accounts()) }

    /// Reads the config file. Writes a discovered one first if none exists.
    ///
    /// The file wins once it exists, so a name or an account the user edited in
    /// is never overwritten by a later scan.
    public static func load() throws -> Config {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            let config = discovered()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try config.encoded().write(to: url)
            return config
        }
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

extension String {
    var expandedPath: String { NSString(string: self).expandingTildeInPath }
}
