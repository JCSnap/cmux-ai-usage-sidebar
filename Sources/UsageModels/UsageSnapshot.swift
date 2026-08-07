import Foundation

/// Which agent CLI an account belongs to.
public enum UsageProvider: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case grok
    case antigravity

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok"
        case .antigravity: "Antigravity"
        }
    }
}

/// Whether the daemon could read this account at all.
public enum UsageAccountState: String, Codable, Sendable {
    /// Live numbers were read.
    case ok
    /// No credential is stored. The account needs a login, not a fix.
    case signedOut
    /// A credential exists but the read failed. `detail` says why.
    case error
}

/// One rate-limit window, for example the Claude 5-hour window.
public struct UsageWindow: Codable, Sendable, Hashable, Identifiable {
    /// Optional group name. Antigravity meters two model groups separately;
    /// Claude and Codex leave this nil.
    public let group: String?
    /// Short window label, for example "5h" or "7d".
    public let label: String
    /// Fraction of the window consumed, 0...1.
    public let usedFraction: Double
    public let resetsAt: Date?

    public var id: String { "\(group ?? "")|\(label)" }

    /// Whole-percent used, clamped to 0...100 for display.
    public var usedPercent: Int {
        Int((max(0, min(1, usedFraction)) * 100).rounded())
    }

    public init(group: String? = nil, label: String, usedFraction: Double, resetsAt: Date? = nil) {
        self.group = group
        self.label = label
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
    }
}

/// One account of one provider, for example `cc2` or `agy1`.
public struct UsageAccount: Codable, Sendable, Hashable, Identifiable {
    /// Stable key that matches the shell alias, for example "cc1".
    public let id: String
    public let provider: UsageProvider
    public let displayName: String
    public let plan: String?
    public let email: String?
    public let state: UsageAccountState
    public let windows: [UsageWindow]
    /// Failure text when `state` is `.error`, otherwise nil.
    public let detail: String?

    public init(
        id: String,
        provider: UsageProvider,
        displayName: String,
        plan: String? = nil,
        email: String? = nil,
        state: UsageAccountState,
        windows: [UsageWindow] = [],
        detail: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.plan = plan
        self.email = email
        self.state = state
        self.windows = windows
        self.detail = detail
    }

    /// The window that is closest to its limit. Drives the one-line summary.
    public var worstWindow: UsageWindow? {
        windows.max { $0.usedFraction < $1.usedFraction }
    }
}

/// Everything the daemon knows, as served on the loopback port.
public struct UsageSnapshot: Codable, Sendable, Hashable {
    public let generatedAt: Date
    public let accounts: [UsageAccount]

    public init(generatedAt: Date, accounts: [UsageAccount]) {
        self.generatedAt = generatedAt
        self.accounts = accounts
    }

    public static let empty = UsageSnapshot(generatedAt: .distantPast, accounts: [])

    /// Shared wire format. Both sides must use these, or dates will not match.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
