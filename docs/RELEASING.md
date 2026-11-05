# Releases

CI runs tests and builds a universal (Apple Silicon and Intel) app on each main push and pull request. No distribution credentials are available to CI or pull requests.

Adapted from Movembercam: manually run **Release (Manual)** on main and choose prerelease or stable. Uncheck **publish** to validate signing/notarization and save artifacts without creating a tag or release. The selected commit must pass CI before signing. The workflow creates the version tag and release only after Developer ID signing, Apple notarization, stapling, and Gatekeeper verification succeed. It uploads a universal drag-to-Applications DMG and SHA-256 checksum. An existing version tag is rejected; increment VERSION before the next release. CFBundleVersion uses the workflow run number.

Repository secrets: BUILD_CERTIFICATE_BASE64 (Developer ID Application P12), P12_PASSWORD, APPLE_TEAM_ID, APPLE_ID, APPLE_ID_PASSWORD (notarization app-specific password). Credentials are imported into a temporary runner keychain and removed even on failure. Watt needs no camera-extension provisioning profile. Credentials are never committed. Bundle identifier: com.grahamgilbert.Watt; macOS 14 or later.

This sets up release distribution. Watt does not yet include Sparkle automatic updates, so no Sparkle key or feed is copied.

Local checks: `swift test --disable-sandbox`; `UNIVERSAL=1 zsh scripts/build-app.sh release`. The local build remains ad hoc signed. CI release scripts require an isolated GitHub Actions runner and must not be used to modify the local keychain.
