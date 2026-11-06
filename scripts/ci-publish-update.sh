#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${GITHUB_ACTIONS:-}" == true && -n "${RUNNER_TEMP:-}" ]] || exit 1
: "${SPARKLE_PRIVATE_KEY:?Configure the Sparkle signing key}"
mode="${1:-preview}"
channel="${RELEASE_CHANNEL:-prerelease}"
[[ "$mode" == release || "$mode" == preview || "$mode" == promote ]] || exit 1
[[ "$channel" == stable || "$channel" == prerelease ]] || exit 1
artifact_root=".build/artifacts"
if [[ -d .build/release-arm64/artifacts ]]; then artifact_root=".build/release-arm64/artifacts"; fi
sign_update="$(find "$artifact_root" -type f -path '*/bin/sign_update' -print -quit)"
[[ -x "$sign_update" ]] || { echo 'Sparkle signing tool is missing.' >&2; exit 1; }
umask 077
mkdir -p "$RUNNER_TEMP/watt-signing"
key_file="$RUNNER_TEMP/watt-signing/sparkle.key"
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$key_file"
feed_tree="$(mktemp -d "$RUNNER_TEMP/watt-feed.XXXXXX")"
cleanup() {
  git worktree remove --force "$feed_tree" >/dev/null 2>&1 || true
  rm -rf "$feed_tree"
  rm -f "$key_file"
}
trap cleanup EXIT
swift scripts/verify-sparkle-key.swift "$key_file" Config/Updates.plist
if [[ "$mode" == preview ]]; then
  cp appcast.xml appcast-prerelease.xml "$feed_tree/"
else
  git fetch origin main
  git worktree add --detach "$feed_tree" origin/main
fi
if [[ "$mode" != promote ]]; then
  tag="${RELEASE_TAG:?Read the release version first}"
  version="${tag#v}"
  archive="$PWD/dist/Watt-$version.dmg"
  build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' dist/Watt.app/Contents/Info.plist)"
  if [[ "$mode" == release ]]; then
    if gh release view "$tag" --json url >/dev/null 2>&1; then
      existing_commit="$(gh api "repos/$GH_REPO/commits/$tag" --jq .sha)"
      [[ "$existing_commit" == "$GITHUB_SHA" ]] || { echo 'Release belongs to another commit; bump VERSION.' >&2; exit 1; }
      published="$RUNNER_TEMP/watt-published"
      mkdir -p "$published"
      gh release download "$tag" --pattern "Watt-$version.dmg*" --dir "$published" --clobber
      (cd "$published" && shasum -a 256 -c "Watt-$version.dmg.sha256")
      archive="$published/Watt-$version.dmg"
      mount="$RUNNER_TEMP/watt-published-mount"
      mkdir -p "$mount"
      hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$archive"
      # Feed metadata must match the published payload, not a rebuilt retry's bundle.
      build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$mount/Watt.app/Contents/Info.plist")"
      payload_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$mount/Watt.app/Contents/Info.plist")"
      hdiutil detach "$mount"
      [[ "$payload_version" == "$version" ]] || exit 1
    else
      args=(--target "$GITHUB_SHA" --title "Watt $version")
      if [[ -f "docs/releases/$version.md" ]]; then args+=(--notes-file "docs/releases/$version.md"); else args+=(--generate-notes); fi
      if [[ "$channel" == prerelease ]]; then args+=(--prerelease); fi
      gh release create "$tag" "$archive" "$archive.sha256" "${args[@]}"
    fi
    gh release view "$tag" --json body --jq .body > "$RUNNER_TEMP/watt-release-notes.md"
  else
    if [[ -f "docs/releases/$version.md" ]]; then
      cp "docs/releases/$version.md" "$RUNNER_TEMP/watt-release-notes.md"
    else
      printf '## Watt %s\n- Release validation preview.\n' "$version" > "$RUNNER_TEMP/watt-release-notes.md"
    fi
  fi
  signature="$("$sign_update" --ed-key-file "$key_file" "$archive")"
  notes="release-notes-$version.html"
  python3 scripts/appcast.py notes --input "$RUNNER_TEMP/watt-release-notes.md" --output "dist/$notes" --version "$version"
  notes_signature="$("$sign_update" --ed-key-file "$key_file" --disable-signing-warning -p "dist/$notes")"
  notes_length="$(wc -c < "dist/$notes" | tr -d '[:space:]')"
  if [[ "$mode" == release ]]; then gh release upload "$tag" "dist/$notes" --clobber; fi
  args=(--version "$version" --build "$build_number"
    --url "https://github.com/$GH_REPO/releases/download/$tag/Watt-$version.dmg"
    --signature "$signature" --notes-url "https://github.com/$GH_REPO/releases/download/$tag/$notes"
    --notes-signature "$notes_signature" --notes-length "$notes_length")
  python3 scripts/appcast.py add --feed "$feed_tree/appcast-prerelease.xml" "${args[@]}"
  if [[ "$channel" == stable ]]; then python3 scripts/appcast.py add --feed "$feed_tree/appcast.xml" "${args[@]}"; fi
else
  version="${2:?Provide the version to promote}"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
  gh release view "v$version" --json url >/dev/null
  python3 scripts/appcast.py promote --source "$feed_tree/appcast-prerelease.xml" --destination "$feed_tree/appcast.xml" --version "$version"
fi
for feed in appcast.xml appcast-prerelease.xml; do
  "$sign_update" --ed-key-file "$key_file" --disable-signing-warning "$feed_tree/$feed"
  "$sign_update" --verify --ed-key-file "$key_file" "$feed_tree/$feed"
done
if [[ "$mode" == preview ]]; then
  cp "$feed_tree/"*.xml dist/
else
  git -C "$feed_tree" add appcast.xml appcast-prerelease.xml
  if ! git -C "$feed_tree" diff --cached --quiet; then
    git -C "$feed_tree" -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' commit -m "Publish signed Sparkle feeds for v$version"
    git -C "$feed_tree" -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin HEAD:main
  fi
  if [[ "$mode" == promote ]]; then gh release edit "v$version" --prerelease=false; fi
fi
