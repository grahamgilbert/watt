#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
configuration="${1:-release}"
swift build --disable-sandbox -c "$configuration"
bin_path="$(swift build --disable-sandbox -c "$configuration" --show-bin-path)"
app="$PWD/dist/Watt.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_path/Watt" "$app/Contents/MacOS/Watt"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.watt.local</string>
<key>CFBundleName</key><string>Watt</string>
<key>CFBundleExecutable</key><string>Watt</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
echo "$app"
