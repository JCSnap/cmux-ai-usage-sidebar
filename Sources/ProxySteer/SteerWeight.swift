import Foundation
import UsageModels

/// The CLIProxyAPI routing weight for one pooled login.
///
/// Under `weighted-round-robin` the proxy sends each login a share of new
/// sessions in proportion to its weight. The rule favours a login that has
/// headroom left and resets soon, because headroom that is not spent before a
/// reset is lost.
///
/// Both bases share these steps:
/// - A login that answered HTTP 429 (cooling down) gets `minWeight`.
/// - Any other login without a fresh reading keeps its current weight.
/// - The weight is clamped to `minWeight...maxWeight`.
public enum SteerWeight {
    /// Which window drives the weight.
    public enum Basis: String, CaseIterable, Sendable {
        /// Earliest deadline first. The login whose weekly window resets
        /// soonest gets most new sessions. See `decideEDF`.
        case edf
        /// The weekly window drives the weight. The 5-hour window only gates it.
        /// See `decideWeekly`.
        case weekly
        /// The fullest window and the soonest reset drive the weight.
        /// See `decideTightest`.
        case tightest
    }

    public static let minWeight = 1
    public static let maxWeight = 1000

    /// What the rule decided for one login.
    public enum Decision: Equatable, Sendable {
        /// Set this weight.
        case weight(Int, reason: String)
        /// Leave the file as it is.
        case keep(reason: String)
    }

    /// One decision per member, in order. The `edf` basis compares members,
    /// so it needs the whole pool. The other bases decide each member alone.
    public static func decide(_ members: [UsageAccount], now: Date, basis: Basis = .edf) -> [Decision] {
        guard basis == .edf else { return members.map { decide($0, now: now, basis: basis) } }
        let readings = members.map { edfReading($0, now: now) }
        let earliest = readings.compactMap { reading -> Double? in
            if case .candidate(let candidate) = reading { return candidate.hours }
            return nil
        }.min()
        return readings.map { reading in
            switch reading {
            case .decided(let decision): decision
            case .candidate(let candidate): decideEDF(candidate, earliestHours: earliest ?? candidate.hours)
            }
        }
    }

    /// The decision for one member. The `edf` basis sees a pool of one, so the
    /// member is its own earliest deadline.
    public static func decide(_ member: UsageAccount, now: Date, basis: Basis = .edf) -> Decision {
        if basis == .edf { return decide([member], now: now, basis: .edf)[0] }
        if let early = unreadable(member) { return early }
        guard !member.windows.isEmpty else { return .keep(reason: "no windows") }
        switch basis {
        case .tightest, .edf:
            return decideTightest(member.windows, now: now)
        case .weekly:
            // A team seat reports no weekly window. Its 5-hour window is all it has.
            guard let weekly = member.windows.first(where: { $0.label == weeklyLabel }) else {
                return decideTightest(member.windows, now: now)
            }
            return decideWeekly(
                weekly: weekly, fiveHour: member.windows.first(where: { $0.label == fiveHourLabel }), now: now)
        }
    }

    /// The decision for a member without a fresh reading, or nil when it has one.
    static func unreadable(_ member: UsageAccount) -> Decision? {
        switch member.state {
        case .ok:
            return nil
        case .error where isCoolingDown(member):
            return .weight(minWeight, reason: "cooling down")
        default:
            return .keep(reason: "no fresh reading (\(member.state.rawValue))")
        }
    }

    // MARK: - Earliest deadline first

    /// Under `edf` a 5-hour window this full gets `minWeight`. It is lower than
    /// `fiveHourGate`: the top login takes most new sessions, and the sessions
    /// already bound to it need room to finish without a 429.
    public static let edfFiveHourGate = 0.75
    /// The weight falls with `(earliest hours / hours) ^ edfExponent`. With 3, a
    /// login that resets a day after the earliest one at 30h gets 1/6 of its
    /// weight. Two logins that reset an hour apart get almost the same weight.
    public static let edfExponent = 3.0

    /// A member that passed the gates, waiting for the pool's earliest deadline.
    struct EDFCandidate {
        let free: Double
        let fiveUsed: Double
        let hours: Double
    }

    enum EDFReading {
        case decided(Decision)
        case candidate(EDFCandidate)
    }

    static func edfReading(_ member: UsageAccount, now: Date) -> EDFReading {
        if let early = unreadable(member) { return .decided(early) }
        guard !member.windows.isEmpty else { return .decided(.keep(reason: "no windows")) }
        // A team seat reports no weekly window. Its 5-hour window is all it has.
        guard let weekly = member.windows.first(where: { $0.label == weeklyLabel }) else {
            return .decided(decideTightest(member.windows, now: now))
        }
        let used = clamp01(weekly.usedFraction)
        if used >= weeklyFullFraction {
            return .decided(.weight(minWeight, reason: "weekly \(percent(used)) used"))
        }
        let fiveUsed = member.windows.first(where: { $0.label == fiveHourLabel }).map { clamp01($0.usedFraction) } ?? 0
        if fiveUsed >= edfFiveHourGate {
            return .decided(.weight(minWeight, reason: "5h \(percent(fiveUsed)) used"))
        }
        // No reset time means no deadline. Treat it as a full week away.
        let toReset = weekly.resetsAt.map { $0.timeIntervalSince(now) / 3600 } ?? weekHours
        return .candidate(EDFCandidate(free: 1 - used, fiveUsed: fiveUsed, hours: max(weeklyMinHours, toReset)))
    }

    /// Earliest-deadline-first rule. Weekly headroom resets unused unless it is
    /// spent before its reset, so the login that resets first is spent first.
    /// 1. Gates: weekly `weeklyFullFraction` or more used, or 5-hour
    ///    `edfFiveHourGate` or more used, gets `minWeight`.
    /// 2. `hours` is the time to the weekly reset, at least `weeklyMinHours`.
    ///    `earliest` is the smallest `hours` of the members that passed the gates.
    /// 3. `weight = maxWeight * free * (earliest / hours) ^ edfExponent * fiveFactor`,
    ///    with `fiveFactor = (edfFiveHourGate - used) / edfFiveHourGate`, clamped.
    ///    The weekly free share scales the weight down near the weekly limit.
    ///    The 5-hour factor moves new sessions to the next login as the top
    ///    login fills its 5-hour window.
    static func decideEDF(_ candidate: EDFCandidate, earliestHours: Double) -> Decision {
        let deadline = pow(earliestHours / candidate.hours, edfExponent)
        let fiveFactor = (edfFiveHourGate - candidate.fiveUsed) / edfFiveHourGate
        let raw = Int((Double(maxWeight) * candidate.free * deadline * fiveFactor).rounded())
        let weight = min(maxWeight, max(minWeight, raw))
        let reason = String(
            format: "weekly %.0f%% free, reset in %.1fh (earliest %.1fh), 5h %@ used",
            candidate.free * 100, candidate.hours, earliestHours, percent(candidate.fiveUsed))
        return .weight(weight, reason: reason)
    }

    // MARK: - Weekly basis

    static let weeklyLabel = "7d"
    static let fiveHourLabel = "5h"
    /// A weekly window this full counts as spent.
    public static let weeklyFullFraction = 0.95
    /// A 5-hour window this full gets `minWeight`, so the login can recover.
    public static let fiveHourGate = 0.90
    /// Floor on the hours until the weekly reset.
    public static let weeklyMinHours = 5.0
    /// Maps weekly headroom per hour to a weight. A fully free login 5 hours
    /// from its weekly reset reaches `maxWeight`: 5000 * 1 / 5 = 1000.
    public static let weeklyScale = 5000.0
    public static let weekHours = 168.0
    /// The burn rate is trusted only after this much of the week has passed.
    public static let minElapsedHours = 24.0

    /// Weekly rule:
    /// 1. `urgency = weekly free fraction / hours to weekly reset` (at least `weeklyMinHours`).
    /// 2. The 5-hour window is a gate. At `fiveHourGate` or more used, the login
    ///    gets `minWeight`. Otherwise the weight is multiplied by
    ///    `(fiveHourGate - used) / fiveHourGate`, which falls to 0 at the gate.
    /// 3. Burn damping. The week-to-date burn rate is `used / hours elapsed`.
    ///    If that rate would spend the free fraction before the reset, the
    ///    weight is multiplied by `free / projected use`. That headroom gets
    ///    spent anyway, so it is less urgent.
    /// 4. `weight = round(weeklyScale * urgency * factors)`, clamped.
    static func decideWeekly(weekly: UsageWindow, fiveHour: UsageWindow?, now: Date) -> Decision {
        let used = clamp01(weekly.usedFraction)
        if used >= weeklyFullFraction {
            return .weight(minWeight, reason: "weekly \(percent(used)) used")
        }
        let fiveUsed = fiveHour.map { clamp01($0.usedFraction) } ?? 0
        if fiveUsed >= fiveHourGate {
            return .weight(minWeight, reason: "5h \(percent(fiveUsed)) used")
        }
        let free = 1 - used
        // No reset time means no deadline. Treat it as a full week away.
        let toReset = weekly.resetsAt.map { $0.timeIntervalSince(now) / 3600 } ?? weekHours
        let hours = max(weeklyMinHours, toReset)
        let fiveFactor = (fiveHourGate - fiveUsed) / fiveHourGate

        var burnFactor = 1.0
        let elapsed = weekHours - min(weekHours, max(0, toReset))
        if elapsed >= minElapsedHours {
            let projected = used / elapsed * hours
            if projected > free { burnFactor = free / projected }
        }

        let raw = Int((weeklyScale * free / hours * fiveFactor * burnFactor).rounded())
        let weight = min(maxWeight, max(minWeight, raw))
        var reason = String(format: "weekly %.0f%% free, reset in %.1fh, 5h %@ used", free * 100, hours, percent(fiveUsed))
        if burnFactor < 1 { reason += String(format: ", burn x%.2f", burnFactor) }
        return .weight(weight, reason: reason)
    }

    // MARK: - Tightest basis

    /// A window this full counts as spent.
    public static let fullFraction = 0.95
    /// Floor on the hours until reset, so a reset a minute away does not
    /// divide by almost zero.
    public static let minHours = 0.25
    /// Maps headroom per hour to a weight. With the 15-minute floor, a fully
    /// free login reaches `maxWeight`: 250 * 1 / 0.25 = 1000.
    public static let scale = 250.0

    /// Tightest rule:
    /// 1. `headroom` is the free fraction of the tightest window, `1 - max(usedFraction)`.
    /// 2. `hours` is the time until the soonest window reset, at least `minHours`.
    /// 3. `weight = round(scale * headroom / hours)`, clamped.
    /// 4. A login at `fullFraction` or more of any window gets `minWeight`.
    static func decideTightest(_ windows: [UsageWindow], now: Date) -> Decision {
        let used = windows.map { clamp01($0.usedFraction) }.max() ?? 0
        if used >= fullFraction {
            return .weight(minWeight, reason: "\(percent(used)) used")
        }
        let headroom = 1 - used
        let resets = windows.compactMap(\.resetsAt)
        // No reset time means no deadline. Treat the longest window we know of
        // as a week away, so the login still gets a small share.
        let seconds = resets.map { $0.timeIntervalSince(now) }.min() ?? 7 * 86_400
        let hours = max(minHours, seconds / 3600)
        let raw = Int((scale * headroom / hours).rounded())
        let weight = min(maxWeight, max(minWeight, raw))
        return .weight(weight, reason: String(format: "%.0f%% free, reset in %.1fh", headroom * 100, hours))
    }

    // MARK: - Helpers

    static func clamp01(_ value: Double) -> Double { max(0, min(1, value)) }
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// The daemon marks a login it could not read because of a 429 with an
    /// error detail that names the rate limit.
    static func isCoolingDown(_ member: UsageAccount) -> Bool {
        let detail = (member.detail ?? "").lowercased()
        return detail.contains("429") || detail.contains("rate limited") || detail.contains("cooling down")
    }
}
