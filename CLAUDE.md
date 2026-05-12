# Watt — Agent Instructions

This file is for AI agents (Claude Code, Cursor, etc.) and human contributors who want to work the way the existing maintainers do.

## What Watt is

A macOS 26 menubar app that watches battery / energy / CPU / fan / temperature, detects sustained drain or high-energy "episodes," and produces Markdown forensics reports an engineer can hand to their security team. macOS 26 only, Apple Silicon only, internal distribution (Developer ID signed).

## Architecture Decision Records

**Every load-bearing decision must have an ADR.** The full process is documented in [`docs/adr/README.md`](docs/adr/README.md).

In short:

- Before you change a load-bearing constant, swap an API, add or remove a dependency, or pick an architectural pattern: **write an ADR first** (or alongside the code change in the same commit).
- Read existing ADRs before re-litigating a decision. If the answer is in `docs/adr/`, follow it; if you have a new reason to revisit, write a superseding ADR rather than silently changing course.
- Reference the ADR number in your commit message. Example: `Implement IOReport bridge (ADR 0007)`.

### When an ADR is required

Yes, write one:

- Choosing one API/framework over another.
- Setting a numerical constant whose value is non-obvious (thresholds, timeouts, window sizes).
- Adding or removing a dependency.
- Picking an architectural pattern (actor model, error-handling style, persistence layer).
- Reversing or superseding an earlier decision.

No, don't:

- Bug fixes that don't change a decision.
- Rewriting prose, fixing typos, renaming.
- Adding tests.
- UI tweaks that don't change information architecture.

If you're not sure, err on the side of writing one — they're cheap and they save future maintainers from re-deriving context.

## Project layout

```
Watt/                       Menubar app target (LSUIElement = YES)
WattCore/                   SwiftPM package — the bulk of the code
  Sources/
    WattModels/             SwiftData @Model types (no logic, no dependencies on other Watt modules besides Foundation)
    WattAnalysis/           Episode detection, suspect ranking, timeline. Pure value types.
    WattSampling/           Per-source actors + SamplingCoordinator + SamplingWriter (@ModelActor)
    WattSamplingC/          C bridges for libproc, host_info, IOHIDEventSystem, IOReport
    WattAI/                 FoundationModels integration + Templater fallback + MarkdownReportBuilder
    WattUI/                 SwiftUI views: menubar, report window, detail/list, login-item controller
  Tests/WattCoreTests/      XCTest suite. Run via `swift test`.
docs/adr/                   Architecture Decision Records (see above).
scripts/                    Operator tools: stress-test.sh, GenerateIcons.swift, export-cert.sh.
```

## Build / test / lint

From repo root:

```sh
xcodegen generate                                    # regenerate Xcode project from project.yml
swift test --package-path WattCore                   # run the unit suite
swiftlint --strict                                   # lint (config at .swiftlint.yml)
xcodebuild -project Watt.xcodeproj -scheme Watt \
  -configuration Debug -destination 'platform=macOS' build
```

CI runs all three on every push and PR (see `.github/workflows/`).

## Concurrency

The codebase is **Swift 6 strict concurrency** throughout. Two non-negotiables:

- SwiftData `@Model` types never cross actor isolation. The pattern is: write inside `@ModelActor` (`SamplingWriter`), and return `*Point` Sendable value-type projections (`SamplePoint`, `ProcessPoint`, `UserEventPoint`). The analysis layer never sees a `@Model` type.
- C bridge callbacks (FSEvents, IOReport, IOHIDEventSystem) fire on arbitrary queues; wrap them in `AsyncStream` or atomic counters and receive on the owning actor.

## Style

- No comments unless the *why* is non-obvious. Code that's mechanical doesn't need narration.
- Tests are XCTest. New tests go in `WattCore/Tests/WattCoreTests/`.
- Use `Fixtures` helpers (`Fixtures.steadyDrain`, `Fixtures.acHighEnergy`, `Fixtures.writerReaderProcesses`) to build sample series — don't construct synthetic samples ad-hoc.
- Markdown report sections must remain stable for diffability (see ADR 0004).

## Working agreements

- All commits include `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>` when an agent contributed.
- Force-pushes on `main` are off-limits.
- The release workflow (`.github/workflows/release.yml`) is the only thing allowed to publish a tagged release; manual `git push --tags` of a `v*` tag is not the expected path.
