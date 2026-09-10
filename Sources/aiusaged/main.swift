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
    private let store: SnapshotStore
    private let listener: NWListener
    private let onRefresh: (@Sendable () async -> Data)?

    init(port: UInt16, store: SnapshotStore, onRefresh: (@Sendable () async -> Data)? = nil) throws {
        self.store = store
        self.onRefresh = onRefresh
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
        // Read the request line to determine whether a full on-demand refresh was requested.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] content, _, _, _ in
            guard let self else { return }
            Task {
                let requestLine = content.flatMap { data in
                    String(data: data, encoding: .utf8)?.components(separatedBy: "\r\n").first
                } ?? ""
                let isRefresh = requestLine.hasPrefix("POST") || requestLine.contains("/refresh")
                let body: Data
                if isRefresh, let onRefresh = self.onRefresh {
                    body = await onRefresh()
                } else {
                    body = await self.store.body()
                }
                let header = """
                HTTP/1.1 200 OK\r
                Content-Type: application/json; charset=utf-8\r
                Content-Length: \(body.count)\r
                Cache-Control: no-store\r
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

/// Coordinates background and on-demand provider fetches.
///
/// Refreshes are coalesced so concurrent requests share a single fetch task,
/// and debounced so rapid manual refreshes do not flood provider APIs.
actor RefreshCoordinator {
    private let store: SnapshotStore
    private let collector: UsageCollector
    private let config: Config
    private var inFlight: Task<Data, Never>?
    private var lastRefresh: Date = .distantPast

    init(store: SnapshotStore, collector: UsageCollector, config: Config) {
        self.store = store
        self.collector = collector
        self.config = config
    }

    func refresh(force: Bool = false) async -> Data {
        if let inFlight {
            return await inFlight.value
        }
        if !force && Date().timeIntervalSince(lastRefresh) < 60.0 {
            return await store.body()
        }
        let task = Task { () -> Data in
            let prev = await store.snapshot()
            let newSnapshot = await collector.collect(config, previous: prev)
            await store.update(newSnapshot)
            return await store.body()
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        lastRefresh = Date()
        return result
    }
}

// Complete the first provider refresh before opening the port. Otherwise the
// installer and sidebar can observe and cache a placeholder empty snapshot.
// Pass in any cached snapshot so restarts never wipe out valid numbers on failure.
let cached = SnapshotStore.loadCache() ?? .empty
let snapshot = await collector.collect(config, previous: cached)
let store = SnapshotStore(initial: snapshot, cachePath: Config.cachePath)
let coordinator = RefreshCoordinator(store: store, collector: collector, config: config)
let server = try UsageServer(port: config.port, store: store, onRefresh: {
    await coordinator.refresh()
})
server.start()
FileHandle.standardError.write(Data(
    "aiusaged: serving \(config.accounts.count) accounts on 127.0.0.1:\(config.port)\n".utf8))

// Sleep first. The snapshot above is one cycle old at most, so collecting again
// here would call every vendor twice within a second of start.
while true {
    try await Task.sleep(for: .seconds(config.refreshSeconds))
    _ = await coordinator.refresh(force: true)
}
