import Foundation
import Testing
import UsageModels
@testable import UsageFetch

@Test func windowLabelsDeriveFromSeconds() {
    #expect(CodexClient.label(forWindowSeconds: 18_000) == "5h")
    #expect(CodexClient.label(forWindowSeconds: 604_800) == "7d")
    #expect(CodexClient.label(forWindowSeconds: 3_600) == "1h")
    #expect(CodexClient.label(forWindowSeconds: 0) == "—")
}

@Test func antigravityWindowWordsBecomeShortLabels() {
    // Antigravity says "weekly" where the others report a length. One column
    // width has to fit every provider, so the words normalise to the same form.
    #expect(AntigravityClient.label(forWindow: "weekly") == "7d")
    #expect(AntigravityClient.label(forWindow: "5h") == "5h")
    #expect(AntigravityClient.label(forWindow: nil) == "—")
    // An unknown word passes through rather than becoming "—": showing the raw
    // value is more useful than hiding that a new window kind appeared.
    #expect(AntigravityClient.label(forWindow: "hourly") == "hourly")
}

@Test func usedPercentClampsAndRounds() {
    #expect(UsageWindow(label: "5h", usedFraction: 0.094).usedPercent == 9)
    #expect(UsageWindow(label: "5h", usedFraction: 1.4).usedPercent == 100)
    #expect(UsageWindow(label: "5h", usedFraction: -0.2).usedPercent == 0)
}

@Test func worstWindowPicksTheFullestOne() {
    let account = UsageAccount(
        id: "cc1", provider: .claude, displayName: "cc1", state: .ok,
        windows: [
            UsageWindow(label: "5h", usedFraction: 0.09),
            UsageWindow(label: "7d", usedFraction: 0.62),
        ])
    #expect(account.worstWindow?.label == "7d")
}

@Test func iso8601ParsesBothFractionalAndPlainForms() {
    // Anthropic sends fractional seconds; Google does not.
    #expect(Date.fromISO8601("2026-08-06T20:00:00.027245+00:00") != nil)
    #expect(Date.fromISO8601("2026-08-03T14:02:16Z") != nil)
    #expect(Date.fromISO8601("not a date") == nil)
}

@Test func snapshotSurvivesAWireRoundTrip() throws {
    let snapshot = UsageSnapshot(generatedAt: Date(timeIntervalSince1970: 1_785_575_910), accounts: [
        UsageAccount(
            id: "agy1", provider: .antigravity, displayName: "agy1", state: .ok,
            windows: [UsageWindow(group: "Gemini Models", label: "weekly", usedFraction: 0.0135)]),
        UsageAccount(id: "cc2", provider: .claude, displayName: "cc2", state: .signedOut),
    ])
    let data = try UsageSnapshot.encoder().encode(snapshot)
    let decoded = try UsageSnapshot.decoder().decode(UsageSnapshot.self, from: data)
    #expect(decoded == snapshot)
    #expect(decoded.accounts[0].windows[0].group == "Gemini Models")
    #expect(decoded.accounts[1].state == .signedOut)
}

@Test func keychainDumpYieldsEveryClaudeProfile() {
    // A trimmed `security dump-keychain` listing. Each item prints one
    // attribute per line, and unrelated items share the same shape.
    let dump = """
        attributes:
            "svce"<blob>="Claude Code-credentials-1a2b3c"
            "acct"<blob>="jane"
        attributes:
            "svce"<blob>="Claude Code-credentials"
        attributes:
            "svce"<blob>="Chrome Safe Storage"
        """
    // The default profile has no suffix, and it sorts first so it becomes
    // "claude" rather than "claude-2".
    #expect(Discovery.claudeServices(inKeychainDump: dump)
        == ["Claude Code-credentials", "Claude Code-credentials-1a2b3c"])
}

@Test func discoveredAccountsAreNamedInAStableOrder() {
    let accounts = Discovery.claudeAccounts(
        services: ["Claude Code-credentials", "Claude Code-credentials-1a2b3c"])
    #expect(accounts.map(\.id) == ["claude", "claude-2"])
    #expect(accounts.allSatisfy { $0.keychainService != nil })
}

@Test func discoveredPathsAreWrittenBackInTildeForm() {
    // The config file is meant to be read and edited, so an absolute home path
    // would be noise.
    let codex = Discovery.codexAccounts(
        directories: ["/Users/jane/.codex", "/Users/jane/.codex-work"], home: "/Users/jane")
    #expect(codex.map(\.codexHome) == ["~/.codex", "~/.codex-work"])

    let antigravity = Discovery.antigravityAccounts(
        homes: ["/Users/jane", "/Users/jane/.agy-home-2"], home: "/Users/jane")
    #expect(antigravity.map(\.home) == ["~", "~/.agy-home-2"])
    #expect(antigravity.map(\.id) == ["antigravity", "antigravity-2"])
}

@Test func discoveryFindsNothingWhenNoAgentIsInstalled() {
    // An empty result must stay empty rather than fall back to an invented
    // account, because a phantom account reads as a broken login in the sidebar.
    #expect(Discovery.claudeServices(inKeychainDump: "") == [])
    #expect(Discovery.accounts(home: "/nonexistent-home").isEmpty
        || !Discovery.accounts(home: "/nonexistent-home").contains { $0.provider != .claude })
}
