import Foundation
import UsageModels

/// Reads a CLIProxyAPI pool: every login of one provider that the proxy holds.
///
/// The proxy owns these tokens and rotates them. A refresh from this daemon
/// would log the proxy out, because refresh tokens are single use. So the
/// tokens are never read here. The management API's `api-call` relay sends the
/// vendor request with `$TOKEN$` replaced on the proxy side. The proxy's own
/// quota dashboard reads usage the same way.
///
/// Each pooled login is metered on its own vendor endpoint. The reading carries
/// them as `members`, and the collector derives the pool's bars from them.
struct CLIProxyClient: UsageProviderClient {
    /// Providers whose usage endpoint a pooled login can be relayed to.
    static let supportedProviders: [UsageProvider] = [.claude, .codex]
    static let defaultKeyFile = "~/.cli-proxy-api/management-key"
    /// Cooldown after a 429 that names no usable `Retry-After`.
    static let defaultCooldown: TimeInterval = 300

    typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// The proxy is on loopback, so a failed call is not retried here. A
    /// relayed vendor 429 is answered with a cooldown instead.
    var send: Send = { try await Http.once($0) }
    var cooldowns: CooldownTracker = .shared
    var now: @Sendable () -> Date = { Date() }

    /// One pooled login, as listed by `GET /v0/management/auth-files`.
    struct AuthEntry: Equatable {
        let authIndex: String
        let provider: String
        let email: String?
        let disabled: Bool
        /// Codex only: the ChatGPT workspace the usage endpoint must name.
        let chatgptAccountID: String?
        let plan: String?

        /// The mailbox name reads well in a narrow sidebar. The domain is
        /// usually the same for every login in a pool.
        var displayName: String {
            guard let email, let local = email.split(separator: "@").first else { return authIndex }
            return String(local)
        }
    }

    func fetch(_ account: AccountConfig) async throws -> ProviderReading {
        guard let base = account.cliProxyURL else { throw FetchError.noCredential }
        let keyPath = (account.cliProxyKeyFile ?? Self.defaultKeyFile).expandedPath
        guard let key = try? String(contentsOfFile: keyPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { throw FetchError.noCredential }

        let entries = try await authEntries(base: base, key: key)
            .filter { $0.provider == account.provider.rawValue && !$0.disabled }
        guard !entries.isEmpty else { throw FetchError.noCredential }

        // One login at a time. Each has its own vendor budget, but a burst of
        // relayed calls still lands on the proxy's single upstream connection.
        var members: [UsageAccount] = []
        for entry in entries {
            members.append(await member(entry, pool: account, base: base, key: key))
        }
        return ProviderReading(windows: [], members: members)
    }

    // MARK: - Pool arithmetic

    /// The pool's bars: for each window, the mean of the members that report
    /// it. The proxy spreads traffic across the pool, so the mean is the share
    /// of the pool's capacity in use. The reset is the earliest one, because
    /// that is when the pool next gains headroom.
    static func pooledWindows(_ members: [UsageAccount]) -> [UsageWindow] {
        var order: [String] = []
        var buckets: [String: [UsageWindow]] = [:]
        for member in members where member.showsWindows {
            for window in member.windows {
                if buckets[window.id] == nil { order.append(window.id) }
                buckets[window.id, default: []].append(window)
            }
        }
        return order.compactMap { id in
            guard let windows = buckets[id], let first = windows.first else { return nil }
            let mean = windows.map(\.usedFraction).reduce(0, +) / Double(windows.count)
            return UsageWindow(
                group: first.group, label: first.label, usedFraction: mean,
                resetsAt: windows.compactMap(\.resetsAt).min())
        }
    }

    /// A plan shared by every member describes the pool. Mixed plans do not.
    static func pooledPlan(_ members: [UsageAccount]) -> String? {
        let plans = Set(members.map(\.plan))
        guard plans.count == 1, let plan = plans.first else { return nil }
        return plan
    }

    // MARK: - Management API

    func authEntries(base: String, key: String) async throws -> [AuthEntry] {
        let request = Http.get(
            "\(base)/v0/management/auth-files", headers: ["Authorization": "Bearer \(key)"])
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw FetchError.badStatus(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.badPayload("auth-files is not a JSON object")
        }
        return Self.authEntries(in: root)
    }

    static func authEntries(in root: [String: Any]) -> [AuthEntry] {
        let files = root["files"] as? [[String: Any]] ?? []
        return files.compactMap { file in
            guard let index = file.string("auth_index"), let provider = file.string("provider")
            else { return nil }
            let idToken = file.dict("id_token")
            return AuthEntry(
                authIndex: index,
                provider: provider,
                email: file.string("email"),
                disabled: file["disabled"] as? Bool ?? false,
                chatgptAccountID: idToken?.string("chatgpt_account_id"),
                plan: idToken?.string("plan_type"))
        }
    }

    /// The vendor usage request for one login, with `$TOKEN$` where the proxy
    /// puts the access token. Built by the direct clients, so the relayed call
    /// is the same request a local login sends.
    static func usageRequest(for entry: AuthEntry) -> URLRequest? {
        switch entry.provider {
        case UsageProvider.claude.rawValue:
            return Http.get(ClaudeClient.usageURL, headers: ClaudeClient.usageHeaders(token: "$TOKEN$"))
        case UsageProvider.codex.rawValue:
            guard let accountID = entry.chatgptAccountID else { return nil }
            return CodexClient.usageRequest(accessToken: "$TOKEN$", accountID: accountID)
        default:
            return nil
        }
    }

    /// Wraps a vendor request in a `POST /v0/management/api-call`.
    static func relayRequest(
        _ upstream: URLRequest, authIndex: String, base: String, key: String
    ) -> URLRequest {
        var request = Http.jsonPost(
            "\(base)/v0/management/api-call",
            object: [
                "auth_index": authIndex,
                "method": upstream.httpMethod ?? "GET",
                "url": upstream.url?.absoluteString ?? "",
                "header": upstream.allHTTPHeaderFields ?? [:],
            ])
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// What the relay reports about the vendor call it made.
    struct Relayed {
        let status: Int
        let retryAfter: String?
        let body: Data
    }

    static func relayed(from data: Data) throws -> Relayed {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root.int("status_code")
        else { throw FetchError.badPayload("api-call reply has no status_code") }
        // Header values arrive as Go's `map[string][]string`.
        let headers = root.dict("header") ?? [:]
        let retryAfter = headers.first { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame }
            .flatMap { ($0.value as? [String])?.first ?? $0.value as? String }
        return Relayed(
            status: status, retryAfter: retryAfter, body: Data((root.string("body") ?? "").utf8))
    }

    // MARK: - One member

    private func member(
        _ entry: AuthEntry, pool: AccountConfig, base: String, key: String
    ) async -> UsageAccount {
        let id = "\(pool.id)/\(entry.email ?? entry.authIndex)"
        func failure(_ detail: String) -> UsageAccount {
            UsageAccount(
                id: id, provider: pool.provider, displayName: entry.displayName,
                plan: entry.plan, email: entry.email, state: .error, detail: detail)
        }

        let (blocked, remaining) = await cooldowns.isBlocked(id)
        if blocked {
            return failure("rate limited, cooling down for ~\(Int(ceil(remaining / 60)))m")
        }
        guard let upstream = Self.usageRequest(for: entry) else {
            return failure("no usage endpoint for this login")
        }

        do {
            let request = Self.relayRequest(upstream, authIndex: entry.authIndex, base: base, key: key)
            let (data, response) = try await send(request)
            guard (200..<300).contains(response.statusCode) else {
                return failure("proxy HTTP \(response.statusCode)")
            }
            let relayed = try Self.relayed(from: data)
            if relayed.status == 429 {
                // Polling again inside the vendor's window extends it. A zero
                // or missing Retry-After is not an invitation to call again.
                let named = relayed.retryAfter.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
                await cooldowns.block(id, for: (named ?? 0) > 0 ? named! : Self.defaultCooldown)
                return failure("HTTP 429: rate limited")
            }
            guard (200..<300).contains(relayed.status) else {
                return failure(FetchError.badStatus(
                    relayed.status, String(decoding: relayed.body, as: UTF8.self)).localizedDescription)
            }
            await cooldowns.clear(id)
            guard let payload = try JSONSerialization.jsonObject(with: relayed.body) as? [String: Any]
            else { return failure("unexpected payload: not a JSON object") }
            let reading = pool.provider == .codex
                ? try CodexClient.reading(from: payload)
                : try ClaudeClient.reading(from: payload)
            return UsageAccount(
                id: id, provider: pool.provider, displayName: entry.displayName,
                plan: entry.plan ?? reading.plan, email: entry.email ?? reading.email,
                state: .ok, windows: reading.windows, updatedAt: now())
        } catch {
            return failure(error.localizedDescription)
        }
    }
}
