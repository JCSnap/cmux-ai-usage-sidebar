import Foundation
import UsageModels

/// How many accounts of weekly quota each CLIProxyAPI pool burned today.
///
/// Every machine that uses a pool sends its requests through the same logins.
/// The sum of today's rise in each login's weekly window is therefore the pool's
/// burn across all machines, in accounts: one login going from 0% to 100% is
/// one account. The ledger reuses the daemon's own readings, so it costs no
/// extra usage request.
///
/// The daemon writes the ledger to `pool-day.json` after each collection. A
/// status line reads that file and never calls a usage endpoint itself.
public struct PoolDayLedger: Codable, Sendable, Equatable {
    public var version: Int
    /// One entry per pool id, for example "cc3".
    public var pools: [String: PoolDay]

    public init(version: Int = 1, pools: [String: PoolDay] = [:]) {
        self.version = version
        self.pools = pools
    }

    public static let path = NSString(string: "~/.config/ai-usage/pool-day.json").expandingTildeInPath

    /// The pool refills one account per login per week.
    public static let windowDays = 7.0

    /// A reading below the previous one by more than this is a weekly reset,
    /// even when the vendor sends no reset time.
    static let resetDrop = 0.01

    /// A reset time that moves later by more than this marks a new window.
    /// Smaller moves are the vendor rounding the same reset time.
    static let resetShift: TimeInterval = 3600

    /// The ledger after one collection, for the local day that holds `now`.
    ///
    /// A pool read for the first time on a new day starts that day's entry, and
    /// each login's first fresh reading becomes its baseline. A login without a
    /// fresh reading keeps its last value and marks the pool as partial.
    public func updated(
        with snapshot: UsageSnapshot, at now: Date, calendar: Calendar = .current
    ) -> PoolDayLedger {
        var ledger = self
        for pool in snapshot.accounts where pool.isPool {
            let earlier = pools[pool.id]
            ledger.pools[pool.id] = PoolDay.updated(
                earlier, pool: pool, at: now, calendar: calendar)
        }
        return ledger
    }

    public static func load(from path: String = PoolDayLedger.path) -> PoolDayLedger? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? UsageSnapshot.decoder().decode(PoolDayLedger.self, from: data)
    }

    /// Writes the ledger atomically, so a reader never sees half a file.
    public func save(to path: String = PoolDayLedger.path) {
        guard let data = try? UsageSnapshot.encoder().encode(self) else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// One pool's burn for one local day.
public struct PoolDay: Codable, Sendable, Equatable {
    /// The local day, as `yyyy-MM-dd`.
    public var day: String
    /// When the first baseline of the day was taken. A time well after
    /// midnight means the daemon was down, so the burn is too low.
    public var since: Date
    /// `since` as local `HH:mm`, for a status line that has no date library.
    public var sinceLocal: String
    /// Whether `since` is within 15 minutes of local midnight.
    public var coversDay: Bool
    public var updatedAt: Date
    /// The logins the pool holds now.
    public var memberCount: Int
    /// Accounts per day that the pool refills: `memberCount / 7`.
    public var breakEvenAccountsPerDay: Double
    /// Today's burn, in accounts of weekly quota.
    public var accountsBurned: Double
    /// True when a login has no fresh reading in the latest collection.
    /// Its last value still counts.
    public var partial: Bool
    /// The logins without a fresh reading in the latest collection.
    public var missing: [String]
    public var logins: [String: LoginDay]

    static let coverSlack: TimeInterval = 15 * 60

    static func updated(
        _ earlier: PoolDay?, pool: UsageAccount, at now: Date, calendar: Calendar
    ) -> PoolDay {
        let today = dayKey(now, calendar: calendar)
        let start = earlier?.day == today ? earlier : nil
        var logins = start?.logins ?? [:]
        var missing: [String] = []
        let members = pool.members ?? []
        for member in members {
            guard pool.state == .ok, member.state == .ok,
                  let week = member.windows.first(where: { $0.group == nil && $0.label == "7d" })
            else {
                missing.append(member.id)
                continue
            }
            let readAt = member.updatedAt ?? now
            if let login = logins[member.id] {
                logins[member.id] = login.reading(week, at: readAt)
            } else {
                logins[member.id] = LoginDay(first: week, at: readAt)
            }
        }
        let since = start?.since ?? now
        let burned = logins.values.reduce(0) { $0 + $1.burned }
        return PoolDay(
            day: today,
            since: since,
            sinceLocal: localTime(since, calendar: calendar),
            coversDay: since.timeIntervalSince(calendar.startOfDay(for: since)) <= coverSlack,
            updatedAt: now,
            memberCount: members.count,
            breakEvenAccountsPerDay: Double(members.count) / PoolDayLedger.windowDays,
            accountsBurned: burned,
            partial: !missing.isEmpty,
            missing: missing,
            logins: logins)
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func localTime(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// One login's weekly window over one local day.
public struct LoginDay: Codable, Sendable, Equatable {
    /// The weekly fraction the current window started the day at, or 0 after
    /// a reset inside the day.
    public var baseline: Double
    /// The latest weekly fraction read.
    public var last: Double
    public var lastAt: Date
    public var resetsAt: Date?
    /// The rise counted in earlier windows of the same day, before a reset.
    public var earlierWindows: Double

    /// Today's rise, in accounts.
    public var burned: Double { earlierWindows + max(0, last - baseline) }

    init(first week: UsageWindow, at date: Date) {
        let fraction = Self.clamped(week.usedFraction)
        baseline = fraction
        last = fraction
        lastAt = date
        resetsAt = week.resetsAt
        earlierWindows = 0
    }

    /// The login after a new reading. A weekly reset adds the rise before it
    /// and starts the new window from zero, because a fresh window starts empty.
    func reading(_ week: UsageWindow, at date: Date) -> LoginDay {
        let fraction = Self.clamped(week.usedFraction)
        var next = self
        let movedReset = week.resetsAt.flatMap { new in
            resetsAt.map { new.timeIntervalSince($0) > PoolDayLedger.resetShift }
        } ?? false
        let isReset = movedReset || fraction < last - PoolDayLedger.resetDrop
        if isReset {
            next.earlierWindows += max(0, last - baseline)
            next.baseline = 0
        }
        next.last = fraction
        next.lastAt = date
        // After a reset, the old reset time belongs to the closed window. Keeping
        // it would count the same reset again when the new time first arrives.
        next.resetsAt = isReset ? week.resetsAt : (week.resetsAt ?? resetsAt)
        return next
    }

    static func clamped(_ fraction: Double) -> Double { max(0, min(1, fraction)) }
}
