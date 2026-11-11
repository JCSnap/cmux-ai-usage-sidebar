#!/usr/bin/env bash
# Builds the usage daemon and runs it as a LaunchAgent.
#
# The daemon must stay unsandboxed. It reads the login keychain and the CLI
# credential files, which a sandboxed process cannot do.
#
# The script refuses a checkout that is behind origin's default branch, because
# a stale build silently drops features such as the pool-day ledger. Pass
# --allow-stale to install it anyway.
set -euo pipefail

allow_stale=0
for arg in "$@"; do
    case "$arg" in
        --allow-stale) allow_stale=1 ;;
        *) echo "usage: $0 [--allow-stale]" >&2; exit 2 ;;
    esac
done

root="$(cd "$(dirname "$0")/.." && pwd)"
bin_dir="$HOME/.local/bin"
label="dev.jcsnap.aiusaged"
plist="$HOME/Library/LaunchAgents/$label.plist"
log_dir="$HOME/Library/Logs/ai-usage"

cd "$root"

echo "==> Checking that the checkout is current"
if git fetch --quiet origin 2>/dev/null; then
    default="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
    behind="$(git rev-list --count "HEAD..$default" 2>/dev/null || echo 0)"
    if [ "$behind" -gt 0 ]; then
        echo "This checkout is $behind commits behind $default." >&2
        git log --oneline "HEAD..$default" | head -5 >&2
        if [ "$allow_stale" -eq 0 ]; then
            echo "Update it first, or pass --allow-stale to install the older build." >&2
            exit 1
        fi
        echo "Installing the older build because of --allow-stale." >&2
    fi
else
    echo "Could not fetch origin. Installing without the freshness check." >&2
fi
commit="$(git rev-parse --short HEAD)"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    commit="$commit-dirty"
fi

echo "==> Building release binary"
swift build -c release --product aiusaged

echo "==> Installing to $bin_dir"
mkdir -p "$bin_dir" "$log_dir"
install -m 755 "$root/.build/release/aiusaged" "$bin_dir/aiusaged"

echo "==> Writing $plist"
mkdir -p "$(dirname "$plist")"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$bin_dir/aiusaged</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>AIUSAGED_COMMIT</key>
        <string>$commit</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$log_dir/aiusaged.log</string>
    <key>StandardErrorPath</key>
    <string>$log_dir/aiusaged.log</string>
</dict>
</plist>
PLIST

echo "==> Loading the agent"
launchctl bootout "gui/$UID/$label" 2>/dev/null || true
launchctl enable "gui/$UID/$label" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$plist"

echo "==> Waiting for the first snapshot"
port="$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.config/ai-usage/config.json")))["port"])' 2>/dev/null || echo 47823)"
for _ in $(seq 1 20); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$port/" >/dev/null 2>&1; then
        echo "Daemon is live on 127.0.0.1:$port"
        curl -fsS "http://127.0.0.1:$port/" | python3 -m json.tool | head -20
        exit 0
    fi
    sleep 1
done

echo "Daemon did not answer on port $port. Check $log_dir/aiusaged.log" >&2
exit 1
