import Foundation
import Network
import Testing
import UsageModels
@testable import UsageFetch

private actor PausedPool: UsageProviderClient {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func fetch(_ account: AccountConfig) async throws -> ProviderReading {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        return ProviderReading(windows: [], members: [UsageAccount(
            id: "cc3/alice", provider: .claude, displayName: "alice", state: .ok,
            windows: [UsageWindow(label: "5h", usedFraction: 0.4)])])
    }

    func release() { continuation?.resume(); continuation = nil }

    func waitForCall(_ count: Int = 1) async {
        while calls < count { await Task.yield() }
    }
}

private actor Completion {
    private(set) var returned = false
    func finish() { returned = true }
}

@Test func manualRefreshReturnsWhileTheProviderIsStillPending() async {
    let pool = PausedPool()
    let store = SnapshotStore(initial: .empty)
    let config = Config(accounts: [AccountConfig(
        id: "cc3", provider: .claude, displayName: "cc3", cliProxyURL: "http://127.0.0.1:1")])
    let coordinator = RefreshCoordinator(
        store: store, collector: UsageCollector(poolClient: pool), config: config)
    let completion = Completion()
    let request = Task {
        _ = await coordinator.handle(.refresh)
        await completion.finish()
    }
    await pool.waitForCall()
    // The provider stays blocked. A response must not depend on its completion.
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await completion.returned)
    #expect(await pool.calls == 1)
    await pool.release()
    await request.value
    await coordinator.waitForRefresh()
}

@Test func pendingRefreshesShareOneReadAndPreserveTheCachedSnapshot() async throws {
    let pool = PausedPool()
    let cached = UsageSnapshot(generatedAt: Date(timeIntervalSince1970: 1_000), accounts: [])
    let store = SnapshotStore(initial: cached)
    let config = Config(accounts: [AccountConfig(
        id: "cc3", provider: .claude, displayName: "cc3", cliProxyURL: "http://127.0.0.1:1")])
    let coordinator = RefreshCoordinator(
        store: store, collector: UsageCollector(poolClient: pool), config: config)

    let first = await coordinator.handle(.refresh)
    await pool.waitForCall()
    let second = await coordinator.handle(.refresh)
    let snapshot = await coordinator.handle(.snapshot)
    #expect(first.isRefreshing && second.isRefreshing && snapshot.isRefreshing)
    #expect(first.body == second.body && first.body == snapshot.body)
    #expect(try UsageSnapshot.decoder().decode(UsageSnapshot.self, from: first.body).generatedAt == cached.generatedAt)
    #expect(await pool.calls == 1)

    await pool.release()
    await coordinator.waitForRefresh()
    // A click immediately after completion must not spend another usage request.
    let done = await coordinator.handle(.refresh)
    #expect(!done.isRefreshing)
    #expect(await pool.calls == 1)
    let fresh = try UsageSnapshot.decoder().decode(UsageSnapshot.self, from: done.body)
    #expect(fresh.accounts.first?.members?.first?.state == .ok)
}

@Test func hidingDuringARefreshSurvivesItsCompletion() async throws {
    let pool = PausedPool()
    let store = SnapshotStore(initial: .empty)
    let config = Config(accounts: [AccountConfig(
        id: "cc3", provider: .claude, displayName: "cc3", cliProxyURL: "http://127.0.0.1:1")])
    let coordinator = RefreshCoordinator(
        store: store, collector: UsageCollector(poolClient: pool), config: config,
        saveConfig: { _ in })
    _ = await coordinator.handle(.refresh)
    await pool.waitForCall()
    _ = await coordinator.handle(.setHidden(id: "cc3", hidden: true))
    await pool.release()
    await coordinator.waitForRefresh()

    let response = await coordinator.handle(.snapshot)
    let hidden = try UsageSnapshot.decoder().decode(UsageSnapshot.self, from: response.body)
    #expect(hidden.accounts.isEmpty)
    #expect(hidden.hidden?.map(\.id) == ["cc3"])
    #expect(await pool.calls == 1)

    let showing = await coordinator.handle(.setHidden(id: "cc3", hidden: false))
    #expect(showing.isRefreshing)
    await pool.waitForCall(2)
    await pool.release()
    await coordinator.waitForRefresh()
    #expect(await store.snapshot().accounts.map(\.id) == ["cc3"])
}

/// A real socket exercises URLSession's timeout, including its session defaults.
private final class SlowProxy: @unchecked Sendable {
    let listener: NWListener
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let isList = String(decoding: data ?? Data(), as: UTF8.self).contains("GET /v0/management/auth-files")
                Task {
                    try? await Task.sleep(for: .seconds(16))
                    let body: String
                    if isList {
                        body = #"{"files":[{"auth_index":"a1","provider":"claude","email":"alice@example.com"}]}"#
                    } else {
                        let usage = #"{"five_hour":{"utilization":40},"seven_day":null}"#
                        body = String(decoding: try! JSONSerialization.data(withJSONObject: [
                            "status_code": 200, "body": usage,
                        ]), as: UTF8.self)
                    }
                    let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready: continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }
}

@Test func aRemoteProxyMayTakeLongerThanFifteenSecondsPerCall() async throws {
    let proxy = try SlowProxy()
    defer { proxy.listener.cancel() }
    let port = try await proxy.start()
    let key = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try "fixture-key".write(to: key, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: key) }
    let account = AccountConfig(
        id: "slow-test", provider: .claude, displayName: "slow",
        cliProxyURL: "http://127.0.0.1:\(port)", cliProxyKeyFile: key.path)

    let reading = try await CLIProxyClient().fetch(account)

    #expect(reading.members?.map(\.state) == [.ok])
    #expect(reading.members?.first?.windows.first?.usedFraction == 0.4)
}
