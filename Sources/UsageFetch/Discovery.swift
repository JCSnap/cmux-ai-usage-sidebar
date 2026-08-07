import Foundation
import UsageModels

/// Finds the agent accounts that exist on this machine.
///
/// Every agent CLI supports more than one account by pointing an environment
/// variable at a second store: `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GROK_HOME`,
/// and for Antigravity a whole `HOME` override. Those names are the user's
/// choice, so a shipped account list only ever fits the machine it was written
/// on. Discovery reads the stores that are actually present and builds the list
/// from them.
///
/// The scan is deliberately shallow. It looks at the login keychain and at the
/// direct children of the home directory, never deeper, so it stays fast and
/// cannot wander into unrelated projects.
public enum Discovery {
    /// The path Antigravity keeps its token at, relative to its `HOME`.
    ///
    /// This is not `.gemini/oauth_creds.json`. That file belongs to gemini-cli
    /// and expires independently of Antigravity.
    static let antigravityTokenPath = ".gemini/antigravity-cli/antigravity-oauth-token"

    public static func accounts(home: String = NSHomeDirectory()) -> [AccountConfig] {
        claudeAccounts(services: claudeKeychainServices())
            + codexAccounts(directories: codexDirectories(home: home), home: home)
            + grokAccounts(directories: grokDirectories(home: home), home: home)
            + antigravityAccounts(homes: antigravityHomes(home: home), home: home)
    }

    // MARK: - Claude Code

    /// Claude Code stores its OAuth blob in the login keychain. A non-default
    /// `CLAUDE_CONFIG_DIR` gets a suffix that Claude Code derives itself, so the
    /// suffix cannot be computed here. Read the item names instead.
    static func claudeKeychainServices() -> [String] {
        guard let dump = Shell.run("/usr/bin/security", ["dump-keychain"]) else { return [] }
        return claudeServices(inKeychainDump: dump)
    }

    /// Pulls the Claude service names out of a `security dump-keychain` listing.
    ///
    /// The dump prints one attribute per line, in the form
    /// `"svce"<blob>="Claude Code-credentials-1a2b3c"`.
    static func claudeServices(inKeychainDump dump: String) -> [String] {
        var found: Set<String> = []
        for line in dump.split(separator: "\n") where line.contains("Claude Code-credentials") {
            // Take the quoted run that holds the name, not the `"svce"` key.
            let quoted = line.split(separator: "\"").map(String.init)
            for part in quoted where part.hasPrefix("Claude Code-credentials") {
                found.insert(part)
            }
        }
        // The unsuffixed item is the default profile, so it sorts first.
        return found.sorted { ($0.count, $0) < ($1.count, $1) }
    }

    static func claudeAccounts(services: [String]) -> [AccountConfig] {
        services.enumerated().map { index, service in
            AccountConfig(
                id: numbered("claude", index),
                provider: .claude,
                displayName: numbered("claude", index),
                keychainService: service)
        }
    }

    // MARK: - Codex

    /// Codex keeps a plain `auth.json` under `CODEX_HOME`, so a directory that
    /// holds that file is an account.
    static func codexDirectories(home: String) -> [String] {
        childDirectories(of: home, prefix: ".codex")
            .filter { FileManager.default.fileExists(atPath: $0 + "/auth.json") }
    }

    static func codexAccounts(directories: [String], home: String) -> [AccountConfig] {
        directories.enumerated().map { index, path in
            AccountConfig(
                id: numbered("codex", index),
                provider: .codex,
                displayName: numbered("codex", index),
                codexHome: tilde(path, home: home))
        }
    }

    // MARK: - Grok

    /// Grok keeps its OAuth credential under `GROK_HOME`, using the same
    /// direct-child convention as Codex for additional profiles.
    static func grokDirectories(home: String) -> [String] {
        childDirectories(of: home, prefix: ".grok")
            .filter { FileManager.default.fileExists(atPath: $0 + "/auth.json") }
    }

    static func grokAccounts(directories: [String], home: String) -> [AccountConfig] {
        directories.enumerated().map { index, path in
            AccountConfig(
                id: numbered("grok", index),
                provider: .grok,
                displayName: numbered("grok", index),
                grokHome: tilde(path, home: home))
        }
    }

    // MARK: - Antigravity

    /// Antigravity has no config-directory variable. A second account needs a
    /// second `HOME`, so both the real home and any home-shaped child of it are
    /// candidates.
    static func antigravityHomes(home: String) -> [String] {
        ([home] + childDirectories(of: home, prefix: "."))
            .filter { FileManager.default.fileExists(atPath: "\($0)/\(antigravityTokenPath)") }
    }

    static func antigravityAccounts(homes: [String], home: String) -> [AccountConfig] {
        homes.enumerated().map { index, path in
            AccountConfig(
                id: numbered("antigravity", index),
                provider: .antigravity,
                displayName: numbered("antigravity", index),
                home: tilde(path, home: home))
        }
    }

    // MARK: - Shared

    /// Names the first account of a provider plainly and numbers the rest.
    /// The result is `claude`, `claude-2`, `claude-3`, and so on.
    static func numbered(_ base: String, _ index: Int) -> String {
        index == 0 ? base : "\(base)-\(index + 1)"
    }

    /// Writes a path back in `~` form, because the config file is meant to be
    /// read and edited by a person.
    static func tilde(_ path: String, home: String) -> String {
        path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }

    private static func childDirectories(of home: String, prefix: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted().map { "\(home)/\($0)" }
    }
}
