# Architecture Decision Records

Watt records every load-bearing technical decision as an ADR. Each ADR is a short Markdown file that captures *what we decided*, *why*, *what we considered*, and *how to revisit it* if circumstances change.

## Why ADRs

The codebase uses several non-obvious approaches — a private framework here, a deliberate threshold there — that look weird without context. ADRs are the place to write the context down so a future maintainer (or a future Claude session) doesn't re-litigate the same decision badly.

## When to write one

Any of these warrants an ADR:

- Choosing one API/framework over another (e.g. IOReport vs. powermetrics).
- Deciding a numerical constant whose value is non-obvious (thresholds, timeouts, window sizes).
- Adopting or removing a dependency.
- Picking an architectural pattern (actor model, error-handling style, persistence layer).
- Reversing an earlier decision.

If a teammate would reasonably ask "why is it done this way?", write an ADR.

## Format

Use [`0000-template.md`](0000-template.md) as the starting point. File naming is `NNNN-kebab-case-title.md` where `NNNN` is a zero-padded sequence number that increments by one per ADR.

Each ADR has:

- **Status** — Proposed / Accepted / Superseded by NNNN / Deprecated.
- **Context** — what problem we were solving.
- **Decision** — what we chose.
- **Consequences** — what this means going forward, including pain points we're accepting.
- **Alternatives considered** — the other options and why we didn't pick them.

Keep them short. One page per ADR is the goal.

## Index

| #    | Title                                                                                                         | Status   |
|------|---------------------------------------------------------------------------------------------------------------|----------|
| 0001 | [SwiftData on macOS 26 for persistence](0001-swiftdata-on-macos-26-for-persistence.md)                        | Accepted |
| 0002 | [SF Symbols + dlopen for Apple Silicon sensor + power data](0002-private-frameworks-via-dlopen.md)            | Accepted |
| 0003 | [On-device verdict via FoundationModels with deterministic fallback](0003-foundation-models-with-fallback.md) | Accepted |
| 0004 | [Markdown report body is the source of truth](0004-markdown-as-source-of-truth.md)                            | Accepted |
| 0005 | [Window-integrated episode detector](0005-window-integrated-episode-detector.md)                              | Accepted |
| 0006 | [Drop SMAppService helper from v1](0006-drop-smappservice-helper.md)                                          | Superseded by 0009 |
| 0007 | [IOReport for system power, not ri_energy_nj](0007-ioreport-for-system-power.md)                              | Accepted |
| 0008 | [Always surface security/system agents in reports](0008-surface-security-agents.md)                           | Accepted |
| 0009 | [Mandatory privileged helper for Endpoint Security visibility](0009-mandatory-privileged-helper.md)           | Accepted |

## Process for future agents

When you make a decision that fits the criteria above:

1. Pick the next free number (look at the index).
2. Copy `0000-template.md` to `NNNN-kebab-case-title.md`.
3. Fill it in.
4. Add the row to the index table.
5. Reference it in the commit message.

`CLAUDE.md` at the repo root mirrors these rules so any agent working on this codebase knows to follow them.
