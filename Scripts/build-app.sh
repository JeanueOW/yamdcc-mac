#!/bin/bash
# Build YAMDCC.app with the Command Line Tools only (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-release}"
APP="build/YAMDCC.app"

echo "==> Building Swift targets ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product YAMDCCApp
swift build -c "$CONFIGURATION" --product yamdcc
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/YAMDCCApp" "$APP/Contents/MacOS/YAMDCC"
# NOTE: macOS volumes are case-insensitive; "yamdcc" would collide with "YAMDCC".
cp "$BIN/yamdcc" "$APP/Contents/MacOS/yamdcc-cli"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
	<key>CFBundleExecutable</key><string>YAMDCC</string>
	<key>CFBundleIdentifier</key><string>com.yamdcc.mac</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIconName</key><string>AppIcon</string>
	<key>CFBundleName</key><string>YAMDCC</string>
	<key>CFBundleDisplayName</key><string>YAMDCC</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.2.1</string>
	<key>CFBundleVersion</key><string>6</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><false/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHumanReadableCopyright</key><string>GPL-3.0-or-later — based on YAMDCC by Sparronator9999</string>
</dict>
PLIST
echo "</plist>" >> "$APP/Contents/Info.plist"

if [ -f Resources/AppIcon.icns ]; then
	cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

if [ -d Resources/Configs ]; then
	cp -R Resources/Configs "$APP/Contents/Resources/Configs"
fi

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null

echo "Built: $(pwd)/$APP"
