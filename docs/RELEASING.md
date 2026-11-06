# Releases

CI runs tests and builds a universal (Apple Silicon and Intel) app on each main push and pull request. No distribution credentials are available to CI or pull requests.

Adapted from Movembercam: manually run **Release (Manual)** on main and choose prerelease or stable. Uncheck **publish** to validate signing/notarization and save artifacts without creating a tag or release. The selected commit must pass CI before signing. The workflow creates the version tag and release only after Developer ID signing, Apple notarization, stapling, and Gatekeeper verification succeed. It uploads a universal drag-to-Applications DMG and SHA-256 checksum. An existing version tag is rejected; increment VERSION before the next release. CFBundleVersion uses the workflow run number.

Repository secrets: BUILD_CERTIFICATE_BASE64 (Developer ID Application P12), P12_PASSWORD, APPLE_TEAM_ID, APPLE_ID, APPLE_ID_PASSWORD (notarization app-specific password). Credentials are imported into a temporary runner keychain and removed even on failure. Watt needs no camera-extension provisioning profile. Credentials are never committed. Bundle identifier: com.grahamgilbert.Watt; macOS 14 or later.

## Sparkle updates

Watt embeds Sparkle 2.10.1, checks hourly when automatic checking is enabled, and offers Check for Updates and a prerelease opt-in in the popup's Updates disclosure. Stable uses appcast.xml; prerelease users use appcast-prerelease.xml, which includes both stable and prerelease builds. Both feeds, the DMG and HTML release notes are Ed25519-signed. Unsigned feeds and payloads are rejected.

SPARKLE_PRIVATE_KEY is the sixth repository secret. Its public half is in Config/Updates.plist. The Watt-specific private key is stored in the Private 1Password vault as **Watt Sparkle Signing Key**. Its Private key field contains the base64 seed; the Public key field matches the app configuration. No copy is kept in the login keychain. Do not commit exported keys. Release validation checks that the secret matches the public key embedded in the app.

Release (Manual) signs and verifies feeds even with publish unchecked. With publish enabled it publishes the notarized DMG and signed notes, then commits both signed feeds to main. A retry of the same source commit signs the already-published DMG and reads its actual build number; it never replaces that DMG. If publication succeeds but the feed push fails, rerun that workflow attempt.

Promote to Stable accepts an existing prerelease version, copies its original signed enclosure into the stable feed, re-signs feeds and removes GitHub's prerelease flag. It does not rebuild or re-sign the DMG. Promotions that would downgrade the stable feed are rejected.

Development builds are ad hoc signed; update installation must be exercised with a Developer ID release. Builds predating Sparkle need one manual installation before they can update themselves. The initial Sparkle release establishes this baseline.

Local checks: `swift test --disable-sandbox`; `UNIVERSAL=1 zsh scripts/build-app.sh release`. The local build remains ad hoc signed. CI release scripts require an isolated GitHub Actions runner and must not be used to modify the local keychain.

## First prerelease readiness

The 0.1.0 candidate includes the visual popup dashboard, configurable menu bar, SQLite process history, corrected cache-excluding memory accounting, a native app icon and Sparkle updates. CPU/SoC power and temperature collectors remain unavailable; battery flow is an electrical estimate. Per-process energy is not attributed. The app is a prerelease and recorder-only benchmarks do not establish whole-app overhead. A real older-to-newer Sparkle installation test needs two Developer ID releases; the first release establishes the baseline.
