import Foundation
import UsageModels

/// Plans and applies routing weights for one CLIProxyAPI pool.
///
/// The input is the daemon snapshot. This never calls a provider API and
/// never reads a token. It sets weights with the proxy's management API,
/// `PATCH /v0/management/auth-files/fields`. The proxy then updates the login
/// in memory and saves the auth file itself, so a token refresh can never
/// race with this edit.
public enum ProxySteer {
    /// A snapshot older than this changes nothing.
    public static let maxSnapshotAge: TimeInterval = 15 * 60

    /// One pooled login, as listed by `GET /v0/management/auth-files`.
    public struct AuthEntry: Equatable, Sendable {
        /// The auth file name. The PATCH call names the login with it.
        public let name: String
        public let provider: String
        public let email: String?
        public let disabled: Bool
        /// Set only when the proxy version lists it.
        public let weight: Int?

        public init(name: String, provider: String, email: String?, disabled: Bool = false, weight: Int? = nil) {
            self.name = name
            self.provider = provider
            self.email = email
            self.disabled = disabled
            self.weight = weight
        }
    }

    public struct Row: Equatable, Sendable {
        public let email: String
        /// The auth file name, or nil when the proxy holds no matching login.
        public let name: String?
        public let currentWeight: Int?
        /// Nil when the login is left as it is.
        public let newWeight: Int?
        public let reason: String

        /// Whether a PATCH is needed. A listed weight that already matches is skipped.
        public var needsUpdate: Bool { name != nil && newWeight != nil && newWeight != currentWeight }
    }

    public enum PlanError: Error, Equatable, CustomStringConvertible {
        case staleSnapshot(ageSeconds: Int)
        case noPool(String)

        public var description: String {
            switch self {
            case .staleSnapshot(let age): "snapshot is \(age / 60)m old (limit \(Int(maxSnapshotAge / 60))m); no change"
            case .noPool(let id): "snapshot has no pool \(id) with members; no change"
            }
        }
    }

    /// One row per pool member, matched to a login of the pool's provider by
    /// email. A member with no login, or no fresh reading, gets no new weight.
    public static func plan(
        snapshot: UsageSnapshot, poolID: String, entries: [AuthEntry], now: Date
    ) throws -> [Row] {
        let age = now.timeIntervalSince(snapshot.generatedAt)
        guard age <= maxSnapshotAge else { throw PlanError.staleSnapshot(ageSeconds: Int(age)) }
        guard let pool = snapshot.accounts.first(where: { $0.id == poolID }), pool.isPool,
              let members = pool.members
        else { throw PlanError.noPool(poolID) }

        let byEmail = Dictionary(
            entries
                .filter { $0.provider == pool.provider.rawValue && !$0.disabled }
                .compactMap { entry in entry.email.map { ($0.lowercased(), entry) } },
            uniquingKeysWith: { first, _ in first })
        return members.map { member in
            let email = member.email ?? member.displayName
            guard let entry = byEmail[email.lowercased()] else {
                return Row(email: email, name: nil, currentWeight: nil, newWeight: nil, reason: "no proxy login")
            }
            switch SteerWeight.decide(member, now: now) {
            case .weight(let weight, let reason):
                return Row(email: email, name: entry.name, currentWeight: entry.weight, newWeight: weight, reason: reason)
            case .keep(let reason):
                return Row(email: email, name: entry.name, currentWeight: entry.weight, newWeight: nil, reason: reason)
            }
        }
    }

    // MARK: - Management API

    /// Parses the `auth-files` listing. Reads only names, emails and weights.
    public static func authEntries(fromListing data: Data) -> [AuthEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = root["files"] as? [[String: Any]]
        else { return [] }
        return files.compactMap { file in
            guard let name = file["name"] as? String, let provider = file["provider"] as? String else {
                return nil
            }
            return AuthEntry(
                name: name, provider: provider, email: file["email"] as? String,
                disabled: file["disabled"] as? Bool ?? false,
                weight: (file["weight"] as? NSNumber)?.intValue)
        }
    }

    public static func listRequest(base: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(base)/v0/management/auth-files")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    /// Sets one top-level field, `weight`, on one login. The body names no other field.
    public static func weightRequest(base: String, key: String, name: String, weight: Int) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(base)/v0/management/auth-files/fields")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["name": name, "weight": weight], options: [.sortedKeys])
        return request
    }

    // MARK: - Output

    /// A fixed-width table of the plan. Shows emails and weights only.
    public static func table(_ rows: [Row]) -> String {
        let width = max(5, rows.map(\.email.count).max() ?? 0)
        func pad(_ text: String, _ count: Int) -> String {
            text.count >= count ? text : text + String(repeating: " ", count: count - text.count)
        }
        var lines = ["\(pad("EMAIL", width))  \(pad("NOW", 5))  \(pad("NEW", 5))  WHY"]
        for row in rows {
            let current = row.currentWeight.map(String.init) ?? "-"
            let new = row.newWeight.map(String.init) ?? "keep"
            lines.append("\(pad(row.email, width))  \(pad(current, 5))  \(pad(new, 5))  \(row.reason)")
        }
        return lines.joined(separator: "\n")
    }
}
