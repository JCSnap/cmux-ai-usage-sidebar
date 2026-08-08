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

@Test func discoveryFindsNothingWhenNoAgentIsInstalled() {
    // An empty result must stay empty rather than fall back to an invented
    // account, because a phantom account reads as a broken login in the sidebar.
    #expect(Discovery.claudeServices(inKeychainDump: "") == [])
    #expect(Discovery.accounts(home: "/nonexistent-home").isEmpty
        || !Discovery.accounts(home: "/nonexistent-home").contains { $0.provider != .claude })
}
