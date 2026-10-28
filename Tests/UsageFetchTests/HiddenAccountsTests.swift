import Foundation
import Testing
import UsageModels
@testable import UsageFetch

private let now = Date(timeIntervalSince1970: 1_785_575_910)

/// Two pools, so the injectable pool client stands in for both and no test
/// reaches a real vendor.
private let shown = AccountConfig(
    id: "cc3", provider: .claude, displayName: "cc3", cliProxyURL: "http://127.0.0.1:1")
private let muted = AccountConfig(
    id: "c3", provider: .codex, displayName: "Codex pool", cliProxyURL: "http://127.0.0.1:1")

/// Records which accounts were read.
private actor Reads {
    private(set) var ids: [String] = []
    func add(_ id: String) { ids.append(id) }
}

private struct RecordingPool: UsageProviderClient {
    let reads: Reads
    func fetch(_ account: AccountConfig) async throws -> ProviderReading {
        await reads.add(account.id)
        return ProviderReading(windows: [], members: [UsageAccount(
            id: "\(account.id)-a", provider: account.provider, displayName: "a", state: .ok,
            windows: [UsageWindow(label: "5h", usedFraction: 0.4)])])
    }
}

@Test func aHiddenAccountIsNeitherReadNorShown() async {
    let reads = Reads()
    let collector = UsageCollector(poolClient: RecordingPool(reads: reads))
    let config = Config(accounts: [shown, muted], hiddenAccounts: ["c3"])

    let snapshot = await collector.collect(config, now: now)

    #expect(await reads.ids == ["cc3"])
    #expect(snapshot.accounts.map(\.id) == ["cc3"])
    #expect(snapshot.hidden == [HiddenAccount(id: "c3", provider: .codex, displayName: "Codex pool")])
}

@Test func hidingAndShowingEditOnlyTheHiddenList() {
    var config = Config(accounts: [shown, muted])
    #expect(config.visibleAccounts.map(\.id) == ["cc3", "c3"])

    let hid = config.setHidden("c3", true)
    let hidAgain = config.setHidden("c3", true)
    #expect(hid && hidAgain)
    #expect(config.hiddenAccounts == ["c3"])
    #expect(config.visibleAccounts.map(\.id) == ["cc3"])
    #expect(config.accounts.count == 2)

    let showed = config.setHidden("c3", false)
    #expect(showed)
    // An empty list leaves the key out of the file rather than writing `[]`.
    #expect(config.hiddenAccounts == nil)
    #expect(config.visibleAccounts.map(\.id) == ["cc3", "c3"])
}

@Test func anUnknownIdIsNeverWrittenToTheHiddenList() {
    var config = Config(accounts: [shown])
    let hid = config.setHidden("typo", true)
    #expect(!hid)
    #expect(config.hiddenAccounts == nil)
}

@Test func theHiddenListSurvivesTheConfigFile() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json").path
    defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    var config = Config(accounts: [shown, muted])
    config.setHidden("cc3", true)

    try config.save(to: path)
    let decoded = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))

    #expect(decoded.hiddenAccounts == ["cc3"])
    #expect(decoded.visibleAccounts.map(\.id) == ["c3"])
}

@Test func aConfigWithoutTheKeyHidesNothing() throws {
    let json = #"{"port":47823,"refreshSeconds":300,"accounts":[{"id":"grok","provider":"grok","displayName":"grok","grokHome":"~/.grok"}]}"#
    let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    #expect(config.hiddenAccounts == nil)
    #expect(config.visibleAccounts.map(\.id) == ["grok"])
}

@Test func hidingDropsTheRowWithoutARead() {
    let rows = [shown, muted].map {
        UsageAccount(id: $0.id, provider: $0.provider, displayName: $0.displayName, state: .ok)
    }
    let before = UsageSnapshot(generatedAt: now, accounts: rows, hidden: [])
    var config = Config(accounts: [shown, muted])
    config.setHidden("cc3", true)

    let after = UsageCollector.applyingVisibility(config, to: before)

    #expect(after.generatedAt == now)
    #expect(after.accounts.map(\.id) == ["c3"])
    #expect(after.hidden?.map(\.id) == ["cc3"])
}

@Test func anOlderSnapshotWithoutAHiddenListStillDecodes() throws {
    let json = #"{"generatedAt":"2033-05-18T03:33:20Z","accounts":[]}"#
    let decoded = try UsageSnapshot.decoder().decode(UsageSnapshot.self, from: Data(json.utf8))
    #expect(decoded.hidden == nil)
}

@Test(arguments: [
    ("GET / HTTP/1.1", DaemonRequest.snapshot),
    ("GET /refresh HTTP/1.1", .refresh),
    ("POST /refresh HTTP/1.1", .refresh),
    ("POST / HTTP/1.1", .refresh),
    ("POST /hide/cc1 HTTP/1.1", .setHidden(id: "cc1", hidden: true)),
    ("POST /show/cc1 HTTP/1.1", .setHidden(id: "cc1", hidden: false)),
    ("POST /hide/my%20pool HTTP/1.1", .setHidden(id: "my pool", hidden: true)),
    // A GET must never change the config file.
    ("GET /hide/cc1 HTTP/1.1", .snapshot),
    ("", .snapshot),
])
func requestLinesRouteToTheirRequest(line: String, expected: DaemonRequest) {
    #expect(DaemonRequest(requestLine: line) == expected)
}
