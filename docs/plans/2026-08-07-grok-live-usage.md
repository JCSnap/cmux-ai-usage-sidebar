# Grok Live Usage Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Discover Grok profiles under `~/.grok*`, fetch their live weekly credit usage directly from Grok's billing API, and render them in the existing cmux usage sidebar.

**Architecture:** Extend the shared provider/config models with Grok, then add a `GrokClient` that owns credential parsing, OIDC refresh, billing request construction, and payload conversion. Keep network calls in the daemon; the extension continues to receive only normalized `UsageSnapshot` JSON over loopback.

**Tech Stack:** Swift 6, Foundation `URLSession`, Swift Testing, JSON Codable/`JSONSerialization`, existing `UsageModels` and `UsageFetch` packages.

---

### Task 1: Add Grok to the shared wire model

**Files:**
- Modify: `Sources/UsageModels/UsageSnapshot.swift`
- Regenerate: `AIUsageSidebar/SampleSidebarExtension/Model/UsageSnapshot.swift`
- Test: `Tests/UsageFetchTests/UsageFetchTests.swift`

**Step 1: Write the failing wire-round-trip test**

Add a Grok account to `snapshotSurvivesAWireRoundTrip` and assert that the
decoded provider and window survive:

```swift
UsageAccount(
    id: "grok", provider: .grok, displayName: "grok", plan: "SuperGrok",
    email: "person@example.com", state: .ok,
    windows: [UsageWindow(label: "7d", usedFraction: 0.42)])
```

**Step 2: Run the focused test to verify it fails**

Run: `swift test --filter snapshotSurvivesAWireRoundTrip`

Expected: compilation fails because `UsageProvider.grok` does not exist.

**Step 3: Add the minimal provider case**

In `Sources/UsageModels/UsageSnapshot.swift`, add:

```swift
case grok
```

and map it to `"Grok"` in `displayName`.

**Step 4: Synchronize the extension's generated model**

Run: `./scripts/sync-models.sh`

Expected: the generated extension model gains the same provider case.

**Step 5: Run the focused test**

Run: `swift test --filter snapshotSurvivesAWireRoundTrip`

Expected: PASS.

**Step 6: Commit**

```bash
git add Sources/UsageModels/UsageSnapshot.swift \
  AIUsageSidebar/SampleSidebarExtension/Model/UsageSnapshot.swift \
  Tests/UsageFetchTests/UsageFetchTests.swift
git commit -m "feat: add Grok to the usage wire model"
```

### Task 2: Discover Grok profiles and encode their configuration

**Files:**
- Modify: `Sources/UsageFetch/Config.swift`
- Modify: `Sources/UsageFetch/Discovery.swift`
- Test: `Tests/UsageFetchTests/UsageFetchTests.swift`

**Step 1: Write failing discovery tests**

Add tests for the pure mapping helper:

```swift
@Test func discoveredGrokPathsAreStableAndUseTildes() {
    let accounts = Discovery.grokAccounts(
        directories: ["/Users/jane/.grok", "/Users/jane/.grok-work"],
        home: "/Users/jane")
    #expect(accounts.map(\.id) == ["grok", "grok-2"])
    #expect(accounts.map(\.grokHome) == ["~/.grok", "~/.grok-work"])
}
```

Add a temporary-home integration test that creates `.grok/auth.json`, calls
the directory scanner, and verifies unrelated directories are excluded.

**Step 2: Run the focused discovery tests to verify they fail**

Run: `swift test --filter Grok`

Expected: compilation fails because `grokHome` and Grok discovery helpers do
not exist.

**Step 3: Extend account configuration**

Add this optional field and initializer argument in `AccountConfig`:

```swift
/// Grok: directory that holds `auth.json` (the `GROK_HOME` value).
public let grokHome: String?
```

Keep the field optional so existing user config files decode unchanged.

**Step 4: Add Grok discovery**

Implement:

```swift
static func grokDirectories(home: String) -> [String] {
    childDirectories(of: home, prefix: ".grok")
        .filter { FileManager.default.fileExists(atPath: $0 + "/auth.json") }
}

static func grokAccounts(directories: [String], home: String) -> [AccountConfig] {
    directories.enumerated().map { index, path in
        AccountConfig(
            id: numbered("grok", index), provider: .grok,
            displayName: numbered("grok", index),
            grokHome: tilde(path, home: home))
    }
}
```

Append these accounts in `Discovery.accounts(home:)` after Codex and before
Antigravity.

**Step 5: Run discovery tests and then the full suite**

Run: `swift test --filter Grok && swift test`

Expected: all tests PASS.

**Step 6: Commit**

```bash
git add Sources/UsageFetch/Config.swift Sources/UsageFetch/Discovery.swift \
  Tests/UsageFetchTests/UsageFetchTests.swift
git commit -m "feat: discover Grok account stores"
```

### Task 3: Parse Grok credentials and billing payloads

**Files:**
- Modify: `Sources/UsageFetch/Providers.swift`
- Test: `Tests/UsageFetchTests/UsageFetchTests.swift`

**Step 1: Write failing credential parsing tests**

Build an in-memory auth object with the real shape but fake tokens:

```swift
let auth: [String: Any] = [
    "https://auth.x.ai::client": [
        "key": "access", "refresh_token": "refresh",
        "expires_at": "2026-08-07T21:26:17Z",
        "email": "person@example.com",
        "oidc_issuer": "https://auth.x.ai",
        "oidc_client_id": "client",
    ]
]
let credential = try #require(GrokClient.credential(in: auth))
#expect(credential.accessToken == "access")
#expect(credential.email == "person@example.com")
```

Also test that empty objects and entries without both an access token and a
usable refresh path return no credential.

**Step 2: Run the credential tests to verify RED**

Run: `swift test --filter grokCredential`

Expected: compilation fails because `GrokClient` does not exist.

**Step 3: Implement the credential value and parser**

Add a private `GrokCredential` value containing access token, refresh token,
expiry, email, issuer, and client ID. Add an internal pure parser that selects
the first valid credential entry in stable key order. Never include token
values in descriptions or thrown errors.

**Step 4: Run the credential tests to verify GREEN**

Run: `swift test --filter grokCredential`

Expected: PASS.

**Step 5: Write failing billing conversion tests**

Use an in-memory payload matching the observed response:

```swift
let payload: [String: Any] = ["config": [
    "creditUsagePercent": 42.0,
    "currentPeriod": [
        "type": "USAGE_PERIOD_TYPE_WEEKLY",
        "start": "2026-08-01T19:17:43.386846+00:00",
        "end": "2026-08-08T19:17:43.386846+00:00",
    ],
]]
let reading = try GrokClient.reading(from: payload, email: "person@example.com")
#expect(reading.email == "person@example.com")
#expect(reading.windows[0].label == "7d")
#expect(reading.windows[0].usedFraction == 0.42)
#expect(reading.windows[0].resetsAt != nil)
```

Add cases for percentage clamping, absent `config`, and an unsupported/missing
period that falls back to `"—"` while preserving a valid meter.

**Step 6: Run the billing conversion tests to verify RED**

Run: `swift test --filter grokBilling`

Expected: compilation fails because `reading(from:email:)` does not exist.

**Step 7: Implement minimal billing conversion**

Parse `creditUsagePercent`, divide by 100, derive the short duration label
from start/end when both parse, and use `currentPeriod.end` as `resetsAt`.
Throw `FetchError.badPayload` if the aggregate percentage is absent.

**Step 8: Run all Task 3 tests**

Run: `swift test --filter grok`

Expected: PASS.

**Step 9: Commit**

```bash
git add Sources/UsageFetch/Providers.swift Tests/UsageFetchTests/UsageFetchTests.swift
git commit -m "feat: parse Grok credentials and billing usage"
```

### Task 4: Fetch billing directly and refresh expired OAuth tokens

**Files:**
- Modify: `Sources/UsageFetch/Providers.swift`
- Modify: `Sources/UsageFetch/Support.swift`
- Test: `Tests/UsageFetchTests/UsageFetchTests.swift`

**Step 1: Write failing request-construction tests**

Verify the request URL and authorization header without performing network
I/O:

```swift
let request = GrokClient.billingRequest(accessToken: "access")
#expect(request.url?.absoluteString
    == "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
```

Verify the refresh request posts `grant_type=refresh_token`, `refresh_token`,
and `client_id` to `https://auth.x.ai/oauth2/token`.

**Step 2: Run request tests to verify RED**

Run: `swift test --filter grokRequest`

Expected: compilation fails because the request helpers do not exist.

**Step 3: Add status-aware HTTP support**

Add an `Http.response(_:)` helper returning `(Data, HTTPURLResponse)`. Refactor
`Http.data(_:)` to use it while preserving existing error behavior. This lets
the Grok client distinguish a 401 from other failures without duplicating the
URLSession setup.

**Step 4: Implement request helpers and refresh**

Construct the billing GET and refresh form requests. If the stored access
token is expired, refresh first. Otherwise call billing directly; on 401,
refresh once and retry once. Decode the refreshed access and refresh tokens,
then atomically update the matching issuer entry in `auth.json`; xAI rotates
refresh tokens, so keeping the result only in memory breaks the next process.

**Step 5: Register the provider client**

Add `.grok: GrokClient()` to `UsageCollector.clients`.

**Step 6: Run focused and full tests**

Run: `swift test --filter grok && swift test`

Expected: all tests PASS with no warnings.

**Step 7: Commit**

```bash
git add Sources/UsageFetch/Providers.swift Sources/UsageFetch/Support.swift \
  Sources/UsageFetch/UsageCollector.swift Tests/UsageFetchTests/UsageFetchTests.swift
git commit -m "feat: fetch live Grok billing usage"
```

### Task 5: Document, synchronize, and verify the integration

**Files:**
- Modify: `README.md`
- Modify: `skills/cmux-ai-usage-setup/SKILL.md`
- Verify: `AIUsageSidebar/SampleSidebarExtension/Model/UsageSnapshot.swift`

**Step 1: Update user documentation**

Document Grok in the overview, architecture, discovery description, sample
config, credential table, and endpoint table. State that the endpoint is
private and may change. Add a sample entry:

```json
{ "id": "grok", "provider": "grok", "displayName": "grok",
  "grokHome": "~/.grok" }
```

Update the setup skill's account discovery/config guidance so fresh installs
include Grok automatically.

**Step 2: Synchronize the shared model**

Run: `./scripts/sync-models.sh`

Expected: no unexpected diff beyond the Grok provider case.

**Step 3: Run static and automated verification**

Run:

```bash
git diff --check
swift test
swift build
```

Expected: all commands exit 0.

**Step 4: Run a credential-safe live smoke test**

Run: `swift run aiusaged --once | jq '.accounts[] | select(.provider == "grok")'`

Expected: a Grok account with state `ok`, a weekly window, and no token fields.
If the live private API has changed, capture the sanitized status/body shape
and fix only the adapter boundary.

**Step 5: Commit**

```bash
git add README.md skills/cmux-ai-usage-setup/SKILL.md \
  AIUsageSidebar/SampleSidebarExtension/Model/UsageSnapshot.swift
git commit -m "docs: explain Grok usage tracking"
```

### Task 6: Final review

**Files:**
- Review: all files changed since commit `2c6440a`

**Step 1: Inspect the complete diff**

Run: `git diff 2c6440a^..HEAD --stat && git diff 2c6440a^..HEAD --check`

Expected: only Grok integration, design/plan documentation, and generated
model changes appear; whitespace check passes.

**Step 2: Re-run final verification from a clean build state**

Run: `swift package clean && swift test && swift build`

Expected: all commands exit 0.

**Step 3: Confirm the worktree preserves unrelated files**

Run: `git status --short`

Expected: only the user's pre-existing untracked `.claude/` directory remains.
