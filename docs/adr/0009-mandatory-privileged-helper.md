# 0009. Mandatory privileged helper for Endpoint Security visibility

* **Status:** Accepted (supersedes [ADR 0006](0006-drop-smappservice-helper.md))
* **Date:** 2026-05-12
* **Deciders:** Graham, Claude

## Context

The whole point of Watt is to make corporate-mandated security tools (CrowdStrike Falcon, Cyberhaven, Jamf Protect, etc.) visible when they degrade a developer's machine. Empirical testing on a real developer laptop revealed:

- **`proc_listallpids` does not return Endpoint Security extension pids to non-privileged callers.** On the test machine, `ps -axo` shows ~1,100 processes but `proc_listallpids` from a non-root caller returns ~70. CrowdStrike Falcon's pid 579 — running as root from `/Library/SystemExtensions/...` — is invisible.
- **`proc_pid_rusage` returns EPERM for processes the caller doesn't own.** Even if we could enumerate Falcon's pid, we couldn't read its CPU/energy/IO counters.

So an unprivileged Watt fundamentally cannot do its job: report on the impact of security tooling. Two paths to fix it:

1. Drop visibility for protected processes ("Watt only sees what you can see"). Honest but useless for the canonical use case.
2. Re-introduce the privileged helper that ADR 0006 deleted, and make it mandatory.

## Decision

Reinstate `WattHelper` as an SMAppService daemon, **mandatory at every launch**:

- The helper is a tiny Swift binary embedded in `Watt.app/Contents/MacOS/`. Its launchd plist lives at `Watt.app/Contents/Library/LaunchDaemons/com.grahamgilbert.watt.helper.plist`.
- The XPC interface is two methods: `hello()` returns the helper's protocol version + binary version; `listProcesses()` returns `[HelperProcessInfo]` covering every visible pid (which, when the helper runs as root, includes Endpoint Security extensions).
- The helper enforces a code-signing requirement on every incoming connection: peers must be signed with team ID `9D8XP85393`.

App startup runs through `HelperGate` before any UI surfaces:

1. Check `SMAppService.daemon(...).status`.
2. If `.notRegistered` / `.notFound`: show the install sheet. The user has two buttons: "Install" (calls `register()` — admin password prompt) or "Quit Watt".
3. If `.requiresApproval`: show the install sheet pointing the user at System Settings → Login Items.
4. If `.enabled`: ping the helper for `hello()`. If `protocolVersion != WattHelperProtocolVersion`, show the install sheet asking for a re-install. If the helper doesn't respond, same thing.
5. Only when `state == .ready` does the report window become interactive and `SamplingCoordinator` start ticking.

`SamplingCoordinator` reads from both the unprivileged `ProcSampler` and the new `HelperProcSampler` every tick and merges results. For pids both samplers see, the unprivileged reading wins (better bundle-ID resolution via `NSRunningApplication`); for pids only the helper sees, the helper's reading is used.

## Consequences

- Watt now actually does what it claims: reports on Endpoint Security extensions and other root-owned daemons.
- The helper is mandatory — a meaningful install friction. Users see the admin password prompt on first launch and on every protocol-version bump. This is acceptable for an internal-distribution tool; a consumer app would think harder.
- We're back to maintaining a second signed binary, an XPC protocol, and a protocol version. ADR 0006's reasons for dropping the helper were real; we're paying that cost again because the use case demands it.
- The helper's wire data is JSON-encoded `Codable` rather than `NSSecureCoding` of model objects so future field additions don't break older app/helper combos. (We still gate on `protocolVersion` so a known-incompatible pair refuses to run rather than silently disagreeing.)
- Uninstall complexity rises. Mitigated by `scripts/uninstall.sh`, which is shipped inside the release DMG alongside `Watt.app` and must be run as root (`sudo ./uninstall.sh`). The script refuses to call `sudo` internally — privilege escalation is the user's explicit choice at the call site.

## Alternatives considered

- **IOReport-only** (the previous v1 plan, ADR 0007). Gives system-wide totals but no per-process attribution for protected processes. Rejected: doesn't answer "is CrowdStrike Falcon the cause?".
- **Make the helper opt-in.** Considered. Rejected: a non-trivial percentage of users would skip it and then send screenshots saying "Watt is broken, it doesn't show Falcon" — exactly the noise the v1 try at this was supposed to avoid.
- **Use `task_for_pid` + `task_info` from a TCC-permitted app.** Requires the user to grant Watt full disk access AND TCC's "Developer Tools" permission. Doesn't work against SIP-protected processes anyway.

## Revisit triggers

- If Apple introduces a public per-process power API on macOS 27+ that works without root (analogous to what Activity Monitor's Energy column does), the helper can be removed and ADR 0006 reinstated.
- If the protocol-version churn becomes annoying for users, consider making the helper auto-update from inside the app (would require the helper to manage its own bundle on disk — significant complexity).
