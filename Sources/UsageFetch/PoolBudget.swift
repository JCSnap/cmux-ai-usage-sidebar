import Foundation

/// How much of a pool to use, given what each login has left and when it resets.
///
/// Logins reset on their own schedule, one week apart. Two limits follow:
///
/// - The floor: quota that resets unused is lost. For each upcoming reset time
///   T, the logins that reset by T hold some quota. That quota must be used
///   before T. The floor is the largest of these amounts per hour.
/// - The ceiling: the pool must not run dry. By any time T in the next week,
///   the pool can use what is left now plus one account for each reset before
///   T. The ceiling is the smallest of these amounts per hour.
///
/// Rates are in accounts per day. Pure math: no clock, no file.
public struct PoolBudget: Sendable, Equatable {
    /// The use-it-or-lose-it rate, in accounts per day. Zero when no login resets.
    public var floorAccountsPerDay: Double
    /// The quota that resets unused at `floorDeadline` unless it is used first.
    public var floorAccounts: Double
    /// The reset time that sets the floor. Nil when no login has a reset time.
    public var floorDeadline: Date?
    /// The fastest rate that does not run the pool dry, in accounts per day.
    public var ceilingAccountsPerDay: Double
    /// The time at which the ceiling rate leaves the pool empty.
    public var ceilingDeadline: Date

    /// One login's weekly window now.
    public struct Login: Sendable, Equatable {
        /// The weekly fraction not used yet, from 0 to 1.
        public var remaining: Double
        /// When the weekly window resets. Nil when the vendor sends no time.
        public var resetsAt: Date?

        public init(remaining: Double, resetsAt: Date?) {
            self.remaining = remaining
            self.resetsAt = resetsAt
        }
    }

    /// The ceiling looks this far ahead. Each login resets once in this span.
    public static let horizon: TimeInterval = PoolDayLedger.windowDays * 86_400
    static let day: TimeInterval = 86_400

    /// The floor and ceiling at `now`. Nil when there is no login.
    ///
    /// A reset time in the past means the login reset and no reading shows it
    /// yet. It then counts as a full account that resets one week later.
    public static func compute(_ logins: [Login], at now: Date) -> PoolBudget? {
        guard !logins.isEmpty else { return nil }
        let current = logins.map { login -> Login in
            let left = max(0, min(1, login.remaining))
            guard var reset = login.resetsAt, reset <= now else { return Login(remaining: left, resetsAt: login.resetsAt) }
            while reset <= now { reset += horizon }
            return Login(remaining: 1, resetsAt: reset)
        }
        let resets = Set(current.compactMap(\.resetsAt)).sorted()

        var floor = (rate: 0.0, amount: 0.0, deadline: Date?.none)
        for deadline in resets {
            let amount = current.filter { $0.resetsAt.map { $0 <= deadline } ?? false }.reduce(0) { $0 + $1.remaining }
            let rate = amount / (deadline.timeIntervalSince(now) / day)
            if rate > floor.rate { floor = (rate, amount, deadline) }
        }

        let leftNow = current.reduce(0) { $0 + $1.remaining }
        let end = now + horizon
        var ceiling = (rate: Double.infinity, deadline: end)
        for deadline in resets.filter({ $0 < end }) + [end] {
            // A reset exactly at the deadline adds nothing before it.
            let refills = Double(current.filter { $0.resetsAt.map { $0 < deadline } ?? false }.count)
            let rate = (leftNow + refills) / (deadline.timeIntervalSince(now) / day)
            if rate < ceiling.rate { ceiling = (rate, deadline) }
        }

        return PoolBudget(
            floorAccountsPerDay: floor.rate, floorAccounts: floor.amount, floorDeadline: floor.deadline,
            ceilingAccountsPerDay: ceiling.rate, ceilingDeadline: ceiling.deadline)
    }

    /// The burn rate over the last `window`, in accounts per day.
    ///
    /// `samples` hold the pool's running total burn, oldest first. The rate
    /// starts at the latest sample at or before `now - window`, or at the oldest
    /// sample when none is that old. Nil when the samples span less than
    /// `minimumSpan`, because a few minutes of burn say little about a day.
    public static func pace(
        _ samples: [BurnSample], at now: Date, window: TimeInterval = paceWindow,
        minimumSpan: TimeInterval = 3600
    ) -> Double? {
        guard let last = samples.last,
              let first = samples.last(where: { $0.at <= now - window }) ?? samples.first
        else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= minimumSpan else { return nil }
        return max(0, last.total - first.total) / (span / day)
    }

    /// The span the pace looks back over.
    public static let paceWindow: TimeInterval = 6 * 3600
}

/// The pool's running total burn at one time, in accounts. The total only
/// rises. It carries across midnight, so a pace can span two days.
public struct BurnSample: Codable, Sendable, Equatable {
    public var at: Date
    public var total: Double

    public init(at: Date, total: Double) {
        self.at = at
        self.total = total
    }
}
