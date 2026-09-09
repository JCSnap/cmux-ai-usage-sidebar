import Foundation

enum FetchError: LocalizedError {
    case noCredential
    case noClientCredentials
    case badStatus(Int, String)
    case badPayload(String)

    var errorDescription: String? {
        switch self {
        case .noCredential: "no stored credential"
        case .noClientCredentials:
            "cannot find the Antigravity OAuth client. Install the antigravity CLI, "
                + "or set ANTIGRAVITY_CLIENT_ID and ANTIGRAVITY_CLIENT_SECRET."
        case let .badStatus(code, body): "HTTP \(code): \(body.prefix(160))"
        case let .badPayload(what): "unexpected payload: \(what)"
        }
    }
}

enum Shell {
    /// Reads a generic password from the login keychain.
    ///
    /// This shells out to `/usr/bin/security` on purpose. That binary already
    /// holds the ACL grant for the Claude Code items, so the read stays silent.
    /// A direct `SecItemCopyMatching` from this daemon is a different caller and
    /// makes macOS show an approval panel, which a background agent cannot answer.
    static func keychainPassword(service: String) -> String? {
        run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
    }

    /// Runs a command and returns its trimmed output, or nil if it fails.
    static func run(
        _ executable: String, _ arguments: [String], environment: [String: String]? = nil
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

enum Http {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// How many times one request is sent before its status is returned as the
    /// answer. Three means the first send plus two retries.
    static let attempts = 3
    /// Longest wait between two attempts. A vendor can name a whole minute in
    /// `Retry-After`, and waiting that long would hold the collect open.
    static let retryCeiling: TimeInterval = 8

    /// Performs a request without interpreting its status code. Providers that
    /// need status-aware recovery (such as an OAuth retry on 401) use this.
    ///
    /// A transient status is retried first. The usage endpoints are also called
    /// by each agent CLI, so a short burst can rate-limit this daemon for one
    /// call only. Retrying costs a second and saves a whole refresh cycle.
    static func response(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await retrying(request, send: once)
    }

    /// Sends the request once. No status is interpreted here.
    static func once(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw FetchError.badStatus(0, String(decoding: data, as: UTF8.self))
        }
        return (data, response)
    }

    /// Retry loop around one sender. `send` and `sleep` are injected so a test
    /// can drive the loop without a socket and without real time.
    static func retrying(
        _ request: URLRequest,
        sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 1
        while true {
            let (data, response) = try await send(request)
            guard attempt < attempts, isTransient(response.statusCode) else { return (data, response) }
            await sleep(backoff(
                retryAfter: response.value(forHTTPHeaderField: "Retry-After"), attempt: attempt))
            attempt += 1
        }
    }

    /// 429 is a rate limit and 5xx is the vendor, not the request. Both can
    /// clear on their own. Every other status is the answer to the call.
    static func isTransient(_ status: Int) -> Bool {
        status == 429 || (500..<600).contains(status)
    }

    /// The vendor `Retry-After` in seconds when it sends a usable one, else one
    /// second and then two. Always inside `retryCeiling`.
    static func backoff(retryAfter: String?, attempt: Int) -> TimeInterval {
        let named = retryAfter
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap(TimeInterval.init)
        let wait = named ?? pow(2, Double(attempt - 1))
        return min(max(wait, 0), retryCeiling)
    }

    /// Performs a request and returns the body, or throws with the status text.
    static func data(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await response(request)
        let code = response.statusCode
        guard (200..<300).contains(code) else {
            throw FetchError.badStatus(code, String(decoding: data, as: UTF8.self))
        }
        return data
    }

    static func json(_ request: URLRequest) async throws -> [String: Any] {
        let data = try await data(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.badPayload("not a JSON object")
        }
        return object
    }

    static func get(_ url: String, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    static func form(_ url: String, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data(components.percentEncodedQuery?.utf8 ?? "".utf8)
        return request
    }

    static func jsonPost(_ url: String, object: [String: Any]) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: object)
        return request
    }
}

extension Dictionary where Key == String, Value == Any {
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func string(_ key: String) -> String? { self[key] as? String }
    func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
}
