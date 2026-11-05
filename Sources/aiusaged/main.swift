import Foundation
import Network
import UsageFetch
import UsageModels

/// Minimal HTTP/1.1 responder bound to loopback.
///
/// The cmux sidebar extension is sandboxed, so it cannot read the credential
/// files or the keychain, and it has no App Group container to share (that
/// needs a provisioning profile). It can open an outgoing socket, so loopback
/// HTTP is the one channel that works with only `network.client`.
final class UsageServer: @unchecked Sendable {
    private let listener: NWListener
    private let onRequest: @Sendable (DaemonRequest) async -> DaemonResponse

    init(port: UInt16, onRequest: @escaping @Sendable (DaemonRequest) async -> DaemonResponse) throws {
        self.onRequest = onRequest
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .global())
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        // Read the request line to learn whether it asks for a refresh or a
        // visibility change rather than the current snapshot.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] content, _, _, _ in
            guard let self else { return }
            Task {
                let requestLine = content.flatMap { data in
                    String(data: data, encoding: .utf8)?.components(separatedBy: "\r\n").first
                } ?? ""
                let request = DaemonRequest(requestLine: requestLine)
                let response = await self.onRequest(request)
                let body = response.body
                let header = """
                HTTP/1.1 200 OK\r
                Content-Type: application/json; charset=utf-8\r
                Content-Length: \(body.count)\r
                Cache-Control: no-store\r
                X-Usage-Refreshing: \(response.isRefreshing)\r
                Connection: close\r
                \r

                """
                connection.send(
                    content: Data(header.utf8) + body,
                    completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

// MARK: - Entry point

let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--discover") {
    // Prints the accounts found on this machine, without reading or writing the
    // config file. Setup tooling uses this to propose a config the user can
    // rename before it is saved.
    FileHandle.standardOutput.write(try Config.discovered().encoded())
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
}

let config = try Config.load()
let collector = UsageCollector()

if config.accounts.isEmpty {
    FileHandle.standardError.write(Data("""
    aiusaged: no accounts configured. Run `aiusaged --discover` to see what this \
    machine has, then write \(Config.path).\n
    """.utf8))
}

if arguments.contains("--once") {
    // One-shot mode: print the snapshot and exit. Useful for testing the
    // credential path without running the agent, and for piping into a TUI.
    let cached = SnapshotStore.loadCache() ?? .empty
    let snapshot = await collector.collect(config, previous: cached)
    FileHandle.standardOutput.write(try UsageSnapshot.encoder().encode(snapshot))
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
}

// Serve cached readings during restart. Their timestamps and states stay intact.
// A first install still waits for real readings instead of serving an empty placeholder.
let cached = SnapshotStore.loadCache()
let store = SnapshotStore(initial: cached ?? .empty, cachePath: Config.cachePath)
// Reads the always-on machine's log when today's pool ledger misses midnight.
let seeds = config.poolDaySeeds ?? [:]
@Sendable func readSeed(_ pool: String) async -> String? {
    guard let argv = seeds[pool] else { return nil }
    return await CommandOutput.run(argv)
}
let coordinator = RefreshCoordinator(
    store: store, collector: collector, config: config, poolDayPath: PoolDayLedger.path,
    poolDaySeed: seeds.isEmpty ? nil : readSeed)
await coordinator.refresh(force: true)
if cached == nil { await coordinator.waitForRefresh() }
let server = try UsageServer(port: config.port, onRequest: { request in
    await coordinator.handle(request)
})
server.start()
FileHandle.standardError.write(Data(
    "aiusaged: serving \(config.visibleAccounts.count) accounts on 127.0.0.1:\(config.port)\n".utf8))

await coordinator.waitForRefresh()
while true {
    try await Task.sleep(for: .seconds(config.refreshSeconds))
    await coordinator.refresh(force: true)
    await coordinator.waitForRefresh()
}
