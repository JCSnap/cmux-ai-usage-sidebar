import Foundation

/// What a request to the loopback port asks for.
public enum DaemonRequest: Equatable, Sendable {
    /// The current snapshot, without a read.
    case snapshot
    /// A fresh read of every shown account.
    case refresh
    /// `POST /hide/<id>` and `POST /show/<id>`. They change the config file, so
    /// a plain GET never triggers them.
    case setHidden(id: String, hidden: Bool)

    /// Parses an HTTP request line such as `POST /hide/cc1 HTTP/1.1`.
    public init(requestLine: String) {
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let path = parts.count > 1 ? String(parts[1]) : "/"
        let segments = path.split(separator: "/").map {
            String($0).removingPercentEncoding ?? String($0)
        }
        if method == "POST", segments.count == 2, ["hide", "show"].contains(segments[0]) {
            self = .setHidden(id: segments[1], hidden: segments[0] == "hide")
        } else if method == "POST" || segments.first == "refresh" {
            self = .refresh
        } else {
            self = .snapshot
        }
    }
}
