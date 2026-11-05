#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
configuration="${1:-release}"
version="$(cat VERSION)"
build_number="${BUILD_NUMBER:-1}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build_number" =~ ^[0-9]+$ ]] || { echo "Invalid app version or build number" >&2; exit 1; }
app="$PWD/dist/Watt.app"
mkdir -p "$app/Contents/MacOS"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  binaries=()
  for target_arch in arm64 x86_64; do
    build_args=(--disable-sandbox -c "$configuration" --arch "$target_arch" --scratch-path ".build/release-$target_arch")
    swift build "${build_args[@]}"
    bin_path="$(swift build "${build_args[@]}" --show-bin-path)"
    binaries+=("$bin_path/Watt")
  done
  lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/Watt"
else
  swift build --disable-sandbox -c "$configuration"
  bin_path="$(swift build --disable-sandbox -c "$configuration" --show-bin-path)"
  cp "$bin_path/Watt" "$app/Contents/MacOS/Watt"
fi
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.grahamgilbert.Watt</string>
<key>CFBundleName</key><string>Watt</string>
<key>CFBundleExecutable</key><string>Watt</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
echo "$app"
