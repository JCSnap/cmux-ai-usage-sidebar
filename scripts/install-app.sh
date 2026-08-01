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

# The project stores the original author's team, which nobody else can sign
# with. Setting DEVELOPMENT_TEAM overrides it without an edit to the project
# file, so a fork stays a clean checkout.
team_override=()
[ -n "${DEVELOPMENT_TEAM:-}" ] && team_override=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")

echo "==> Building release app"
xcodebuild -project "$project" \
    -scheme CMUXExtKitSampleSidebarApp \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived" \
    ${team_override[@]+"${team_override[@]}"} \
    build

built="$derived/Build/Products/Release/$app_name"
[ -d "$built" ] || { echo "Build produced no app at $built" >&2; exit 1; }

echo "==> Installing to /Applications"
rm -rf "/Applications/$app_name"
cp -R "$built" "/Applications/$app_name"

# Launch Services registers every app bundle it finds, including the build
# products. cmux then lists the same extension once per registration. Drop the
# build copies so only the installed app remains.
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for stale in "$derived/Build/Products"/*/"$app_name"; do
    [ -d "$stale" ] && "$lsregister" -u "$stale" 2>/dev/null || true
done

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
  1. Settings > Advanced > turn on the "Extensions" experimental toggle.
     The puzzle button does not appear until this is on.
  2. Click the puzzle button next to the sidebar help button.
  3. Open Sidebar Extensions and enable "AI Usage".
  4. Choose the extension sidebar provider from the same menu.
NEXT
