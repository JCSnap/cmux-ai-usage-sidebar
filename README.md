# AI Usage Sidebar

A cmux sidebar that shows the rate-limit usage of every local AI agent account:
two Claude Code accounts, two Codex accounts, and two Antigravity accounts.

```
AI USAGE                              2 min ago  ⟳
────────────────────────────────────────────────
CLAUDE CODE
● cc1                                       pro
  5h   ▓▓░░░░░░░░░░░░░░░░               12%
  7d   ▓░░░░░░░░░░░░░░░░░                9%
○ cc2
  Not signed in

CODEX
● c1                                  education
  5h   ▓░░░░░░░░░░░░░░░░░                2%
  7d   ▓░░░░░░░░░░░░░░░░░                3%
● c2                                       plus
  7d   ░░░░░░░░░░░░░░░░░░                0%

ANTIGRAVITY
● agy1
  GEMINI MODELS
  weekly ▓░░░░░░░░░░░░░░░░               1%
  5h     ░░░░░░░░░░░░░░░░░               0%
  CLAUDE AND GPT MODELS
  weekly ░░░░░░░░░░░░░░░░░               0%
  5h     ░░░░░░░░░░░░░░░░░               0%
○ agy2
  Not signed in
```

## Architecture

Two components, because a cmux sidebar extension is sandboxed.

```
  aiusaged (LaunchAgent, unsandboxed)          AI Usage Sidebar.appex (sandboxed)
  ├── reads the login keychain                 ├── entitlement: network.client only
  ├── reads ~/.codex*/auth.json                │
  ├── refreshes the Antigravity token          │
  ├── calls the three usage APIs               │
  └── serves JSON on 127.0.0.1:47823  ────────▶└── polls that URL every 60s
```

The extension cannot read the keychain or the credential files, and App Groups
need a provisioning profile that a personal team does not get. An outgoing
loopback socket is the one channel that works with `network.client` alone. The
extension therefore never holds a token.

## Requirements

- macOS 14 or newer.
- **cmux 0.64.20 or newer.** Earlier builds have no sidebar extension point.
  Check with `cmux --version`.
- An Apple Development signing identity.

## Install

```bash
./scripts/fetch-sdk.sh        # vendor the cmux extension SDK (once)
./scripts/install-daemon.sh   # build + LaunchAgent + first snapshot
./scripts/install-app.sh      # build + register the extension
```

Then in cmux: click the puzzle button next to the sidebar help button, open
**Sidebar Extensions**, enable **AI Usage**, and choose the extension sidebar
provider from the same menu.

## Configure

`~/.config/ai-usage/config.json` is written on first run. It lists one entry per
account:

```json
{
  "port": 47823,
  "refreshSeconds": 300,
  "accounts": [
    { "id": "cc1", "provider": "claude", "displayName": "cc1",
      "keychainService": "Claude Code-credentials" },
    { "id": "c1", "provider": "codex", "displayName": "c1",
      "codexHome": "~/.codex" },
    { "id": "agy1", "provider": "antigravity", "displayName": "agy1",
      "home": "~" }
  ]
}
```

Each provider reads a different credential store, which is why the fields differ:

| provider | field | credential |
|---|---|---|
| `claude` | `keychainService` | login keychain item |
| `codex` | `codexHome` | `$CODEX_HOME/auth.json` |
| `antigravity` | `home` | `<home>/.gemini/antigravity-cli/antigravity-oauth-token` |

To find the keychain service name for a second Claude account, run:

```bash
security dump-keychain | grep -o '"Claude Code[^"]*"' | sort -u
```

Claude Code derives the suffix from `CLAUDE_CONFIG_DIR`.

## Endpoints

Each provider exposes usage over its own OAuth token.

| provider | request |
|---|---|
| Claude | `GET api.anthropic.com/api/oauth/usage`, header `anthropic-beta: oauth-2025-04-20` |
| Codex | `GET chatgpt.com/backend-api/wham/usage`, header `chatgpt-account-id` |
| Antigravity | `POST cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` |

Two behaviours are easy to misdiagnose:

- The Antigravity endpoint answers `403 PERMISSION_DENIED` unless the
  `User-Agent` names the antigravity client. It is client sniffing, not a
  missing OAuth scope.
- A logged-out Claude profile still has a keychain item, holding only
  `mcpOAuth`. The item existing is not proof of a login.

The Antigravity endpoint is `v1internal:` and can change without notice.

## Develop

```bash
swift build && swift test          # daemon
./.build/debug/aiusaged --once     # print one snapshot and exit
./scripts/sync-models.sh           # after editing Sources/UsageModels
```

The extension target keeps a generated copy of the wire types, because it is a
separate Xcode target and cannot link the SPM library. `sync-models.sh` copies
them; do not edit the generated file.

## Layout

```
Sources/UsageModels     wire types, shared by both sides
Sources/UsageFetch      credential access and provider HTTP
Sources/aiusaged        refresh loop and loopback server
AIUsageSidebar/         Xcode project: containing app + sidebar extension
vendor/CmuxExtensionKit copy of the cmux extension SDK
```
