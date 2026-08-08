import Foundation
import Testing
import UsageModels
@testable import UsageFetch

@Test func windowLabelsDeriveFromSeconds() {
    #expect(CodexClient.label(forWindowSeconds: 18_000) == "5h")
    #expect(CodexClient.label(forWindowSeconds: 604_800) == "7d")
    #expect(CodexClient.label(forWindowSeconds: 3_600) == "1h")
    #expect(CodexClient.label(forWindowSeconds: 0) == "—")
}

@Test func antigravityWindowWordsBecomeShortLabels() {
    // Antigravity says "weekly" where the others report a length. One column
    // width has to fit every provider, so the words normalise to the same form.
    #expect(AntigravityClient.label(forWindow: "weekly") == "7d")
    #expect(AntigravityClient.label(forWindow: "5h") == "5h")
    #expect(AntigravityClient.label(forWindow: nil) == "—")
    // An unknown word passes through rather than becoming "—": showing the raw
    // value is more useful than hiding that a new window kind appeared.
    #expect(AntigravityClient.label(forWindow: "hourly") == "hourly")
}

@Test func grokCredentialReadsTheStoredOidcSession() throws {
    let auth: [String: Any] = [
        "https://auth.x.ai::client": [
            "key": "access",
            "refresh_token": "refresh",
            "expires_at": "2026-08-07T21:26:17Z",
            "email": "person@example.com",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "client",
        ]
    ]

    let credential = try #require(GrokClient.credential(in: auth))
    #expect(credential.accessToken == "access")
    #expect(credential.refreshToken == "refresh")
    #expect(credential.email == "person@example.com")
    #expect(credential.issuer == "https://auth.x.ai")
    #expect(credential.clientID == "client")
    #expect(credential.expiresAt != nil)
}

@Test func grokCredentialRejectsAnUnusableEntry() {
    #expect(GrokClient.credential(in: [:]) == nil)
    #expect(GrokClient.credential(in: ["entry": ["email": "person@example.com"]]) == nil)
}

@Test func grokCredentialRejectsTokensFromAnotherIssuer() {
    let auth: [String: Any] = [
        "a-https://other.example::client": [
            "key": "must-not-be-sent-to-xai",
            "refresh_token": "must-not-be-sent-to-xai",
            "oidc_issuer": "https://other.example",
            "oidc_client_id": "client",
        ],
        "z-https://auth.x.ai::client": [
            "key": "xai-access",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "client",
        ],
    ]
    #expect(GrokClient.credential(in: auth)?.accessToken == "xai-access")
    #expect(GrokClient.credential(in: ["entry": auth["a-https://other.example::client"]!]) == nil)
}

@Test func malformedGrokAuthIsAnErrorRatherThanSignedOut() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let auth = root.appendingPathComponent("auth.json")
    try Data("not json".utf8).write(to: auth)

    do {
        _ = try GrokClient.credential(at: auth)
        Issue.record("malformed auth.json unexpectedly parsed")
    } catch FetchError.badPayload {
        // Expected: the collector renders this as an error, not signedOut.
    } catch {
        Issue.record("malformed auth.json threw \(error) instead of badPayload")
    }
}

@Test func grokRefreshPersistsRotatedTokensAtomically() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let auth = root.appendingPathComponent("auth.json")
    let storageKey = "https://auth.x.ai::client"
    let original: [String: Any] = [storageKey: [
        "key": "old-access",
        "refresh_token": "old-refresh",
        "expires_at": "2026-08-01T00:00:00Z",
        "email": "person@example.com",
        "oidc_issuer": "https://auth.x.ai",
        "oidc_client_id": "client",
    ]]
    try JSONSerialization.data(withJSONObject: original).write(to: auth)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
    let credential = try GrokClient.credential(at: auth)
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    try GrokClient.persist(
        refresh: GrokRefresh(
            accessToken: "new-access", refreshToken: "new-refresh", expiresIn: 3_600),
        credential: credential, at: auth, now: now)

    let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as! [String: Any]
    let entry = try #require(updated[storageKey] as? [String: Any])
    #expect(entry["key"] as? String == "new-access")
    #expect(entry["refresh_token"] as? String == "new-refresh")
    #expect(entry["email"] as? String == "person@example.com")
    #expect((entry["expires_at"] as? String).flatMap(Date.fromISO8601) == now.addingTimeInterval(3_600))
    let attributes = try FileManager.default.attributesOfItem(atPath: auth.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func grokBillingConvertsTheWeeklyCreditWindow() throws {
    let payload: [String: Any] = ["config": [
        "creditUsagePercent": 42.0,
        "currentPeriod": [
            "type": "USAGE_PERIOD_TYPE_WEEKLY",
            "start": "2026-08-01T19:17:43.386846+00:00",
            "end": "2026-08-08T19:17:43.386846+00:00",
        ],
    ]]

    let reading = try GrokClient.reading(from: payload, email: "person@example.com")
    #expect(reading.email == "person@example.com")
    #expect(reading.windows.count == 1)
    #expect(reading.windows[0].label == "7d")
    #expect(reading.windows[0].usedFraction == 0.42)
    #expect(reading.windows[0].resetsAt != nil)
}

@Test func grokBillingClampsPercentAndToleratesAnUnknownPeriod() throws {
    let over: [String: Any] = ["config": ["creditUsagePercent": 142.0]]
    let under: [String: Any] = ["config": ["creditUsagePercent": -5.0]]

    #expect(try GrokClient.reading(from: over, email: nil).windows[0].usedFraction == 1)
    #expect(try GrokClient.reading(from: under, email: nil).windows[0].usedFraction == 0)
    #expect(try GrokClient.reading(from: over, email: nil).windows[0].label == "—")
    #expect(try GrokClient.reading(from: over, email: nil).windows[0].resetsAt == nil)
}

@Test func grokBillingRequiresAnAggregatePercentage() {
    #expect(throws: FetchError.self) {
        try GrokClient.reading(from: ["config": [:]], email: nil)
    }
}

@Test func grokRequestTargetsTheCreditsEndpoint() {
    let request = GrokClient.billingRequest(accessToken: "access")
    #expect(request.url?.absoluteString
        == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
}

@Test func grokRequestRefreshesThroughTheStoredOidcClient() throws {
    let request = GrokClient.refreshRequest(refreshToken: "refresh token", clientID: "client")
    #expect(request.url?.absoluteString == "https://auth.x.ai/oauth2/token")
    #expect(request.httpMethod == "POST")

    let body = try #require(request.httpBody)
    let fields = URLComponents(string: "?" + String(decoding: body, as: UTF8.self))?.queryItems
    let values = Dictionary(uniqueKeysWithValues: (fields ?? []).map { ($0.name, $0.value) })
    #expect(values["grant_type"] == "refresh_token")
    #expect(values["refresh_token"] == "refresh token")
    #expect(values["client_id"] == "client")
}

private actor GrokHTTPStub {
    struct Reply: Sendable {
        let status: Int
        let body: String
    }

    private var replies: [Reply]
    private var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw FetchError.badPayload("unexpected request") }
        let reply = replies.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(reply.body.utf8), response)
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private let grokBillingFixture = """
{"config":{"creditUsagePercent":42,"currentPeriod":{
"start":"2026-08-01T19:17:43Z","end":"2026-08-08T19:17:43Z"}}}
"""

private func grokCredential(expiresAt: Date?) -> GrokCredential {
    GrokCredential(
        storageKey: "https://auth.x.ai::client",
        accessToken: "stored-access", refreshToken: "refresh", expiresAt: expiresAt,
        email: "person@example.com", issuer: "https://auth.x.ai", clientID: "client")
}

@Test func expiredGrokTokenRefreshesBeforeBilling() async throws {
    let stub = GrokHTTPStub([
        .init(status: 200, body: #"{"access_token":"fresh-access"}"#),
        .init(status: 200, body: grokBillingFixture),
    ])
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    let reading = try await GrokClient.fetch(
        credential: grokCredential(expiresAt: now.addingTimeInterval(-1)), now: now,
        send: { try await stub.send($0) })

    #expect(reading.windows[0].usedFraction == 0.42)
    let requests = await stub.recordedRequests()
    #expect(requests.map { $0.url?.path } == ["/oauth2/token", "/v1/billing"])
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access")
}

@Test func grokBilling401RefreshesAndRetriesExactlyOnce() async throws {
    let stub = GrokHTTPStub([
        .init(status: 401, body: "unauthorized"),
        .init(status: 200, body: #"{"access_token":"fresh-access"}"#),
        .init(status: 200, body: grokBillingFixture),
    ])
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    _ = try await GrokClient.fetch(
        credential: grokCredential(expiresAt: now.addingTimeInterval(3_600)), now: now,
        send: { try await stub.send($0) })

    let requests = await stub.recordedRequests()
    #expect(requests.map { $0.url?.path } == ["/v1/billing", "/oauth2/token", "/v1/billing"])
    #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access")
}

@Test func grokBillingNon401DoesNotRefresh() async {
    let stub = GrokHTTPStub([.init(status: 503, body: "unavailable")])
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    await #expect(throws: FetchError.self) {
        try await GrokClient.fetch(
            credential: grokCredential(expiresAt: now.addingTimeInterval(3_600)), now: now,
            send: { try await stub.send($0) })
    }
    #expect(await stub.recordedRequests().count == 1)
}

@Test func grokBillingSecond401SurfacesWithoutAnotherRefresh() async {
    let stub = GrokHTTPStub([
        .init(status: 401, body: "unauthorized"),
        .init(status: 200, body: #"{"access_token":"fresh-access"}"#),
        .init(status: 401, body: "still unauthorized"),
    ])
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    await #expect(throws: FetchError.self) {
        try await GrokClient.fetch(
            credential: grokCredential(expiresAt: now.addingTimeInterval(3_600)), now: now,
            send: { try await stub.send($0) })
    }
    #expect(await stub.recordedRequests().count == 3)
}

@Test func duplicateGrokAccountsShareTheAuthRefreshLock() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let auth = root.appendingPathComponent("auth.json")
    let original: [String: Any] = ["https://auth.x.ai::client": [
        "key": "expired-access",
        "refresh_token": "old-refresh",
        "expires_at": "2026-08-01T00:00:00Z",
        "oidc_issuer": "https://auth.x.ai",
        "oidc_client_id": "client",
    ]]
    try JSONSerialization.data(withJSONObject: original).write(to: auth)
    let stub = GrokHTTPStub([
        .init(status: 200, body: #"{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":3600}"#),
        .init(status: 200, body: grokBillingFixture),
        .init(status: 200, body: grokBillingFixture),
    ])
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    async let first = GrokClient.fetch(
        at: auth, now: now, send: { try await stub.send($0) })
    async let second = GrokClient.fetch(
        at: auth, now: now, send: { try await stub.send($0) })
    let readings = try await [first, second]

    #expect(readings.allSatisfy { $0.windows[0].usedFraction == 0.42 })
    let requests = await stub.recordedRequests()
    #expect(requests.filter { $0.url?.path == "/oauth2/token" }.count == 1)
    #expect(requests.filter { $0.url?.path == "/v1/billing" }.count == 2)
}

private final class GrokLockReplacementHook: @unchecked Sendable {
    private let stateLock = NSLock()
    private var didReplace = false

    func replaceOnce(_ lockURL: URL) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !didReplace else { return }
        didReplace = true
        try? FileManager.default.removeItem(at: lockURL)
        try? Data("stale-holder".utf8).write(to: lockURL)
    }
}

@Test func grokAuthLockRetriesWhenTheCLIReplacesItsInode() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let auth = root.appendingPathComponent("auth.json")
    try Data("{}".utf8).write(to: auth)
    let hook = GrokLockReplacementHook()

    let lock = try await GrokAuthFileLock.acquire(for: auth, onOpened: hook.replaceOnce)
    defer { lock.release() }

    #expect(lock.descriptorMatchesPath())
    let holder = try String(contentsOf: auth.appendingPathExtension("lock"), encoding: .utf8)
    #expect(holder.split(separator: ":").first == Substring(String(getpid())))
}

@Test func everyClientPairIsTriedBecauseTheBinaryHoldsMoreThanOne() {
    // Nothing in the binary layout says which id belongs to which secret, so
    // every combination has to be a candidate.
    let pairs = AntigravityCredentialStore.pairs(
        ids: ["a.apps.googleusercontent.com", "b.apps.googleusercontent.com"],
        secrets: ["GOCSPX-one", "GOCSPX-two"])
    #expect(pairs.count == 4)
    #expect(pairs.first?.clientID == "a.apps.googleusercontent.com")
    #expect(Set(pairs.map(\.clientSecret)) == ["GOCSPX-one", "GOCSPX-two"])
}

@Test func scanKeepsTheFirstOfEachRepeatedMatch() {
    // grep prints one line per hit, and a binary repeats the same string.
    #expect(AntigravityCredentialStore.distinctLines("a\nb\na\nc\n") == ["a", "b", "c"])
    #expect(AntigravityCredentialStore.distinctLines("") == [])
}

@Test func onlyAClientMismatchIsWorthRetrying() {
    // A wrong pair must fall through to the next candidate. Anything else
    // repeats for every pair, so it should surface instead of being retried.
    #expect(AntigravityClient.isWrongClient(400, "{\"error\":\"invalid_client\"}"))
    #expect(AntigravityClient.isWrongClient(401, ""))
    #expect(!AntigravityClient.isWrongClient(400, "{\"error\":\"invalid_grant\"}"))
    #expect(!AntigravityClient.isWrongClient(503, "backend error"))
}

@Test func usedPercentClampsAndRounds() {
    #expect(UsageWindow(label: "5h", usedFraction: 0.094).usedPercent == 9)
    #expect(UsageWindow(label: "5h", usedFraction: 1.4).usedPercent == 100)
    #expect(UsageWindow(label: "5h", usedFraction: -0.2).usedPercent == 0)
}

@Test func worstWindowPicksTheFullestOne() {
    let account = UsageAccount(
        id: "cc1", provider: .claude, displayName: "cc1", state: .ok,
        windows: [
            UsageWindow(label: "5h", usedFraction: 0.09),
            UsageWindow(label: "7d", usedFraction: 0.62),
        ])
    #expect(account.worstWindow?.label == "7d")
}

@Test func iso8601ParsesBothFractionalAndPlainForms() {
    // Anthropic sends fractional seconds; Google does not.
    #expect(Date.fromISO8601("2026-08-06T20:00:00.027245+00:00") != nil)
    #expect(Date.fromISO8601("2026-08-03T14:02:16Z") != nil)
    #expect(Date.fromISO8601("not a date") == nil)
}

@Test func snapshotSurvivesAWireRoundTrip() throws {
    let snapshot = UsageSnapshot(generatedAt: Date(timeIntervalSince1970: 1_785_575_910), accounts: [
        UsageAccount(
            id: "agy1", provider: .antigravity, displayName: "agy1", state: .ok,
            windows: [UsageWindow(group: "Gemini Models", label: "weekly", usedFraction: 0.0135)]),
        UsageAccount(
            id: "grok", provider: .grok, displayName: "grok", plan: "SuperGrok",
            email: "person@example.com", state: .ok,
            windows: [UsageWindow(label: "7d", usedFraction: 0.42)]),
        UsageAccount(id: "cc2", provider: .claude, displayName: "cc2", state: .signedOut),
    ])
    let data = try UsageSnapshot.encoder().encode(snapshot)
    let decoded = try UsageSnapshot.decoder().decode(UsageSnapshot.self, from: data)
    #expect(decoded == snapshot)
    #expect(decoded.accounts[0].windows[0].group == "Gemini Models")
    #expect(decoded.accounts[1].provider == .grok)
    #expect(decoded.accounts[1].windows[0].usedFraction == 0.42)
    #expect(decoded.accounts[2].state == .signedOut)
}

@Test func snapshotStoreStartsWithACompletedCollection() async throws {
    let initial = UsageSnapshot(
        generatedAt: Date(timeIntervalSince1970: 1_785_575_910),
        accounts: [UsageAccount(
            id: "grok", provider: .grok, displayName: "grok", state: .ok,
            windows: [UsageWindow(label: "7d", usedFraction: 1)])])

    let store = SnapshotStore(initial: initial)
    let decoded = try UsageSnapshot.decoder().decode(
        UsageSnapshot.self, from: await store.body())

    #expect(decoded == initial)
}

@Test func keychainDumpYieldsEveryClaudeProfile() {
    // A trimmed `security dump-keychain` listing. Each item prints one
    // attribute per line, and unrelated items share the same shape.
    let dump = """
        attributes:
            "svce"<blob>="Claude Code-credentials-1a2b3c"
            "acct"<blob>="jane"
        attributes:
            "svce"<blob>="Claude Code-credentials"
        attributes:
            "svce"<blob>="Chrome Safe Storage"
        """
    // The default profile has no suffix, and it sorts first so it becomes
    // "claude" rather than "claude-2".
    #expect(Discovery.claudeServices(inKeychainDump: dump)
        == ["Claude Code-credentials", "Claude Code-credentials-1a2b3c"])
}

@Test func discoveredAccountsAreNamedInAStableOrder() {
    let accounts = Discovery.claudeAccounts(
        services: ["Claude Code-credentials", "Claude Code-credentials-1a2b3c"])
    #expect(accounts.map(\.id) == ["claude", "claude-2"])
    #expect(accounts.allSatisfy { $0.keychainService != nil })
}

@Test func discoveredPathsAreWrittenBackInTildeForm() {
    // The config file is meant to be read and edited, so an absolute home path
    // would be noise.
    let codex = Discovery.codexAccounts(
        directories: ["/Users/jane/.codex", "/Users/jane/.codex-work"], home: "/Users/jane")
    #expect(codex.map(\.codexHome) == ["~/.codex", "~/.codex-work"])

    let antigravity = Discovery.antigravityAccounts(
        homes: ["/Users/jane", "/Users/jane/.agy-home-2"], home: "/Users/jane")
    #expect(antigravity.map(\.home) == ["~", "~/.agy-home-2"])
    #expect(antigravity.map(\.id) == ["antigravity", "antigravity-2"])
}

@Test func discoveredGrokPathsAreStableAndUseTildes() {
    let accounts = Discovery.grokAccounts(
        directories: ["/Users/jane/.grok", "/Users/jane/.grok-work"],
        home: "/Users/jane")
    #expect(accounts.map(\.id) == ["grok", "grok-2"])
    #expect(accounts.map(\.grokHome) == ["~/.grok", "~/.grok-work"])
}

@Test func grokDiscoveryRequiresAnAuthFile() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent(".grok", isDirectory: true),
        withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent(".grok-empty", isDirectory: true),
        withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: root.appendingPathComponent(".grok/auth.json"))

    #expect(Discovery.grokDirectories(home: root.path) == [root.path + "/.grok"])
}

@Test func configMigrationAddsDiscoveredGrokWithoutRenamingExistingAccounts() {
    var config = Config(
        configVersion: nil,
        accounts: [AccountConfig(
            id: "work", provider: .codex, displayName: "Work Codex", codexHome: "~/.codex")])
    let discovered = [AccountConfig(
        id: "grok", provider: .grok, displayName: "grok", grokHome: "~/.grok")]

    let migrated = config.migrateIfNeeded(discovered: discovered)
    #expect(migrated)
    #expect(config.configVersion == Config.currentVersion)
    #expect(config.accounts.map(\.id) == ["work", "grok"])
    #expect(config.accounts[0].displayName == "Work Codex")
    let migratedAgain = config.migrateIfNeeded(discovered: discovered)
    #expect(!migratedAgain)
    #expect(config.accounts.map(\.id) == ["work", "grok"])
}

@Test func configMigrationDoesNotDuplicateAManuallyConfiguredGrokAccount() {
    var config = Config(
        configVersion: nil,
        accounts: [AccountConfig(
            id: "xai", provider: .grok, displayName: "Personal", grokHome: "~/.grok")])
    let discovered = [AccountConfig(
        id: "grok", provider: .grok, displayName: "grok", grokHome: "~/.grok")]

    let migrated = config.migrateIfNeeded(discovered: discovered)
    #expect(migrated)
    #expect(config.accounts.count == 1)
    #expect(config.accounts[0].id == "xai")
}

@Test func discoveryFindsNothingWhenNoAgentIsInstalled() {
    // An empty result must stay empty rather than fall back to an invented
    // account, because a phantom account reads as a broken login in the sidebar.
    #expect(Discovery.claudeServices(inKeychainDump: "") == [])
    #expect(Discovery.accounts(home: "/nonexistent-home").isEmpty
        || !Discovery.accounts(home: "/nonexistent-home").contains { $0.provider != .claude })
}
