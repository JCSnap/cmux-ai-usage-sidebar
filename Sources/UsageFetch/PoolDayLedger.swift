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
/// The day starts at local midnight. Each login's baseline is its reading
/// nearest to and not after midnight. The daemon writes the ledger to
/// `pool-day.json` after each collection. A status line reads that file and
/// never calls a usage endpoint itself.
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
    /// A pool read for the first time on a new day starts that day's entry. A
    /// login read in the last 30 minutes before midnight keeps that reading as
    /// its baseline. Any other login's first fresh reading of the day becomes its
    /// baseline. A login without a fresh reading keeps its last value and marks
    /// the pool as partial.
    public func updated(
        with snapshot: UsageSnapshot, at now: Date, calendar: Calendar = .current
    ) -> PoolDayLedger {
        var ledger = self
        for pool in snapshot.accounts where pool.isPool {
            ledger.pools[pool.id] = PoolDay.updated(
                pools[pool.id], pool: pool, at: now, calendar: calendar)
        }
        return ledger
    }

    /// Whether today's entry for `pool` starts at midnight. False when there
    /// is no entry for today yet.
    public func coversToday(_ pool: String, at now: Date, calendar: Calendar = .current) -> Bool {
        guard let day = pools[pool], day.day == PoolDay.dayKey(now, calendar: calendar) else { return false }
        return day.coversDay
    }

    /// The ledger with today's entry for `pool` rebuilt from logged readings.
    ///
    /// Each login's baseline is its latest logged reading at or before midnight,
    /// up to 12 hours back. Readings after midnight are then replayed in order,
    /// so a weekly reset inside the day counts as it does live. Apply the current
    /// snapshot after this with `updated(with:at:)`.
    public func backfilled(
        _ pool: String, from readings: [LoggedReading], at now: Date, calendar: Calendar = .current
    ) -> PoolDayLedger {
        guard !readings.isEmpty else { return self }
        var ledger = self
        ledger.pools[pool] = PoolDay.rebuilt(
            pools[pool], pool: pool, from: readings, at: now, calendar: calendar)
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
    /// Local midnight when every login has a baseline from at or before it.
    /// Otherwise the latest baseline time: the burn before it is not counted.
    public var since: Date
    /// `since` as local `HH:mm`, for a status line that has no date library.
    public var sinceLocal: String
    /// Whether every login's baseline is at most 15 minutes after midnight.
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
    /// How far before midnight a reading still serves as the day's baseline.
    static let carryWindow: TimeInterval = 30 * 60
    /// How far before midnight a logged reading still serves as a baseline.
    static let logLookback: TimeInterval = 12 * 3600

    static func updated(
        _ earlier: PoolDay?, pool: UsageAccount, at now: Date, calendar: Calendar
    ) -> PoolDay {
        let today = dayKey(now, calendar: calendar)
        var logins = earlier?.day == today
            ? earlier?.logins ?? [:]
            : carried(earlier, before: calendar.startOfDay(for: now))
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
            logins[member.id] = logins[member.id]?.reading(week, at: readAt) ?? LoginDay(first: week, at: readAt)
        }
        return summary(
            day: today, logins: logins, memberCount: members.count, missing: missing,
            at: now, calendar: calendar)
    }

    /// Today's entry rebuilt from logged readings. Membership and missing logins
    /// stay as the earlier entry had them, until the next snapshot sets them.
    static func rebuilt(
        _ earlier: PoolDay?, pool: String, from readings: [LoggedReading], at now: Date, calendar: Calendar
    ) -> PoolDay {
        let midnight = calendar.startOfDay(for: now)
        let ordered = readings.sorted { $0.at < $1.at }
        var logins: [String: LoginDay] = [:]
        for entry in ordered where entry.at <= midnight && entry.at >= midnight - logLookback {
            logins[entry.login(in: pool)] = LoginDay(first: entry.week, at: entry.at)
        }
        for entry in ordered where entry.at > midnight && entry.at <= now {
            let id = entry.login(in: pool)
            logins[id] = logins[id]?.reading(entry.week, at: entry.at) ?? LoginDay(first: entry.week, at: entry.at)
        }
        return summary(
            day: dayKey(now, calendar: calendar), logins: logins,
            memberCount: earlier?.memberCount ?? logins.count, missing: earlier?.missing ?? [],
            at: now, calendar: calendar)
    }

    /// The logins whose last reading of the previous day fell in the half hour
    /// before midnight. That reading becomes today's baseline.
    static func carried(_ earlier: PoolDay?, before midnight: Date) -> [String: LoginDay] {
        guard let earlier else { return [:] }
        return earlier.logins.compactMapValues { login in
            guard login.lastAt <= midnight, login.lastAt >= midnight - carryWindow else { return nil }
            return login.carriedOver()
        }
    }

    static func summary(
        day: String, logins: [String: LoginDay], memberCount: Int, missing: [String],
        at now: Date, calendar: Calendar
    ) -> PoolDay {
        let midnight = calendar.startOfDay(for: now)
        let latestStart = logins.values.map { $0.baselineAt ?? now }.max() ?? now
        let coversDay = !logins.isEmpty && latestStart <= midnight + coverSlack
        let since = coversDay ? midnight : latestStart
        return PoolDay(
            day: day,
            since: since,
            sinceLocal: localTime(since, calendar: calendar),
            coversDay: coversDay,
            updatedAt: now,
            memberCount: memberCount,
            breakEvenAccountsPerDay: Double(memberCount) / PoolDayLedger.windowDays,
            accountsBurned: logins.values.reduce(0) { $0 + $1.burned },
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
    /// When the baseline reading was taken. Nil in a ledger written before
    /// this field existed.
    public var baselineAt: Date?
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
        baselineAt = date
        last = fraction
        lastAt = date
        resetsAt = week.resetsAt
        earlierWindows = 0
    }

    /// The login at the start of a new day: its last reading is the baseline.
    func carriedOver() -> LoginDay {
        var next = self
        next.baseline = last
        next.baselineAt = lastAt
        next.earlierWindows = 0
        return next
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

/// One login's weekly reading from a log line, such as the `aiusage proxy-steer`
/// log that an always-on machine writes every few minutes.
public struct LoggedReading: Sendable, Equatable {
    public let at: Date
    public let email: String
    public let week: UsageWindow

    public init(at: Date, email: String, week: UsageWindow) {
        self.at = at
        self.email = email
        self.week = week
    }

    /// The pool member id the daemon uses for this login, for example `cc3/a@b.com`.
    func login(in pool: String) -> String { "\(pool)/\(email)" }

    /// The weekly readings in a proxy-steer log. A line reads
    /// `<ISO time> <email> keep 1: weekly 100% used` or
    /// `<ISO time> <email> weight 24: weekly 53% free, reset in 67.9h, ...`.
    /// Any other line, such as a 5-hour gate or a failed read, carries no weekly
    /// figure and is skipped.
    public static func parseProxySteerLog(_ text: String) -> [LoggedReading] {
        let iso = ISO8601DateFormatter()
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count == 3, let at = iso.date(from: String(parts[0])),
                  let colon = parts[2].range(of: ": ") else { return nil }
            let reason = parts[2][colon.upperBound...]
            if let used = match(reason, #"^weekly (\d+)% used"#)?.first.flatMap(Double.init) {
                return LoggedReading(at: at, email: String(parts[1]),
                                     week: UsageWindow(label: "7d", usedFraction: used / 100))
            }
            if let groups = match(reason, #"^weekly (\d+)% free, reset in ([\d.]+)h"#), groups.count == 2,
               let free = Double(groups[0]), let hours = Double(groups[1]) {
                return LoggedReading(at: at, email: String(parts[1]), week: UsageWindow(
                    label: "7d", usedFraction: 1 - free / 100, resetsAt: at.addingTimeInterval(hours * 3600)))
            }
            return nil
        }
    }

    private static func match(_ text: Substring, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let string = String(text)
        guard let found = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string))
        else { return nil }
        return (1..<found.numberOfRanges).compactMap { index in
            Range(found.range(at: index), in: string).map { String(string[$0]) }
        }
    }
}
