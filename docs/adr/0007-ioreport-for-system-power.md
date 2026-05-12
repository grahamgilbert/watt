# 0007. IOReport for system power, not `ri_energy_nj`

* **Status:** Accepted
* **Date:** 2026-05-12
* **Deciders:** Graham, Claude

## Context

Watt needs a system-wide watts signal that works on both AC and battery. The first implementation summed `proc_pid_rusage(RUSAGE_INFO_V6).ri_energy_nj` across processes and divided by elapsed wall-clock seconds.

A 3-hour stress test (`./scripts/stress-test.sh`) revealed this signal is wrong by an order of magnitude:

- Average system watts during the test: **1.6 W**
- Peak ever recorded: **11.5 W**
- Heaviest 10-minute bucket mean: **5.4 W**

Real wall power for a busy M-series Mac sits around 25-40 W. The shortfall is because `ri_energy_nj` only includes kernel-billed per-process energy: GPU, display, idle floor, controller, networking, and any work the kernel throttled to background QoS are all missing or under-counted. No realistic threshold could distinguish "running a build" from "browsing Slack" with this signal.

## Decision

Read system power from **`IOReport`**, the framework Activity Monitor's Energy column uses. IOReport exposes per-subsystem cumulative joule counters (CPU, GPU, ANE, DRAM) on Apple Silicon. Our bridge (`WattSamplingC/ioreport_bridge.c`) resolves the API symbols via `dlopen` against `IOKit.framework` (see ADR 0002), subscribes to the "Energy Model" channel group, and returns watts as nanojoules-since-last-sample / elapsed.

`PowerSampler` is the Swift wrapper. `SamplingCoordinator.tickOnce()` reads from it; the old `ri_energy_nj` path remains as a fallback for the unlikely case `watt_ioreport_open()` fails.

Default AC threshold raised from 3 W (calibrated for `ri_energy_nj`) back to 18 W (calibrated for IOReport's true wall power).

## Consequences

- The watts signal now matches what Activity Monitor and `powermetrics` show, within a few hundred milliwatts.
- Episode thresholds are once again interpretable: 18 W mean over 10 minutes really is "this Mac is doing real work."
- We accept dependence on a private API surface (mitigated by graceful fallback).
- Per-process attribution remains via `ri_energy_nj` — IOReport gives system totals, not per-process. The two signals are complementary.

## Alternatives considered

- **`ri_energy_nj` only** — incumbent. Rejected (see context).
- **Privileged helper running `powermetrics`** — public, but requires admin password and a daemon install. Rejected (see ADR 0006).
- **Battery wattage from IOPS (`kIOPSCurrentKey × kIOPSVoltageKey`)** — works on battery only, returns 0 on AC for many machines. Useful supplement, not a replacement.

## Revisit triggers

- If Apple ships a public power-counters API, switch.
- If a macOS update breaks our IOReport bridge, the `ri_energy_nj` fallback keeps the app limping; budget time to either chase the new symbols or reinstate the helper.
- If we add per-process power attribution, `ri_energy_nj` is the right signal for that — IOReport channels are per-subsystem, not per-process.
