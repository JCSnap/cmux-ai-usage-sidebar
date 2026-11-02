#!/usr/bin/env bash
# Builds `aiusage` and runs `aiusage proxy-steer` every 5 minutes as a LaunchAgent.
#
# Each run reads the aiusaged snapshot and sets the CLIProxyAPI routing weight
# of each pool login. The proxy must use `strategy: "weighted-round-robin"`.
# Install the daemon first with ./scripts/install-daemon.sh.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bin_dir="$HOME/.local/bin"
label="dev.jcsnap.aiusage-proxy-steer"
plist="$HOME/Library/LaunchAgents/$label.plist"
log_dir="$HOME/Library/Logs/ai-usage"
pool="${1:-cc3}"

echo "==> Building release binary"
cd "$root"
swift build -c release --product aiusage

echo "==> Installing to $bin_dir"
mkdir -p "$bin_dir" "$log_dir"
install -m 755 "$root/.build/release/aiusage" "$bin_dir/aiusage"

echo "==> Planned weights for pool $pool"
"$bin_dir/aiusage" proxy-steer --pool "$pool" --dry-run

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
        <string>$bin_dir/aiusage</string>
        <string>proxy-steer</string>
        <string>--pool</string>
        <string>$pool</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$log_dir/proxy-steer.log</string>
    <key>StandardErrorPath</key>
    <string>$log_dir/proxy-steer.log</string>
</dict>
</plist>
PLIST

echo "==> Loading the agent"
launchctl bootout "gui/$UID/$label" 2>/dev/null || true
launchctl enable "gui/$UID/$label" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$plist"

sleep 3
echo "==> Last log lines"
tail -n 10 "$log_dir/proxy-steer.log" 2>/dev/null || echo "No log yet. Check $log_dir/proxy-steer.log"
