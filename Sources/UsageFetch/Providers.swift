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

// MARK: - Grok

struct GrokCredential: Sendable {
    let storageKey: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let email: String?
    let issuer: String?
    let clientID: String?
}

struct GrokRefresh: Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: TimeInterval?
}

/// Credential: plain file `$GROK_HOME/auth.json`. The root is keyed by issuer
/// and client ID, with one OAuth session object beneath each key.
struct GrokClient: UsageProviderClient {
    private static let issuer = "https://auth.x.ai"

    func fetch(_ account: AccountConfig) async throws -> ProviderReading {
        let home = (account.grokHome ?? "~/.grok").expandedPath
        let url = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
        let credential = try Self.credential(at: url)
        return try await Self.fetch(
            credential: credential, now: Date(),
            send: { try await Http.response($0) },
            persist: { refresh in
                try Self.persist(refresh: refresh, credential: credential, at: url, now: Date())
            })
    }

    static func fetch(
        credential: GrokCredential,
        now: Date,
        send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
        persist: @Sendable (GrokRefresh) throws -> Void = { _ in }
    ) async throws -> ProviderReading {
        var accessToken = credential.accessToken
        var didRefresh = false
        if credential.expiresAt.map({ $0 <= now.addingTimeInterval(300) }) == true {
            let refreshed = try await Self.refresh(credential, send: send)
            try persist(refreshed)
            accessToken = refreshed.accessToken
            didRefresh = true
        }

        var (billingData, response) = try await send(
            Self.billingRequest(accessToken: accessToken))
        if response.statusCode == 401, !didRefresh {
            let refreshed = try await Self.refresh(credential, send: send)
            try persist(refreshed)
            accessToken = refreshed.accessToken
            (billingData, response) = try await send(
                Self.billingRequest(accessToken: accessToken))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw FetchError.badStatus(
                response.statusCode, String(decoding: billingData, as: UTF8.self))
        }
        guard let payload = try JSONSerialization.jsonObject(with: billingData) as? [String: Any]
        else { throw FetchError.badPayload("not a JSON object") }
        return try Self.reading(from: payload, email: credential.email)
    }

    static func billingRequest(accessToken: String) -> URLRequest {
        Http.get(
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json",
            ])
    }

    static func refreshRequest(refreshToken: String, clientID: String) -> URLRequest {
        Http.form(
            "https://auth.x.ai/oauth2/token",
            fields: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientID,
            ])
    }

    private static func refresh(
        _ credential: GrokCredential,
        send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> GrokRefresh {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty,
              let clientID = credential.clientID, !clientID.isEmpty
        else { throw FetchError.noCredential }
        let (data, response) = try await send(
            refreshRequest(refreshToken: refreshToken, clientID: clientID))
        guard (200..<300).contains(response.statusCode) else {
            throw FetchError.badStatus(
                response.statusCode, String(decoding: data, as: UTF8.self))
        }
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.badPayload("token refresh returned invalid JSON")
        }
        guard let accessToken = payload.string("access_token"), !accessToken.isEmpty else {
            throw FetchError.badPayload("token refresh returned no access_token")
        }
        return GrokRefresh(
            accessToken: accessToken,
            refreshToken: payload.string("refresh_token"),
            expiresIn: payload.double("expires_in"))
    }

    static func credential(in root: [String: Any]) -> GrokCredential? {
        for key in root.keys.sorted() {
            guard let entry = root.dict(key),
                  entry.string("oidc_issuer") == issuer,
                  let accessToken = entry.string("key"), !accessToken.isEmpty
            else { continue }
            return GrokCredential(
                storageKey: key,
                accessToken: accessToken,
                refreshToken: entry.string("refresh_token"),
                expiresAt: entry.string("expires_at").flatMap(Date.fromISO8601),
                email: entry.string("email"),
                issuer: entry.string("oidc_issuer"),
                clientID: entry.string("oidc_client_id"))
        }
        return nil
    }

    static func credential(at url: URL) throws -> GrokCredential {
        guard let data = try? Data(contentsOf: url) else { throw FetchError.noCredential }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw FetchError.badPayload("Grok auth.json is invalid JSON")
        }
        guard let root = object as? [String: Any] else {
            throw FetchError.badPayload("Grok auth.json is not a JSON object")
        }
        guard let credential = credential(in: root) else { throw FetchError.noCredential }
        return credential
    }

    /// Grok's OIDC server rotates refresh tokens. Preserve the fresh session in
    /// Grok's own entry so both the CLI and future daemon processes can use it.
    /// Re-read before writing to avoid replacing unrelated fields or a newer
    /// credential written concurrently by Grok itself.
    static func persist(
        refresh: GrokRefresh,
        credential: GrokCredential,
        at url: URL,
        now: Date
    ) throws {
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var entry = root[credential.storageKey] as? [String: Any]
        else { throw FetchError.badPayload("Grok auth.json changed shape during refresh") }

        if let storedRefresh = entry.string("refresh_token"),
           storedRefresh != credential.refreshToken {
            // Grok refreshed the same entry after we read it. Its value is
            // newer, so do not overwrite it with this response.
            return
        }

        entry["key"] = refresh.accessToken
        if let refreshToken = refresh.refreshToken, !refreshToken.isEmpty {
            entry["refresh_token"] = refreshToken
        }
        if let expiresIn = refresh.expiresIn {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            entry["expires_at"] = formatter.string(from: now.addingTimeInterval(expiresIn))
        }
        root[credential.storageKey] = entry

        let updated = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func reading(from payload: [String: Any], email: String?) throws -> ProviderReading {
        guard let config = payload.dict("config"),
              let usedPercent = config.double("creditUsagePercent")
        else { throw FetchError.badPayload("no creditUsagePercent") }

        let period = config.dict("currentPeriod")
        let startsAt = period?.string("start").flatMap(Date.fromISO8601)
        let resetsAt = period?.string("end").flatMap(Date.fromISO8601)
        let label: String
        if let startsAt, let resetsAt, resetsAt > startsAt {
            label = CodexClient.label(
                forWindowSeconds: Int(resetsAt.timeIntervalSince(startsAt).rounded()))
        } else {
            label = "—"
        }

        return ProviderReading(
            email: email,
            windows: [UsageWindow(
                label: label,
                usedFraction: max(0, min(100, usedPercent)) / 100,
                resetsAt: resetsAt)])
    }
}

// MARK: - Antigravity

/// Credential: `<home>/.gemini/antigravity-cli/antigravity-oauth-token`.
/// Note this is not `~/.gemini/oauth_creds.json`, which belongs to gemini-cli
/// and goes stale independently.
struct AntigravityClient: UsageProviderClient {
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
        let accessToken = try await Self.refresh(refreshToken)

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

    /// Exchanges the stored refresh token for an access token.
    ///
    /// The OAuth client comes from the installed CLI rather than from source,
    /// and the binary holds more than one. Try each candidate: only the client
    /// that issued the token can refresh it, so the endpoint is the authority on
    /// which pair is right. Remember the winner so this happens once.
    static func refresh(_ refreshToken: String) async throws -> String {
        var lastError: Error = FetchError.noClientCredentials
        var tried: Set<AntigravityCredentials> = []
        for source in AntigravityCredentialStore.sources {
            for credentials in source() where tried.insert(credentials).inserted {
                do {
                    let refreshed = try await Http.json(Http.form(
                        "https://oauth2.googleapis.com/token",
                        fields: [
                            "client_id": credentials.clientID,
                            "client_secret": credentials.clientSecret,
                            "refresh_token": refreshToken,
                            "grant_type": "refresh_token",
                        ]))
                    guard let accessToken = refreshed.string("access_token") else {
                        throw FetchError.badPayload("token refresh returned no access_token")
                    }
                    AntigravityCredentialStore.remember(credentials)
                    return accessToken
                } catch let FetchError.badStatus(code, body) where isWrongClient(code, body) {
                    // Only a mismatched client is worth retrying. Any other
                    // failure repeats for every pair, so surface it rather than
                    // hide it behind three more identical requests.
                    lastError = FetchError.badStatus(code, body)
                    continue
                }
            }
        }
        throw lastError
    }

    static func isWrongClient(_ code: Int, _ body: String) -> Bool {
        code == 401 || (code == 400 && body.contains("invalid_client"))
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
