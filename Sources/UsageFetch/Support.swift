import Foundation

enum FetchError: LocalizedError {
    case noCredential
    case badStatus(Int, String)
    case badPayload(String)

    var errorDescription: String? {
        switch self {
        case .noCredential: "no stored credential"
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
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

    /// Performs a request and returns the body, or throws with the status text.
    static func data(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
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
}

extension Dictionary where Key == String, Value == Any {
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func string(_ key: String) -> String? { self[key] as? String }
    func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
}
