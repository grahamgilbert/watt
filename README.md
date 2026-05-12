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
WattCore/              SwiftPM package: models, sampling, analysis, AI, UI
```

See [`docs/adr/`](docs/adr/) for architectural decision records, and [`CLAUDE.md`](CLAUDE.md) for contributor / agent instructions.

## Where reports live

Watt persists every report inside its SwiftData store at
`~/Library/Application Support/Watt/store.sqlite`. On every report
generation it also writes a Markdown mirror to:

```
~/Library/Application Support/Watt/Reports/episode-<timestamp>-<ai|templated>.md
```

The "Show reports folder in Finder" button in the menubar opens that
directory directly. The mirrored files are plain UTF-8 Markdown — paste
them into Slack, share via gist, or just `grep` them.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
