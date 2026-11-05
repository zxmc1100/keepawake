#!/bin/zsh
# Build, self-check, install to /Applications and launch KeepAwake.
set -e
cd "$(dirname "$0")"

APP=build/KeepAwake.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -swift-version 5 KeepAwake.swift -o "$APP/Contents/MacOS/KeepAwake"
"$APP/Contents/MacOS/KeepAwake" --selfcheck
./test_guard.sh "$APP/Contents/MacOS/KeepAwake"

# A stable identity keeps Launch at Login working across rebuilds; ad hoc is the fallback.
codesign --force -s "Apple Development" "$APP" 2>/dev/null || codesign --force -s - "$APP"

# Wait for the old app: the new one exits at once if it still sees another instance.
pkill -x KeepAwake 2>/dev/null || true
for _ in {1..50}; do pgrep -x KeepAwake >/dev/null || break; sleep 0.1; done
rm -rf /Applications/KeepAwake.app
cp -R "$APP" /Applications/
open /Applications/KeepAwake.app
echo "KeepAwake installed: look for the bolt icon in the menu bar."
