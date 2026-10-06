#!/bin/zsh
# Builds MicGuard.app and installs it to /Applications.
set -euo pipefail
cd "${0:A:h}"

APP=build/MicGuard.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -swift-version 5 -O main.swift -o "$APP/Contents/MacOS/MicGuard"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MicGuard</string>
    <key>CFBundleIdentifier</key><string>local.micguard</string>
    <key>CFBundleExecutable</key><string>MicGuard</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

pkill -x MicGuard 2>/dev/null || true
rm -rf /Applications/MicGuard.app
cp -R "$APP" /Applications/
open /Applications/MicGuard.app
echo "Installed and launched /Applications/MicGuard.app"
