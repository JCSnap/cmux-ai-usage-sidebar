import Foundation

/// The OAuth client that Antigravity itself uses.
///
/// A refresh needs the client that issued the token, not an arbitrary one. The
/// Antigravity CLI ships this pair inside its own binary, so it is a
/// client-distributed value rather than a user secret. It is still not this
/// project's value to republish, and a copy in source goes stale the moment
/// Google rotates it. Read it from the installed CLI instead.
struct AntigravityCredentials: Codable, Sendable, Hashable {
    let clientID: String
    let clientSecret: String
}

/// Finds the Antigravity OAuth client, and remembers the one that works.
enum AntigravityCredentialStore {
    static let cachePath = NSString(string: "~/.config/ai-usage/antigravity-client.json")
        .expandingTildeInPath

    /// Where the CLI usually installs. `which` is not enough on its own, because
    /// a LaunchAgent runs with a minimal `PATH` that holds none of these.
    static let searchPaths = [
        "~/.local/bin/agy", "/usr/local/bin/agy", "/opt/homebrew/bin/agy",
        "~/.antigravity/bin/agy",
    ]

    /// Where to look, in order, each source evaluated only if the ones before it
    /// produced nothing that worked.
    ///
    /// The order is what keeps this cheap. Scanning the CLI means reading a
    /// 165 MB binary twice, which is fine once but not on every refresh, so the
    /// remembered pair has to be tried before the scan is ever started.
    static var sources: [@Sendable () -> [AntigravityCredentials]] {
        [
            { [fromEnvironment(), remembered()].compactMap { $0 } },
            { fromInstalledCLI() },
        ]
    }

    static func fromEnvironment() -> AntigravityCredentials? {
        let environment = ProcessInfo.processInfo.environment
        guard let id = environment["ANTIGRAVITY_CLIENT_ID"],
              let secret = environment["ANTIGRAVITY_CLIENT_SECRET"]
        else { return nil }
        return AntigravityCredentials(clientID: id, clientSecret: secret)
    }

    static func remembered() -> AntigravityCredentials? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)) else { return nil }
        return try? JSONDecoder().decode(AntigravityCredentials.self, from: data)
    }

    /// Stores the pair that refreshed a token, so later runs skip the search.
    static func remember(_ credentials: AntigravityCredentials) {
        guard remembered() != credentials else { return }
        let url = URL(fileURLWithPath: cachePath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(credentials).write(to: url)
    }

    static func fromInstalledCLI() -> [AntigravityCredentials] {
        guard let binary = installedCLI() else { return [] }
        return pairs(
            ids: scan(binary, pattern: idPattern),
            secrets: scan(binary, pattern: secretPattern))
    }

    static func installedCLI() -> String? {
        if let explicit = ProcessInfo.processInfo.environment["ANTIGRAVITY_CLI"] { return explicit }
        let candidates = searchPaths.map(\.expandedPath)
            + [Shell.run("/usr/bin/which", ["agy"])].compactMap { $0 }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// A Google OAuth client secret is `GOCSPX-` and 28 more characters. Pinning
    /// the length matters: the binary stores the secrets back to back, so an
    /// open-ended pattern swallows the next one too.
    static let secretPattern = "GOCSPX-[A-Za-z0-9_-]{28}"
    static let idPattern = "[0-9]{6,}-[a-z0-9]{20,40}\\.apps\\.googleusercontent\\.com"

    static func scan(_ path: String, pattern: String) -> [String] {
        var environment = ProcessInfo.processInfo.environment
        // Treat the binary as bytes. A locale that validates UTF-8 makes grep
        // give up on the first invalid sequence, which a binary is full of.
        environment["LC_ALL"] = "C"
        guard let output = Shell.run(
            "/usr/bin/grep", ["-aoE", pattern, path], environment: environment)
        else { return [] }
        return distinctLines(output)
    }

    static func distinctLines(_ output: String) -> [String] {
        var seen: Set<String> = []
        return output.split(separator: "\n").map(String.init).filter { seen.insert($0).inserted }
    }

    /// Pairs every id with every secret. There are at most a handful, and one
    /// refresh call each settles which is right.
    static func pairs(ids: [String], secrets: [String]) -> [AntigravityCredentials] {
        ids.flatMap { id in
            secrets.map { AntigravityCredentials(clientID: id, clientSecret: $0) }
        }
    }
}
