# 0005. Window-integrated episode detector

* **Status:** Accepted
* **Date:** 2026-05-12
* **Deciders:** Graham, Claude

## Context

The first version of the episode detector compared each new sample's *instantaneous* signal against a threshold and required N consecutive samples above threshold to start an episode.

The canonical workload Watt is supposed to catch is a security agent that spikes the CPU for ~1 s every ~5 s while idling between. Each individual sample is below threshold; the integrated energy across a 10-min window reveals the workload. The first detector would never trigger on this pattern.

## Decision

`EpisodeDetector` keeps a rolling-time-window buffer (default 600 s) and computes integrated metrics:

- **Battery path:** total battery percent dropped across the window.
- **AC path:** trapezoidally integrated mean wattage across the window.

An episode starts when the integrated metric exceeds threshold for `stickyCount` consecutive samples *and* the window is saturated (`windowSeconds` of real wall-clock data buffered). Window saturation prevents first-launch false positives.

Sample gaps > 60 s reset the window so sleep/wake transitions never produce phantom episodes.

`DrainEpisodeTrigger` records which path fired (`.batteryDrain`, `.acHighEnergy`, or `.userTriggered` for operator-requested look-backs).

## Consequences

- Episodes only fire on workloads that consume real energy across a 10-min window. Brief spikes don't trigger.
- The detector is robust to spiky workloads that hide in instantaneous samples.
- We need at least 10 minutes of data before the detector says anything. After-launch warmup is silent.
- Tests use a shrunken `windowSeconds: 60` config so the suite runs in milliseconds. Production thresholds are tested against by the marquee `testTriggersOnSpikyWorkloadEvenWhenInstantaneousIsLow` test.

## Alternatives considered

- **Per-sample threshold with sticky count** — the first version. Rejected: misses spiky workloads.
- **EWMA / exponentially weighted moving average** — smooth signal, adjustable decay. Rejected: less interpretable than "mean over the last N minutes," and the threshold semantics shift with the decay constant.
- **Multiple thresholds (warning / serious / critical)** — could give earlier warnings. Rejected for v1 to keep the report shape simple. May revisit.

## Revisit triggers

- If users complain the detector misses a real workload, profile the windowed mean during that workload — usually means a threshold tweak rather than a structural change.
- If a workload pattern emerges that even windowed integration misses (e.g. a daily-at-3am pattern), consider per-time-of-day baselines.
