#!/usr/bin/env bash
# Assembles a double-clickable Koda.app from the KodaApp executable.
# Personal tool: ad-hoc signed, not notarised, not for distribution.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Koda.app"

echo "Building release…"
swift build -c release --package-path "$ROOT"

BIN="$ROOT/.build/release/KodaApp"
[ -f "$BIN" ] || { echo "error: $BIN not found" >&2; exit 1; }

echo "Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Koda"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"

plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Ad-hoc signature so macOS will launch it locally without Gatekeeper complaints.
codesign --force --sign - "$APP" 2>/dev/null || echo "warning: ad-hoc signing failed; the app may still run"

echo "Built $APP"
echo "Open it with: open '$APP'"
