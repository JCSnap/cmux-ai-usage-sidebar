#!/usr/bin/env bash
# Builds the containing app and registers its embedded sidebar extension.
#
# macOS only discovers an app extension after the containing app has been
# launched at least once from a stable location, so the app is copied to
# /Applications and opened.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
project="$root/AIUsageSidebar/SampleSidebarExtensionApp.xcodeproj"
derived="$root/AIUsageSidebar/DerivedData"
app_name="AI Usage Sidebar.app"

echo "==> Building release app"
xcodebuild -project "$project" \
    -scheme CMUXExtKitSampleSidebarApp \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived" \
    build

built="$derived/Build/Products/Release/$app_name"
[ -d "$built" ] || { echo "Build produced no app at $built" >&2; exit 1; }

echo "==> Installing to /Applications"
rm -rf "/Applications/$app_name"
cp -R "$built" "/Applications/$app_name"

echo "==> Launching once so macOS registers the extension"
open "/Applications/$app_name"
sleep 4

echo "==> Registered sidebar extensions"
pluginkit -m -p com.cmuxterm.app.cmux.sidebar || {
    echo "No sidebar extension registered yet." >&2
    echo "Confirm cmux is 0.64.20 or newer; older builds have no extension point." >&2
    exit 1
}

cat <<'NEXT'

Next steps in cmux:
  1. Click the puzzle button next to the sidebar help button.
  2. Open Sidebar Extensions and enable "AI Usage".
  3. Choose the extension sidebar provider from the same menu.
NEXT
