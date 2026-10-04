#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Build on macOS 13+ with Xcode Command Line Tools installed." >&2
    exit 1
fi
swift test
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="dist/TokenChomp.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/TokenChomp" "$APP/Contents/MacOS/TokenChomp"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TokenChomp</string>
<key>CFBundleIdentifier</key><string>local.tokenchomp.app</string>
<key>CFBundleName</key><string>TokenChomp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP. Move it to /Applications before configuring the Claude bridge."
