# 0001. SwiftData on macOS 26 for persistence

* **Status:** Accepted
* **Date:** 2026-05-12
* **Deciders:** Graham, Claude

## Context

Watt needs to persist three kinds of records:

1. Time-series telemetry (`Sample` and `ProcessSample`) — high write volume, ~one row per 5s plus N processes per row.
2. Operator-relevant events (`UserEvent`) — sparse, event-driven.
3. Episode + report rows — derived state, low volume, long retention.

The app is macOS 26 only and Apple Silicon only, so we have access to the latest persistence APIs without backporting concerns.

## Decision

Use **SwiftData** with a single `ModelContainer` rooted at `~/Library/Application Support/Watt/store.sqlite`. All writes are funneled through a `@ModelActor`-isolated `SamplingWriter` so SwiftData's strict-concurrency rules hold without any locks.

`@Model` types live in `WattModels`. The analysis layer never touches a SwiftData context — `SamplePoint`/`ProcessPoint`/`UserEventPoint` are Sendable value-type projections that the writer hands out across actor boundaries.

## Consequences

- Schema changes are easy via SwiftData migrations; we get indexes, predicates, and prefetching for free.
- The strict-concurrency boundary (no `@Model` types crossing actor isolation) means we maintain two parallel hierarchies (SwiftData models vs. `*Point` value types). It's mechanical, but it's duplication.
- We're tied to the SwiftData implementation; bugs in SwiftData hit us directly. Mitigation: the value-type projections mean we could swap the storage layer without touching the analysis or AI code.

## Alternatives considered

- **GRDB.swift** — more SQL control, mature library. Rejected: extra dep, manual migrations, and we don't need the SQL escape hatch for this workload.
- **Core Data** — heavy boilerplate, the SwiftData "Core Data classic" path. Rejected: SwiftData supersedes it cleanly on macOS 26.
- **Append-only JSON files** — simplest possible. Rejected: at one row/5s × hours, queries get expensive without indexes.

## Revisit triggers

- If SwiftData strict-concurrency friction blocks us from a real feature, evaluate GRDB.
- If retention requirements grow to weeks of high-cadence data, profile and consider time-bucketed Parquet/CSV exports.
