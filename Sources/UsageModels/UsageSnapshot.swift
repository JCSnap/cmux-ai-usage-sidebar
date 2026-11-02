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
    /// The last read failed, but the numbers from an earlier read are recent
    /// enough to show. `windows` holds them, `updatedAt` says when they were
    /// read, and `detail` says why the refresh failed.
    case stale
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
    /// Failure text when `state` is `.error` or `.stale`, otherwise nil.
    public let detail: String?
    /// When `windows` were read from the vendor. A `.stale` account keeps the
    /// time of its last good read, so the panel can say how old the bars are.
    public let updatedAt: Date?
    /// The enabled logins behind a CLIProxyAPI pool. Nil for an ordinary account.
    /// The pool's windows average only members with fresh readings.
    public let members: [UsageAccount]?

    public init(
        id: String,
        provider: UsageProvider,
        displayName: String,
        plan: String? = nil,
        email: String? = nil,
        state: UsageAccountState,
        windows: [UsageWindow] = [],
        detail: String? = nil,
        updatedAt: Date? = nil,
        members: [UsageAccount]? = nil
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.plan = plan
        self.email = email
        self.state = state
        self.windows = windows
        self.detail = detail
        self.updatedAt = updatedAt
        self.members = members
    }

    /// Whether this row stands for a pool of accounts rather than one login.
    public var isPool: Bool { members?.isEmpty == false }

    /// Count fresh readings, optionally for one window. A full quota still counts.
    public func reportingMemberCount(for window: UsageWindow? = nil) -> Int {
        guard state == .ok else { return 0 }
        return (members ?? []).filter { member in
            guard member.state == .ok else { return false }
            if let window { return member.windows.contains { $0.id == window.id } }
            return !member.windows.isEmpty
        }.count
    }

    /// How much of a pool window frees up as its members reset, at fixed marks.
    ///
    /// Each member that reports `window` freshly counts toward the average, as
    /// in the pool bar. A member frees its share, `usedFraction / count`, when
    /// its window resets. A member without a reset time stays in the count but
    /// frees nothing. A reset that has already passed counts as freeing now.
    ///
    /// Marks fall every hour, or every day when the last reset is more than a
    /// day away. Each mark is cumulative. A "now" mark leads when a passed
    /// reset frees at least one whole percent. A mark whose whole percent
    /// equals the one before it is dropped, and so are leading 0% marks. The
    /// last mark covers the last reset, so it equals the full freed share.
    public func headroomGains(for window: UsageWindow, now: Date = .now) -> [HeadroomGain] {
        guard state == .ok else { return [] }
        let windows = (members ?? []).compactMap { member -> UsageWindow? in
            guard member.state == .ok else { return nil }
            return member.windows.first { $0.id == window.id }
        }
        guard !windows.isEmpty else { return [] }
        let share = 1 / Double(windows.count)
        let resets: [(seconds: TimeInterval, fraction: Double)] = windows.compactMap { member in
            guard let resetsAt = member.resetsAt else { return nil }
            return (max(0, resetsAt.timeIntervalSince(now)), max(0, min(1, member.usedFraction)) * share)
        }
        guard let lastReset = resets.map(\.seconds).max() else { return [] }
        func freed(by seconds: TimeInterval) -> Double {
            resets.filter { $0.seconds <= seconds }.reduce(0) { $0 + $1.fraction }
        }

        let (step, unit): (TimeInterval, String) = lastReset > 86_400 ? (86_400, "d") : (3600, "h")
        var gains = [HeadroomGain(at: now, label: "now", fraction: freed(by: 0))]
        let count = max(1, Int((lastReset / step).rounded(.up)))
        for index in 1...count {
            let seconds = Double(index) * step
            gains.append(HeadroomGain(
                at: now.addingTimeInterval(seconds), label: "\(index)\(unit)", fraction: freed(by: seconds)))
        }
        var shown: [HeadroomGain] = []
        for gain in gains where gain.percent >= 1 && gain.percent != shown.last?.percent {
            shown.append(gain)
        }
        return shown
    }

    /// Whether the row has numbers to draw. A stale account still does; its
    /// bars are simply older than one refresh cycle.
    public var showsWindows: Bool { state == .ok || state == .stale }

    /// The window that is closest to its limit. Drives the one-line summary.
    public var worstWindow: UsageWindow? {
        windows.max { $0.usedFraction < $1.usedFraction }
    }
}

/// Pool headroom that is free again by `at`, as a fraction of the pool.
public struct HeadroomGain: Sendable, Hashable {
    public let at: Date
    /// The mark's offset from now, such as "now", "3h" or "2d".
    public let label: String
    public let fraction: Double

    /// Whole percent of the pool, as the pool bar rounds it.
    public var percent: Int { Int((fraction * 100).rounded()) }

    public init(at: Date, label: String, fraction: Double) {
        self.at = at
        self.label = label
        self.fraction = fraction
    }
}

/// An account the user hid from the sidebar. The daemon does not read it, so
/// it carries only what the panel needs to offer it back.
public struct HiddenAccount: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let provider: UsageProvider
    public let displayName: String

    public init(id: String, provider: UsageProvider, displayName: String) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
    }
}

/// Everything the daemon knows, as served on the loopback port.
public struct UsageSnapshot: Codable, Sendable, Hashable {
    public let generatedAt: Date
    public let accounts: [UsageAccount]
    /// Accounts left out of `accounts` by the user. Nil from a daemon that
    /// predates hiding.
    public let hidden: [HiddenAccount]?

    public init(generatedAt: Date, accounts: [UsageAccount], hidden: [HiddenAccount]? = nil) {
        self.generatedAt = generatedAt
        self.accounts = accounts
        self.hidden = hidden
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
