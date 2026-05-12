# 0002. Private frameworks via `dlopen` for sensor and power data

* **Status:** Accepted
* **Date:** 2026-05-12
* **Deciders:** Graham, Claude

## Context

Two of Watt's most useful signals — fan RPM / per-die temperature, and accurate system wattage — are not exposed through public macOS APIs:

- `IOHIDEventSystemClient` (Apple Sensors) is the only practical way to read fan and temperature sensors on Apple Silicon. Activity Monitor, `stats`, and `iStat Menus` all use it.
- `IOReport` is what Activity Monitor's Energy column reads for per-subsystem power counters. The framework is exported from `IOKit.framework` but the headers ship in a private `IOReport.framework`.

The app is internal-distribution (Developer ID signed, not App Store), so the App Store private-API ban doesn't apply.

## Decision

Resolve all symbols dynamically via `dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)` followed by `dlsym` for each function we use. C bridges live in `WattCore/Sources/WattSamplingC/` (`iohid_bridge.c`, `ioreport_bridge.c`).

Each bridge gracefully degrades when symbols can't be resolved:

- `IOHIDEventSystem`: returns empty arrays, gated behind the `WATT_USE_PRIVATE_HID` build flag so it can be compiled out entirely if needed.
- `IOReport`: returns `available: false` from `PowerSampler.read()`. The coordinator falls back to summing `ri_energy_nj` across processes (less accurate but still better than nothing).

## Consequences

- The build doesn't depend on private SDK headers — anyone with the public macOS SDK can compile.
- We get the same data quality Activity Monitor shows, without admin password or a privileged helper.
- We accept that Apple could rename or remove these symbols in a future macOS. The graceful-degradation path means the app keeps working even if a single bridge breaks.
- This is **not** App Store distributable as long as we link these symbols. Acceptable for v1's internal-tools target.

## Alternatives considered

- **Privileged helper running `powermetrics`** — public, root-required, requires SMAppService daemon install. Rejected for v1 (see ADR 0006).
- **Public IOKit alone** — only gives battery state, not sensors or per-subsystem power. Insufficient.
- **Linking the private `IOReport.framework` directly** — would require shipping its private headers; same dependence on private surface but with an SDK-path requirement that complicates CI.

## Revisit triggers

- If Apple ships a public sensors or power-counter API on macOS 27+, switch.
- If a macOS update breaks either bridge, evaluate whether the helper-based path becomes cheaper than chasing the private surface.
- If we ever target App Store distribution, every private-symbol path becomes a blocker.
