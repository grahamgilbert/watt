# Watt

A macOS 26 menubar app that watches your battery, finds drain episodes, and writes a real Markdown report explaining what happened — with on-device AI prose grounded in deterministic timeline + per-process telemetry.

Built for Airbnb engineers who need evidence to bring to their security team when corporate agent software is silently melting their laptops.

## Requirements

- macOS 26.0+ on Apple Silicon
- Xcode 26.4+
- Apple Intelligence enabled (optional — Watt falls back to a deterministic templated verdict if it's off)

## Build

```sh
xcodegen generate          # produce Watt.xcodeproj from project.yml
open Watt.xcodeproj
# build & run the Watt scheme in Xcode
```

Or from CLI:

```sh
swift test --package-path WattCore           # run the analysis/AI unit tests
xcodebuild -scheme Watt -configuration Debug build
```

## Layout

```
Watt/                  Menubar app target (LSUIElement = YES)
WattHelper/            SMAppService privileged daemon (runs powermetrics)
WattCore/              SwiftPM package: models, sampling, analysis, AI, UI
WattHelperProtocol/    SwiftPM package: shared XPC protocol
```

See `/Users/graham_gilbert/.claude/plans/i-want-to-write-wiggly-elephant.md` for full design notes.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
