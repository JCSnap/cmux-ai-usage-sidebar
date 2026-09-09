import Foundation
import Observation
import SwiftUI

/// Polls the local usage daemon and publishes the latest snapshot.
///
/// The extension is sandboxed. It cannot read the keychain or the credential
/// files, so it never sees a token: it only reads the daemon's JSON over
/// loopback, which the `network.client` entitlement permits.
@Observable
@MainActor
final class UsageStore {
    enum Health: Equatable {
        case loading
        case live
        /// The daemon is not answering. Almost always means it is not running.
        case unreachable(String)
    }

    private(set) var snapshot = UsageSnapshot.empty
    private(set) var health = Health.loading
    private(set) var isRefreshing = false

    /// Must match `port` in ~/.config/ai-usage/config.json.
    private let endpoint = URL(string: "http://127.0.0.1:47823/")!
    private let interval = Duration.seconds(60)
    private var poller: Task<Void, Never>?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func start() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchLatest()
                try? await Task.sleep(for: self?.interval ?? .seconds(60))
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    /// Background poll: quickly fetches the daemon's current snapshot.
    func fetchLatest() async {
        do {
            var request = URLRequest(url: endpoint)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, _) = try await session.data(for: request)
            snapshot = try UsageSnapshot.decoder().decode(UsageSnapshot.self, from: data)
            health = .live
        } catch {
            // Keep the last good snapshot on screen. A stale number beats an
            // empty panel, and the header shows how old it is.
            health = .unreachable(error.localizedDescription)
        }
    }

    /// On-demand refresh: tells the daemon to collect fresh usage from all providers.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            var request = URLRequest(url: endpoint.appendingPathComponent("refresh"))
            request.httpMethod = "POST"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, _) = try await session.data(for: request)
            snapshot = try UsageSnapshot.decoder().decode(UsageSnapshot.self, from: data)
            health = .live
        } catch {
            health = .unreachable(error.localizedDescription)
        }
    }
}
