import Foundation
import Testing
import UsageModels
@testable import UsageFetch

// MARK: - Fixtures

private let proxyBase = "http://127.0.0.1:8317"
private let now = Date(timeIntervalSince1970: 2_000_000_000)

private let pool = AccountConfig(
    id: "cc3", provider: .claude, displayName: "cc3", cliProxyURL: proxyBase)

private let authFilesFixture = """
{"files":[
 {"auth_index":"a1","provider":"claude","email":"alice@example.com","disabled":false},
 {"auth_index":"b2","provider":"claude","email":"bob@example.com","disabled":false},
 {"auth_index":"d4","provider":"claude","email":"dora@example.com","disabled":true},
 {"auth_index":"c3","provider":"codex","email":"carol@example.com",
  "id_token":{"chatgpt_account_id":"ws-1","plan_type":"pro"}},
 {"provider":"claude","email":"no-index@example.com"}
]}
"""

private func reply(_ status: Int, _ url: String = proxyBase) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: [:])!
}

/// The JSON the `api-call` relay returns around a vendor reply.
private func relayed(_ status: Int, body: String, retryAfter: String? = nil) -> Data {
    var header: [String: Any] = [:]
    if let retryAfter { header["Retry-After"] = [retryAfter] }
    return try! JSONSerialization.data(withJSONObject: [
        "status_code": status, "header": header, "body": body,
    ])
}

private func claudeUsage(_ percent: Double, resets: String = "2033-05-18T05:00:00Z") -> String {
    #"{"five_hour":{"utilization":\#(percent),"resets_at":"\#(resets)"},"seven_day":null}"#
}

private func member(
    _ name: String, state: UsageAccountState = .ok, windows: [UsageWindow],
    updatedAt: Date? = now
) -> UsageAccount {
    UsageAccount(
        id: "cc3/\(name)", provider: .claude, displayName: name, state: state,
        windows: windows, detail: state == .ok ? nil : "HTTP 429: rate limited",
        updatedAt: updatedAt)
}

private func keyFile() throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cliproxy-key-\(UUID().uuidString)")
    try "secret-key\n".write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

/// Answers the proxy's two endpoints: the auth-file list, then one relayed
/// usage call per login, keyed by `auth_index`.
private func fakeProxy(
    usage: [String: Data], seen: RequestLog
) -> CLIProxyClient.Send {
    { request in
        await seen.record(request)
        let url = request.url!.absoluteString
        if url.hasSuffix("/auth-files") {
            return (Data(authFilesFixture.utf8), reply(200, url))
        }
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let index = body["auth_index"] as! String
        return (usage[index] ?? relayed(500, body: "no fixture"), reply(200, url))
    }
}

private actor RequestLog {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}

// MARK: - Pool arithmetic

@Test func pooledWindowsAverageEachWindowAndTakeTheEarliestReset() {
    let early = Date(timeIntervalSince1970: 2_000_001_000)
    let late = Date(timeIntervalSince1970: 2_000_009_000)
    let members = [
        member("a", windows: [
            UsageWindow(label: "5h", usedFraction: 0.2, resetsAt: late),
            UsageWindow(label: "7d", usedFraction: 0.5, resetsAt: late),
        ]),
        member("b", windows: [UsageWindow(label: "5h", usedFraction: 0.6, resetsAt: early)]),
        // A member with no numbers must not drag the average to zero.
        member("c", state: .error, windows: []),
    ]

    let windows = CLIProxyClient.pooledWindows(members)

    #expect(windows.map(\.label) == ["5h", "7d"])
    #expect(abs(windows[0].usedFraction - 0.4) < 1e-9)
    #expect(windows[0].resetsAt == early)
    // Only the member that reports a weekly window counts toward it.
    #expect(windows[1].usedFraction == 0.5)
}

@Test func staleMembersStillCountTowardThePool() {
    let members = [
        member("a", windows: [UsageWindow(label: "5h", usedFraction: 0.1)]),
        member("b", state: .stale, windows: [UsageWindow(label: "5h", usedFraction: 0.3)]),
    ]
    #expect(abs(CLIProxyClient.pooledWindows(members)[0].usedFraction - 0.2) < 1e-9)
}

@Test func aPoolHasAPlanOnlyWhenEveryMemberSharesIt() {
    func plan(_ plan: String?) -> UsageAccount {
        UsageAccount(id: UUID().uuidString, provider: .codex, displayName: "x", plan: plan, state: .ok)
    }
    #expect(CLIProxyClient.pooledPlan([plan("pro"), plan("pro")]) == "pro")
    #expect(CLIProxyClient.pooledPlan([plan("pro"), plan("plus")]) == nil)
    #expect(CLIProxyClient.pooledPlan([plan(nil)]) == nil)
}

// MARK: - Management API

@Test func authFilesYieldEveryIndexedLoginWithItsCodexWorkspace() throws {
    let root = try JSONSerialization.jsonObject(with: Data(authFilesFixture.utf8)) as! [String: Any]
    let entries = CLIProxyClient.authEntries(in: root)

    #expect(entries.map(\.authIndex) == ["a1", "b2", "d4", "c3"])
    #expect(entries[2].disabled)
    #expect(entries[3].chatgptAccountID == "ws-1")
    #expect(entries[3].plan == "pro")
    #expect(entries[0].displayName == "alice")
}

@Test func theRelayCarriesTheVendorRequestWithATokenPlaceholder() throws {
    let entry = CLIProxyClient.AuthEntry(
        authIndex: "a1", provider: "claude", email: nil, disabled: false,
        chatgptAccountID: nil, plan: nil)
    let upstream = try #require(CLIProxyClient.usageRequest(for: entry))
    let request = CLIProxyClient.relayRequest(upstream, authIndex: "a1", base: proxyBase, key: "k")

    #expect(request.url?.absoluteString == "\(proxyBase)/v0/management/api-call")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: Any]
    #expect(body["auth_index"] as? String == "a1")
    #expect(body["url"] as? String == ClaudeClient.usageURL)
    let header = body["header"] as! [String: String]
    #expect(header["Authorization"] == "Bearer $TOKEN$")
    #expect(header["User-Agent"]?.hasPrefix("claude-code/") == true)
}

@Test func aCodexLoginWithoutAWorkspaceCannotBeMetered() {
    let entry = CLIProxyClient.AuthEntry(
        authIndex: "c3", provider: "codex", email: nil, disabled: false,
        chatgptAccountID: nil, plan: nil)
    #expect(CLIProxyClient.usageRequest(for: entry) == nil)
}

@Test func theRelayReplyExposesStatusRetryAfterAndBody() throws {
    let reply = try CLIProxyClient.relayed(from: relayed(429, body: "slow", retryAfter: "42"))
    #expect(reply.status == 429)
    #expect(reply.retryAfter == "42")
    #expect(String(decoding: reply.body, as: UTF8.self) == "slow")
}

// MARK: - End to end through a fake proxy

@Test func aPoolReadsEveryEnabledLoginOfItsProvider() async throws {
    let log = RequestLog()
    let cooldowns = CooldownTracker()
    var client = CLIProxyClient()
    client.cooldowns = cooldowns
    client.now = { now }
    client.send = fakeProxy(
        usage: ["a1": relayed(200, body: claudeUsage(20)), "b2": relayed(200, body: claudeUsage(60))],
        seen: log)
    let account = AccountConfig(
        id: "cc3", provider: .claude, displayName: "cc3",
        cliProxyURL: proxyBase, cliProxyKeyFile: try keyFile())

    let reading = try await client.fetch(account)

    let members = try #require(reading.members)
    // The disabled login and the Codex login are not part of a Claude pool.
    #expect(members.map(\.id) == ["cc3/alice@example.com", "cc3/bob@example.com"])
    #expect(members.map(\.state) == [.ok, .ok])
    #expect(members.map { $0.windows.first?.usedPercent } == [20, 60])
    let requests = await log.requests
    #expect(requests.count == 3)
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key" })
}

@Test func aRelayedRateLimitCoolsThatLoginDownWithoutTouchingTheOthers() async throws {
    let log = RequestLog()
    let cooldowns = CooldownTracker()
    var client = CLIProxyClient()
    client.cooldowns = cooldowns
    client.send = fakeProxy(
        usage: [
            "a1": relayed(200, body: claudeUsage(20)),
            // A drained budget answers with a zero Retry-After.
            "b2": relayed(429, body: "Rate limited.", retryAfter: "0"),
        ],
        seen: log)
    let account = AccountConfig(
        id: "cc3", provider: .claude, displayName: "cc3",
        cliProxyURL: proxyBase, cliProxyKeyFile: try keyFile())

    let first = try #require(try await client.fetch(account).members)
    #expect(first.map(\.state) == [.ok, .error])
    let (blocked, remaining) = await cooldowns.isBlocked("cc3/bob@example.com")
    #expect(blocked)
    #expect(remaining > CLIProxyClient.defaultCooldown - 5)

    // The next cycle skips the cooled-down login instead of calling again.
    _ = try await client.fetch(account)
    #expect(await log.requests.count == 3 + 2)
}

@Test func aMissingManagementKeyReadsAsSignedOut() async {
    let account = AccountConfig(
        id: "cc3", provider: .claude, displayName: "cc3",
        cliProxyURL: proxyBase, cliProxyKeyFile: "/nonexistent/management-key")
    await #expect(throws: FetchError.self) { try await CLIProxyClient().fetch(account) }
}

// MARK: - Collector

private struct StubPool: UsageProviderClient {
    let members: [UsageAccount]
    func fetch(_ account: AccountConfig) async throws -> ProviderReading {
        ProviderReading(windows: [], members: members)
    }
}

@Test func aFailedMemberKeepsItsRecentNumbersInsideThePool() {
    let earlier = UsageAccount(
        id: "cc3", provider: .claude, displayName: "cc3", state: .ok,
        windows: [UsageWindow(label: "5h", usedFraction: 0.3)],
        updatedAt: now.addingTimeInterval(-600),
        members: [
            member("a", windows: [UsageWindow(label: "5h", usedFraction: 0.1)]),
            member("b", windows: [UsageWindow(label: "5h", usedFraction: 0.5)],
                   updatedAt: now.addingTimeInterval(-600)),
        ])
    let fresh = [
        member("a", windows: [UsageWindow(label: "5h", usedFraction: 0.1)]),
        member("b", state: .error, windows: []),
    ]

    let row = UsageCollector.pool(pool, members: fresh, earlier: earlier, now: now)

    #expect(row.state == .ok)
    #expect(row.members?.map(\.state) == [.ok, .stale])
    #expect(row.members?[1].updatedAt == now.addingTimeInterval(-600))
    #expect(abs(row.windows[0].usedFraction - 0.3) < 1e-9)
}

@Test func aPoolWithNoAnsweringMemberIsAnErrorThatStillListsItsMembers() {
    let fresh = [member("a", state: .error, windows: []), member("b", state: .error, windows: [])]

    let row = UsageCollector.pool(pool, members: fresh, earlier: nil, now: now)

    #expect(row.state == .error)
    #expect(row.detail == "HTTP 429: rate limited")
    #expect(row.members?.count == 2)
}

@Test func theCollectorRoutesPoolAccountsToThePoolClient() async {
    let collector = UsageCollector(poolClient: StubPool(members: [
        member("a", windows: [UsageWindow(label: "5h", usedFraction: 0.4)]),
    ]))
    let snapshot = await collector.collect(Config(accounts: [pool]), now: now)

    #expect(snapshot.accounts.count == 1)
    #expect(snapshot.accounts[0].isPool)
    #expect(snapshot.accounts[0].windows.map(\.usedPercent) == [40])
}

@Test func aPoolSurvivesAWireRoundTrip() throws {
    let row = UsageCollector.pool(pool, members: [
        member("a", windows: [UsageWindow(label: "5h", usedFraction: 0.4)]),
    ], earlier: nil, now: now)
    let data = try UsageSnapshot.encoder().encode(UsageSnapshot(generatedAt: now, accounts: [row]))
    let decoded = try UsageSnapshot.decoder().decode(UsageSnapshot.self, from: data)
    #expect(decoded.accounts == [row])
}

@Test func anOlderSnapshotWithoutMembersStillDecodes() throws {
    let json = #"{"generatedAt":"2033-05-18T03:33:20Z","accounts":[{"id":"cc1","provider":"claude","displayName":"cc1","state":"ok","windows":[]}]}"#
    let decoded = try UsageSnapshot.decoder().decode(UsageSnapshot.self, from: Data(json.utf8))
    #expect(decoded.accounts[0].members == nil)
    #expect(!decoded.accounts[0].isPool)
}

// MARK: - Discovery and migration

@Test func discoveryProposesOnePoolPerMeteredProvider() {
    let names = [
        "claude-f13a-alice@example.com.json", "claude-f13a-bob@example.com.json",
        "codex-1544-carol@example.com-pro.json", "gemini-9-dan@example.com.json",
        "management-key", "config.yaml",
    ]
    #expect(Discovery.cliProxyProviders(inFileNames: names) == [.claude, .codex])
    #expect(Discovery.cliProxyProviders(inFileNames: ["config.yaml"]).isEmpty)
}

@Test func discoveryNeedsTheManagementKeyToProposeAPool() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cliproxy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "{}".write(to: dir.appendingPathComponent("claude-x-a@b.json"), atomically: true, encoding: .utf8)
    #expect(Discovery.cliProxyAccounts(authDirectory: dir.path).isEmpty)

    try "k".write(to: dir.appendingPathComponent("management-key"), atomically: true, encoding: .utf8)
    let found = Discovery.cliProxyAccounts(authDirectory: dir.path)
    #expect(found.map(\.id) == ["claude-proxy"])
    #expect(found[0].cliProxyURL == Discovery.cliProxyURL)
}

@Test func migrationToVersionTwoAddsThePoolOnceAndKeepsEveryName() {
    var config = Config(
        configVersion: 1,
        accounts: [AccountConfig(id: "cc1", provider: .claude, displayName: "cc1",
                                 keychainService: "Claude Code-credentials")])
    let discovered = [
        AccountConfig(id: "claude", provider: .claude, displayName: "claude",
                      keychainService: "Claude Code-credentials"),
        AccountConfig(id: "grok", provider: .grok, displayName: "grok", grokHome: "~/.grok"),
        AccountConfig(id: "claude-proxy", provider: .claude, displayName: "claude-proxy",
                      cliProxyURL: proxyBase, cliProxyKeyFile: "~/.cli-proxy-api/management-key"),
    ]

    let migrated = config.migrateIfNeeded(discovered: discovered)
    #expect(migrated)
    // Version 1 already offered Grok; the user's choice to skip it stands.
    #expect(config.accounts.map(\.id) == ["cc1", "claude-proxy"])
    #expect(config.accounts[1].isCLIProxyPool)
    #expect(config.configVersion == 2)
    let migratedAgain = config.migrateIfNeeded(discovered: discovered)
    #expect(!migratedAgain)
}

@Test func migrationDoesNotDuplicateAHandWrittenPool() {
    var config = Config(configVersion: 1, accounts: [pool])
    let discovered = [AccountConfig(
        id: "claude-proxy", provider: .claude, displayName: "claude-proxy", cliProxyURL: proxyBase)]
    let migrated = config.migrateIfNeeded(discovered: discovered)
    #expect(migrated)
    #expect(config.accounts.map(\.id) == ["cc3"])
}

// MARK: - Rate-limit hygiene for direct logins

@Test func aZeroRetryAfterStopsTheRetries() async throws {
    #expect(Http.backoff(retryAfter: "0", attempt: 1) == nil)

    let sent = RequestLog()
    let (_, response) = try await Http.retrying(
        URLRequest(url: URL(string: ClaudeClient.usageURL)!),
        sleep: { _ in },
        send: { request in
            await sent.record(request)
            let limited = HTTPURLResponse(
                url: request.url!, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "0"])!
            return (Data(), limited)
        })
    #expect(response.statusCode == 429)
    #expect(await sent.requests.count == 1)
}

@Test func claudeUsageNamesItselfAsClaudeCode() {
    let headers = ClaudeClient.usageHeaders(token: "t")
    #expect(headers["User-Agent"] == "claude-code/\(ClaudeClient.claudeCodeVersion)")
    #expect(ClaudeClient.claudeCodeVersion.first?.isNumber == true)
}

@Test func aClaudePayloadWithOnlyTheFiveHourWindowIsAFullReading() throws {
    let payload = try JSONSerialization.jsonObject(with: Data(claudeUsage(12).utf8)) as! [String: Any]
    let reading = try ClaudeClient.reading(from: payload)
    #expect(reading.windows.map(\.label) == ["5h"])
    #expect(reading.windows[0].usedPercent == 12)
}
