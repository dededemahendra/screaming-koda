#!/bin/bash
#
# Wraps the KodaApp executable in a .app bundle.
#
# SwiftPM only produces a bare Mach-O. Launched as one, a SwiftUI app gets no
# Dock icon, no menu bar and cannot be brought to the front, because AppKit
# derives all of that from the bundle's Info.plist.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/ScreamingKoda.app"

cd "$ROOT"
swift build -c "$CONFIGURATION" --product KodaApp
BINARY="$(swift build -c "$CONFIGURATION" --product KodaApp --show-bin-path)/KodaApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/ScreamingKoda"

VERSION="$(sed -n 's/.*versionString = "\(.*\)".*/\1/p' Sources/KodaCore/KodaCore.swift | head -1)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Screaming Koda</string>
  <key>CFBundleDisplayName</key><string>Screaming Koda</string>
  <key>CFBundleExecutable</key><string>ScreamingKoda</string>
  <key>CFBundleIdentifier</key><string>co.sistercreatives.screamingkoda</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION:-0.1.0}</string>
  <key>CFBundleVersion</key><string>${VERSION:-0.1.0}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Koda Crawl</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>public.database</string></array>
      <key>CFBundleTypeExtensions</key><array><string>koda</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Ad-hoc signature. Not notarisation, which is out of scope, but without any
# signature at all recent macOS refuses to launch the bundle.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "note: could not ad-hoc sign; the app may not launch"

echo "Built $APP"
