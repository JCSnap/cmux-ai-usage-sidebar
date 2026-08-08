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

    init(port: UInt16, store: SnapshotStore) throws {
        self.store = store
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
        // Read the request line and discard it. The daemon serves one document,
        // so routing on the path would add nothing.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] _, _, _, _ in
            guard let self else { return }
            Task {
                let body = await self.store.body()
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
    let snapshot = await collector.collect(config)
    FileHandle.standardOutput.write(try UsageSnapshot.encoder().encode(snapshot))
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
}

// Complete the first provider refresh before opening the port. Otherwise the
// installer and sidebar can observe and cache a placeholder empty snapshot.
let store = SnapshotStore(initial: await collector.collect(config))
let server = try UsageServer(port: config.port, store: store)
server.start()
FileHandle.standardError.write(Data(
    "aiusaged: serving \(config.accounts.count) accounts on 127.0.0.1:\(config.port)\n".utf8))

while true {
    await store.update(await collector.collect(config))
    try await Task.sleep(for: .seconds(config.refreshSeconds))
}
