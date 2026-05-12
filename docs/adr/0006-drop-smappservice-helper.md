# 0006. Drop SMAppService helper from v1

* **Status:** **Superseded by [ADR 0009](0009-mandatory-privileged-helper.md)**
* **Date:** 2026-05-12
* **Deciders:** Graham, Claude

## Context

The original v1 plan included a privileged helper (`WattHelper`) registered via `SMAppService.daemon`. The helper's only job was to invoke `/usr/bin/powermetrics` and stream the parsed plist back over XPC, giving Watt access to richer per-cluster power data than `proc_pid_rusage` could provide.

We built the scaffolding (target, XPC protocol, helper client, launchd plist, Code Signing Requirement enforcement) but never wired it into the live sampling pipeline. `HelperClient.registerIfNeeded()` was never called, so users were never prompted to install it, and the helper binary was dead code.

When we discovered IOReport (see ADR 0007) gives us the same data without a helper, the helper's reason for existing went away.

## Decision

Delete the helper entirely:

- `WattHelper/` target removed.
- `WattHelperProtocol/` SwiftPM package removed.
- `WattCore/Sources/WattHelperClient/` module removed.
- All references in `project.yml`, `Package.swift`, `.swiftlint.yml`, `WattApp.swift`, `README.md`, and the GH Actions test workflow stripped.
- The `helperInstalled` parameter that lingered in `MarkdownReportBuilder.RenderInput` (and was rendering "Helper installed: no" in every report footer) is also gone.

## Consequences

- No admin-password prompt on first launch. Frictionless install.
- ~500 lines of XPC + helper plumbing deleted.
- Code-signing and notarization workflows are simpler — only one signed bundle to deal with.
- We give up the option to use `powermetrics`-only data in the future without rebuilding the helper. Acceptable: IOReport gives the same numbers.

## Alternatives considered

- **Keep the helper, wire it up, prompt for admin** — would have given identical data to IOReport but with friction. Rejected after IOReport was shown to work.
- **Keep the helper as dead-code scaffolding for "future use"** — invites code rot, and dead-code scaffolding tends to be wrong by the time someone wants to use it. Rejected.

## Revisit triggers

- If IOReport stops working on a macOS update and there's no public replacement, reinstating the helper as an opt-in install is the fallback. Code lives in git history.
- If we ever need data only `powermetrics` can produce (e.g. hardware-thermal counters not in IOReport), the helper can come back as a fresh implementation.
