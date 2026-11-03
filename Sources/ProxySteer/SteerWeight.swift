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

    public static func decide(_ member: UsageAccount, now: Date, basis: Basis = .weekly) -> Decision {
        switch member.state {
        case .ok:
            break
        case .error where isCoolingDown(member):
            return .weight(minWeight, reason: "cooling down")
        default:
            return .keep(reason: "no fresh reading (\(member.state.rawValue))")
        }
        guard !member.windows.isEmpty else { return .keep(reason: "no windows") }
        switch basis {
        case .tightest:
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
