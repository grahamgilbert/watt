# 0008. Always surface security/system agents in reports

* **Status:** Accepted
* **Date:** 2026-05-12
* **Deciders:** Graham, Claude

## Context

Watt's purpose is to make corporate-mandated security tools visible when they degrade a developer's machine. Real-world testing exposed that the v1 report did **not** mention CrowdStrike Falcon or Cyberhaven despite both being observed at 15%+ CPU during the captured window — they didn't make the top-5 ranked-by-score list because their CPU was distributed across many short-lived helper processes and individually they fell below the threshold of "loud" workloads like a build.

Two failure modes:

1. **Suspect ranking eats them.** A weighted CPU+energy+IO score puts a 30-second `swift build` invocation above a constantly-spiking-but-low-individual-cost agent.
2. **Hardcoded lists rot.** Even if we maintain a curated registry of well-known agents, in-house corporate tooling won't be in any list.

## Decision

Three layers, in order of preference:

1. **`SystemServiceRegistry`** — load every plist in `/Library/LaunchDaemons` and every bundle in `/Library/SystemExtensions` at app launch. Any process whose name or bundle-id matches one of these is treated as "system-managed." Entries declaring `NSExtensionPointIdentifier == com.apple.security.endpoint-security.client` are flagged as `.endpointSecurityExtension` — the strongest signal a process is part of an EDR product.
2. **`SecurityAgents` curated list** — hardcoded patterns for the well-known vendors (Falcon, Cyberhaven, JAMF, SentinelOne, Defender, Zscaler, etc.). Used to give friendly display names and "what this is" descriptions when the host registry doesn't include enough metadata.
3. **`SecurityAgents.classify`** combines both, returning `.curated`, `.systemManaged`, or `.unknown`.

`ProcessCorrelator` uses this to:

- Always include every observed agent in the suspect list, even if it scored below the top-N.
- Expose the agent set separately as `Result.securityAgents` so the report can render a dedicated "Security / system agents observed" section.

`PeriodicTopProcesses` adds a second cut at the data: the episode window is split into 6 equal time slices, each bucket ranks its own top-N processes by combined score, and any agent active in a slice is always included regardless of score. Reports render this as an "Activity over time" section with one table per slice.

The AI system prompt is updated to require explicit mention of every security agent by name. The deterministic `Templater` fallback also weaves agent names into the verdict paragraph and adds a "Open a ticket with Security listing X, Y, Z" recommended action.

## Consequences

- An engineer reading a report **can't miss** which corporate agents were active. That's the entire point of Watt.
- The "Activity over time" buckets show whether an agent was sustained throughout the window or only spiked briefly — key context for the security team conversation.
- Reports are longer (more sections) but each section is independently scannable.
- We pay a one-time disk read of every plist in `/Library/LaunchDaemons` at process start. Cheap on any reasonable Mac.
- Hardcoded curated list will need maintenance as new vendors emerge. Acceptable: the system-registry path catches everything we miss in the curated list, just without the friendly display name.

## Alternatives considered

- **Score-only ranking, leave thresholds tuned higher** — would still miss agents that distribute their work across many helpers. Rejected.
- **Curated list only, no system registry** — would miss in-house corporate tools. Rejected.
- **System registry only, no curated list** — works for detection but we lose the "this is what CrowdStrike Falcon is" rationale strings. Rejected; keep both.

## Revisit triggers

- If a real workload's helper processes get incorrectly flagged as agents (e.g. a JetBrains IDE helper picks up a generic LaunchAgent and matches), tighten matching to `/Library/LaunchDaemons` only (already the case) and require the system extension bundle to actually declare an EndpointSecurity entitlement before treating it as one.
- If users complain reports are too long, hide the "Security agents" section behind a `<details>` collapse but keep it on by default.
