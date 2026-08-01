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

    /// Must match `port` in ~/.config/ai-usage/config.json.
    private let endpoint = URL(string: "http://127.0.0.1:47823/")!
    private let interval = Duration.seconds(60)
    private var poller: Task<Void, Never>?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func start() {
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: self?.interval ?? .seconds(60))
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    func refresh() async {
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
}
