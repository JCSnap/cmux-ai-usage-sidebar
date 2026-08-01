import Foundation
import UsageModels

/// What one provider read yields. A struct rather than a tuple so each client
/// can omit the fields its API does not return.
struct ProviderReading {
    var plan: String?
    var email: String?
    var windows: [UsageWindow]
}

/// Reads one account. One implementation per agent CLI.
protocol UsageProviderClient: Sendable {
    func fetch(_ account: AccountConfig) async throws -> ProviderReading
}

// MARK: - Claude Code

/// Credential: login keychain, service `Claude Code-credentials[-<suffix>]`.
/// The suffix is derived by Claude Code from a non-default `CLAUDE_CONFIG_DIR`.
struct ClaudeClient: UsageProviderClient {
    func fetch(_ account: AccountConfig) async throws -> ProviderReading {
        guard let service = account.keychainService,
              let blob = Shell.keychainPassword(service: service),
              let object = try? JSONSerialization.jsonObject(with: Data(blob.utf8)),
              let root = object as? [String: Any]
        else { throw FetchError.noCredential }

        // A logged-out profile still has a keychain entry holding only `mcpOAuth`,
        // so the presence of the item is not proof of a login.
        guard let oauth = root.dict("claudeAiOauth"),
              let token = oauth.string("accessToken"), !token.isEmpty
        else { throw FetchError.noCredential }

        let payload = try await Http.json(Http.get(
            "https://api.anthropic.com/api/oauth/usage",
            headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "application/json",
                "anthropic-beta": "oauth-2025-04-20",
            ]))

        func window(_ key: String, _ label: String) -> UsageWindow? {
            guard let block = payload.dict(key) else { return nil }
            return UsageWindow(
                label: label,
                usedFraction: (block.double("utilization") ?? 0) / 100,
                resetsAt: block.string("resets_at").flatMap(Date.fromISO8601))
        }

        let windows = [window("five_hour", "5h"), window("seven_day", "7d")].compactMap { $0 }
        guard !windows.isEmpty else { throw FetchError.badPayload("no usage windows") }
        return ProviderReading(windows: windows)
    }
}

// MARK: - Codex

/// Credential: plain file `$CODEX_HOME/auth.json`. No keychain involved, which
/// is why `CODEX_HOME` alone is enough to separate the two accounts.
struct CodexClient: UsageProviderClient {
    func fetch(_ account: AccountConfig) async throws -> ProviderReading {
        let home = (account.codexHome ?? "~/.codex").expandedPath
        let url = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root.dict("tokens"),
              let token = tokens.string("access_token"), !token.isEmpty
        else { throw FetchError.noCredential }

        let payload = try await Http.json(Http.get(
            "https://chatgpt.com/backend-api/wham/usage",
            headers: [
                "Authorization": "Bearer \(token)",
                "chatgpt-account-id": tokens.string("account_id") ?? "",
                "Accept": "application/json",
            ]))

        guard let limit = payload.dict("rate_limit") else {
            throw FetchError.badPayload("no rate_limit")
        }

        // The window length is reported in seconds and varies per plan, so the
        // label is derived rather than assumed: Plus gets one weekly window,
        // Education gets a 5-hour plus a weekly one.
        func window(_ key: String) -> UsageWindow? {
            guard let block = limit.dict(key) else { return nil }
            let seconds = block.int("limit_window_seconds") ?? 0
            let resetsAt = block.int("reset_at").map {
                Date(timeIntervalSince1970: TimeInterval($0))
            }
            return UsageWindow(
                label: Self.label(forWindowSeconds: seconds),
                usedFraction: (block.double("used_percent") ?? 0) / 100,
                resetsAt: resetsAt)
        }

        let windows = [window("primary_window"), window("secondary_window")].compactMap { $0 }
        guard !windows.isEmpty else { throw FetchError.badPayload("no usage windows") }
        return ProviderReading(
            plan: payload.string("plan_type"), email: payload.string("email"), windows: windows)
    }

    static func label(forWindowSeconds seconds: Int) -> String {
        switch seconds {
        case 0: "—"
        case ..<3600: "\(max(1, seconds / 60))m"
        case ..<86_400: "\(seconds / 3600)h"
        default: "\(seconds / 86_400)d"
        }
    }
}

// MARK: - Antigravity

/// Credential: `<home>/.gemini/antigravity-cli/antigravity-oauth-token`.
/// Note this is not `~/.gemini/oauth_creds.json`, which belongs to gemini-cli
/// and goes stale independently.
struct AntigravityClient: UsageProviderClient {
    /// Extracted from the shipped `agy` binary. The CLI ships this pair itself,
    /// so it is a public client credential, not a user secret.
    static let clientID =
        "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    static let clientSecret = "GOCSPX-REDACTED"

    func fetch(_ account: AccountConfig) async throws -> ProviderReading {
        let home = (account.home ?? "~").expandedPath
        let url = URL(fileURLWithPath: home)
            .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refreshToken = root.dict("token")?.string("refresh_token"),
              !refreshToken.isEmpty
        else { throw FetchError.noCredential }

        // The stored access token is short-lived and is usually already expired,
        // so refresh unconditionally rather than checking the expiry field.
        let refreshed = try await Http.json(Http.form(
            "https://oauth2.googleapis.com/token",
            fields: [
                "client_id": Self.clientID,
                "client_secret": Self.clientSecret,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token",
            ]))
        guard let accessToken = refreshed.string("access_token") else {
            throw FetchError.badPayload("token refresh returned no access_token")
        }

        // This endpoint answers 403 PERMISSION_DENIED unless the User-Agent
        // names the antigravity client. That is client sniffing, not a scope
        // problem, so do not go looking for a missing OAuth scope.
        var request = Http.get(
            "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json",
                "User-Agent": "antigravity-cli",
            ])
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)

        let payload = try await Http.json(request)
        guard let groups = payload["groups"] as? [[String: Any]] else {
            throw FetchError.badPayload("no quota groups")
        }

        let windows: [UsageWindow] = groups.flatMap { group -> [UsageWindow] in
            let name = group.string("displayName") ?? "Models"
            let buckets = group["buckets"] as? [[String: Any]] ?? []
            return buckets.map { bucket in
                UsageWindow(
                    group: name,
                    label: Self.label(forWindow: bucket.string("window")),
                    usedFraction: 1 - (bucket.double("remainingFraction") ?? 1),
                    resetsAt: bucket.string("resetTime").flatMap(Date.fromISO8601))
            }
        }
        guard !windows.isEmpty else { throw FetchError.badPayload("no quota buckets") }
        return ProviderReading(windows: windows)
    }

    /// Antigravity names its windows in words. Claude and Codex report window
    /// lengths, which become labels like "5h" and "7d". This maps the words to
    /// the same short form so one column width fits every provider.
    static func label(forWindow raw: String?) -> String {
        switch raw?.lowercased() {
        case "weekly", "week": "7d"
        case "daily", "day": "24h"
        case "monthly", "month": "30d"
        case let known?: known
        case nil: "—"
        }
    }
}

extension Date {
    /// Google and Anthropic both return ISO 8601, but only one includes
    /// fractional seconds, so try both shapes.
    static func fromISO8601(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
