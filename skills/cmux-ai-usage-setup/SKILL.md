---
name: cmux-ai-usage-setup
description: Installs and configures the cmux AI Usage Sidebar on this machine. It finds the local Claude Code, Codex, and Antigravity accounts, writes the account config, builds the sidebar extension with the correct signing team, and fixes the usual install failures. Use this skill whenever the user wants to install, set up, configure, rename accounts in, or repair the cmux AI usage sidebar or the aiusaged daemon, and also when they say the sidebar shows no accounts, shows the wrong accounts, shows an account twice, or says a daemon is unreachable.
---

# Set up the cmux AI Usage Sidebar

This project shows the rate-limit usage of every local AI agent account inside a
cmux sidebar. It has two parts. `aiusaged` is an unsandboxed LaunchAgent that
reads the credentials and calls each vendor API. The sidebar extension is
sandboxed and only reads `http://127.0.0.1:47823/`.

Two things in this project are specific to each machine: the Apple signing team,
and the list of accounts. Everything else is the same everywhere. Your work is to
get those two right and then hand the user the steps that only a person can do.

## What you cannot do

The last part of the install happens in the cmux settings window. You cannot
click it. Do not try to automate the cmux user interface. Write the steps out for
the user, then wait, then verify the result from the command line.

## Step 1. Check the prerequisites

Run these and read the results before you build anything. A wrong cmux version is
the single most common cause of an install that appears to work and then shows
nothing at all.

```bash
sw_vers -productVersion          # needs 14 or newer
cmux --version                   # needs 0.64.20 or newer
xcodebuild -version              # needs Xcode 16 or newer
swift --version
```

If cmux is older than 0.64.20, stop. That build has no sidebar extension point,
so nothing you install can appear. Tell the user to update cmux first.

## Step 2. Find the signing team

The project file holds the original author's team ID, which nobody else can sign
with. Read the user's own team ID from their development certificate:

```bash
security find-certificate -c "Apple Development" -p \
  | openssl x509 -noout -subject \
  | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p'
```

The `OU` field of an Apple Development certificate is the team ID. If the command
prints nothing, the user has no development certificate. They must open Xcode,
select Settings, then Accounts, and add their Apple ID. A free personal team is
sufficient. If the command prints more than one ID, ask the user which team to
use.

Export the ID for the build in step 5:

```bash
export DEVELOPMENT_TEAM=<the ID>
```

## Step 3. Build the daemon

```bash
./scripts/fetch-sdk.sh
./scripts/install-daemon.sh
```

`install-daemon.sh` builds `aiusaged`, installs it in `~/.local/bin`, starts the
LaunchAgent, and waits for the first snapshot. It writes a config file at
`~/.config/ai-usage/config.json` if none exists.

## Step 4. Get the account list right

This is the step that needs your judgment. Everything else is mechanical.

Ask the daemon what it can find:

```bash
~/.local/bin/aiusaged --discover
```

Discovery reads the login keychain for `Claude Code-credentials*` items, looks
for `auth.json` under each `~/.codex*` directory, and looks for an Antigravity
token under the home directory and its dot-directories. It names the first
account of each kind plainly and numbers the rest: `claude`, `claude-2`, `codex`,
`codex-2`.

Now reconcile that list with what the user actually has. Show them the result and
ask two questions.

**Is anything missing?** Discovery finds a store only when a credential exists in
it, so a signed-out account is invisible. That is usually correct. But if the
user wants a signed-out account listed, so that the sidebar reminds them to log
in, add it by hand. Each provider needs a different field:

| provider | field | value |
|---|---|---|
| `claude` | `keychainService` | the login keychain item name |
| `codex` | `codexHome` | the `CODEX_HOME` directory |
| `antigravity` | `home` | the `HOME` that account runs under |

To list the Claude keychain items directly:

```bash
security dump-keychain | grep -o '"Claude Code[^"]*"' | sort -u
```

Claude Code derives the suffix from `CLAUDE_CONFIG_DIR`, so the suffix cannot be
computed. Read it from the keychain.

**Are the names right?** `claude-2` is accurate but tells the user nothing. Ask
what they call each account. People usually have a shell alias per account, so
check `~/.zshrc` or `~/.bashrc` for the aliases they already use and offer those
names. Set both `id` and `displayName` to the chosen name. The sidebar shows
`displayName`, and it has room for roughly ten characters.

Write the result to `~/.config/ai-usage/config.json` and restart the daemon:

```bash
launchctl kickstart -k "gui/$UID/dev.jcsnap.aiusaged"
```

Then confirm every account reads. This is the real test, because it exercises the
credentials rather than the file:

```bash
curl -s http://127.0.0.1:47823/ | python3 -m json.tool
```

Each account reports `state` of `ok`, `signedOut`, or `error`. Treat `error` as a
problem to fix now; see the table at the end. Treat `signedOut` as a fact to
confirm with the user, because a logged-out Claude profile still keeps a keychain
item that holds only `mcpOAuth`.

## Step 5. Build and install the extension

```bash
./scripts/install-app.sh
```

The script uses `DEVELOPMENT_TEAM` from step 2. It builds the app, copies it to
`/Applications`, and opens it once, because macOS finds an extension only after
the containing app has run. It ends by listing the registered extension. If that
list is empty, the build did not sign, so re-read the error above it.

## Step 6. Hand the cmux steps to the user

Give the user these four steps verbatim. Step 1 is the one people miss: the
puzzle button does not exist until the experimental toggle is on, so without it
the user hunts for a button that is not there.

1. Open cmux Settings and select Advanced. Set the Extensions toggle to on.
2. Click the puzzle button, next to the sidebar help button.
3. Select Sidebar Extensions and enable AI Usage.
4. Select the extension sidebar provider from the same menu.

Tell them the sidebar replaces the built-in one, because cmux shows one sidebar
at a time. Their workspace list is not gone. It is rebuilt inside the extension,
above the usage section, with a divider they can drag.

## Troubleshooting

| symptom | cause | fix |
|---|---|---|
| No puzzle button in cmux | The Extensions experimental toggle is off | Settings, then Advanced, then set the toggle on |
| AI Usage listed two or three times | Launch Services registered the build copies as well as the installed app | Run `./scripts/install-app.sh` again; it unregisters the stale copies |
| Sidebar says the daemon is unreachable | The LaunchAgent is not running, or another process holds the port | Read `~/Library/Logs/ai-usage/aiusaged.log`; run `lsof -i :47823` |
| An account shows `error` with HTTP 403 on Antigravity | Something changed the `User-Agent` | The endpoint sniffs the client; it is not a missing OAuth scope |
| An account shows `error` with HTTP 401 | The stored token is dead | Log in again with that agent's own CLI, then restart the daemon |
| An account shows `signedOut` but the user is logged in | The config points at the wrong store | Re-run `aiusaged --discover` and compare the field for that provider |
| Nothing appears after enabling the extension | cmux is older than 0.64.20 | Update cmux |

## Verify before you report success

Do not tell the user the setup is done until all three of these hold. Report what
you checked, and name anything you could not check.

1. `curl -s http://127.0.0.1:47823/ | python3 -m json.tool` lists every account
   the user expects, with the names they chose.
2. `launchctl print "gui/$UID/dev.jcsnap.aiusaged" | grep state` shows the
   daemon running.
3. The user confirms the sidebar renders in cmux. You cannot see it, so ask.
