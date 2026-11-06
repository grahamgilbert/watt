#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
configuration="${1:-release}"
version="$(cat VERSION)"
build_number="${BUILD_NUMBER:-1}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build_number" =~ ^[0-9]+$ ]] || { echo "Invalid app version or build number" >&2; exit 1; }
app="$PWD/dist/Watt.app"
helper="$app/Contents/Library/HelperTools/WattEnergyHelper"
helper_identifier="com.grahamgilbert.Watt.EnergyHelper"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/HelperTools" "$app/Contents/Library/LaunchDaemons"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  binaries=()
  helper_binaries=()
  for target_arch in arm64 x86_64; do
    build_args=(--disable-sandbox -c "$configuration" --arch "$target_arch" --scratch-path ".build/release-$target_arch")
    swift build "${build_args[@]}"
    bin_path="$(swift build "${build_args[@]}" --show-bin-path)"
    binaries+=("$bin_path/Watt")
    [[ -x "$bin_path/WattEnergyHelper" ]] || { echo "Energy helper build output is missing" >&2; exit 1; }
    helper_binaries+=("$bin_path/WattEnergyHelper")
  done
  lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/Watt"
  lipo -create "${helper_binaries[@]}" -output "$helper"
  helper_architectures="$(lipo -archs "$helper")"
  [[ " $helper_architectures " == *" arm64 "* && " $helper_architectures " == *" x86_64 "* ]] || { echo "Energy helper must contain both architectures" >&2; exit 1; }
else
  swift build --disable-sandbox -c "$configuration"
  bin_path="$(swift build --disable-sandbox -c "$configuration" --show-bin-path)"
  cp "$bin_path/Watt" "$app/Contents/MacOS/Watt"
  cp "$bin_path/WattEnergyHelper" "$helper"
fi
chmod 0755 "$helper"
cp Config/com.grahamgilbert.Watt.Energy.plist "$app/Contents/Library/LaunchDaemons/"
chmod 0644 "$app/Contents/Library/LaunchDaemons/com.grahamgilbert.Watt.Energy.plist"
python3 - "$app" <<'PYTHON'
import pathlib,plistlib,stat,sys
app=pathlib.Path(sys.argv[1])
plist=app/'Contents/Library/LaunchDaemons/com.grahamgilbert.Watt.Energy.plist'
info=plistlib.loads(plist.read_bytes())
expected='Contents/Library/HelperTools/WattEnergyHelper'
assert info.get('Label')=='com.grahamgilbert.Watt.Energy','Wrong helper launchd label'
assert info.get('BundleProgram')==expected,'Wrong helper bundle-relative executable'
assert info.get('MachServices')=={'com.grahamgilbert.Watt.Energy':True},'Wrong helper Mach service'
assert not {'Program','ProgramArguments','WatchPaths','QueueDirectories','StartInterval'} & info.keys(),'Unexpected helper launch arguments or polling configuration'
assert info.get('RunAtLoad') is False and info.get('KeepAlive') is False,'Helper must launch only on demand'
helper=app/expected
assert helper.is_file() and not helper.is_symlink(),'Helper executable must be embedded directly'
assert helper.stat().st_mode & 0o111,'Helper is not executable'
assert not helper.stat().st_mode & (stat.S_ISUID|stat.S_ISGID),'Helper must not use setuid/setgid bits'
PYTHON
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.grahamgilbert.Watt</string>
<key>CFBundleName</key><string>Watt</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>Watt</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 - "$app/Contents/Info.plist" <<'PYTHON'
import pathlib,plistlib,sys
path=pathlib.Path(sys.argv[1])
info=plistlib.loads(path.read_bytes());info.update(plistlib.loads(pathlib.Path('Config/Updates.plist').read_bytes()))
path.write_bytes(plistlib.dumps(info))
PYTHON
bash scripts/build-icon.sh
mkdir -p "$app/Contents/Resources"
cp dist/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
artifact_root=".build/artifacts"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then artifact_root=".build/release-arm64/artifacts"; fi
framework="$(find "$artifact_root" -type d -path '*/macos-arm64_x86_64/Sparkle.framework' -print -quit)"
[[ -d "$framework" ]] || { echo "Sparkle framework is missing" >&2; exit 1; }
mkdir -p "$app/Contents/Frameworks"
rm -rf "$app/Contents/Frameworks/Sparkle.framework"
ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
xattr -cr "$app"
# The local helper remains ad hoc and intentionally fails its production client gate.
codesign --force --sign - --identifier "$helper_identifier" "$helper"
codesign --verify --strict "$helper"
codesign -dv --verbose=4 "$helper" 2>&1 | grep -Fx "Identifier=$helper_identifier"
codesign --force --sign - "$app"
echo "$app"
