import Foundation
import UsageModels

/// The CLIProxyAPI routing weight for one pooled login.
///
/// Under `weighted-round-robin` the proxy sends each login a share of new
/// sessions in proportion to its weight. The rule favours a login that has
/// headroom left and resets soon, because headroom that is not spent before a
/// reset is lost.
///
/// Rule:
/// 1. `headroom` is the free fraction of the tightest window, `1 - max(usedFraction)`.
/// 2. `hours` is the time until the soonest window reset, at least `minHours`.
/// 3. `weight = round(scale * headroom / hours)`, clamped to `minWeight...maxWeight`.
/// 4. A login at `fullFraction` or more of any window gets `minWeight`.
/// 5. A login that answered HTTP 429 (cooling down) gets `minWeight`.
/// 6. Any other login without a fresh reading keeps its current weight.
public enum SteerWeight {
    public static let minWeight = 1
    public static let maxWeight = 1000
    /// A window this full counts as spent.
    public static let fullFraction = 0.95
    /// Floor on the hours until reset, so a reset a minute away does not
    /// divide by almost zero.
    public static let minHours = 0.25
    /// Maps headroom per hour to a weight. With the 15-minute floor, a fully
    /// free login reaches `maxWeight`: 250 * 1 / 0.25 = 1000.
    public static let scale = 250.0

    /// What the rule decided for one login.
    public enum Decision: Equatable, Sendable {
        /// Set this weight.
        case weight(Int, reason: String)
        /// Leave the file as it is.
        case keep(reason: String)
    }

    public static func decide(_ member: UsageAccount, now: Date) -> Decision {
        switch member.state {
        case .ok:
            break
        case .error where isCoolingDown(member):
            return .weight(minWeight, reason: "cooling down")
        default:
            return .keep(reason: "no fresh reading (\(member.state.rawValue))")
        }
        guard !member.windows.isEmpty else { return .keep(reason: "no windows") }

        let used = member.windows.map { max(0, min(1, $0.usedFraction)) }.max() ?? 0
        if used >= fullFraction {
            return .weight(minWeight, reason: "\(Int((used * 100).rounded()))% used")
        }
        let headroom = 1 - used
        let resets = member.windows.compactMap(\.resetsAt)
        // No reset time means no deadline. Treat the longest window we know of
        // as a week away, so the login still gets a small share.
        let seconds = resets.map { $0.timeIntervalSince(now) }.min() ?? 7 * 86_400
        let hours = max(minHours, seconds / 3600)
        let raw = Int((scale * headroom / hours).rounded())
        let weight = min(maxWeight, max(minWeight, raw))
        return .weight(weight, reason: String(format: "%.0f%% free, reset in %.1fh", headroom * 100, hours))
    }

    /// The daemon marks a login it could not read because of a 429 with an
    /// error detail that names the rate limit.
    static func isCoolingDown(_ member: UsageAccount) -> Bool {
        let detail = (member.detail ?? "").lowercased()
        return detail.contains("429") || detail.contains("rate limited") || detail.contains("cooling down")
    }
}
