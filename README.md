# Watt

Native macOS menu bar performance recorder. See the [design plan](docs/WATT_PLAN.md).

## Build and run

Requires macOS 14+ and Swift. Tests require full Xcode. If Command Line Tools is selected, set `DEVELOPER_DIR` to your Xcode app's `Contents/Developer` for these commands.

```sh
swift run Watt
zsh scripts/build-app.sh
open dist/Watt.app
```

The development build opens the unified Process Explorer at launch. Click the menu bar item for the popup. Its controls are direct buttons: Open Process Explorer, Preferences and Quit. Preferences combines appearance, the sample interval, popup layout editing, and updates.

## One Process Explorer

Live processes and history share one window and selection. Use Live for current readings. Choose a date/time and 5-minute, 15-minute, one-hour or two-hour window, then Inspect interval. Earlier/Later queries older SQLite records beyond the live cache. At cursor shows a recorded process snapshot and optional observed parent tree. Interval summary shows time-weighted CPU average, sampled CPU peak, CPU time, last/peak footprint, observed footprint growth and valid disk totals. Move the cursor to switch back to the point view within the same window. Select a process for CPU, memory and disk curves.

Rank/filter by CPU, memory, disk read or disk write. PID plus start identity keeps separate lifetimes distinct. Parent links are observations, not a complete execution trace. Polling can miss short-lived processes. Access failures and recording gaps remain visible. Memory footprints are not additive, and a coincident security-process spike does not establish EDR causality.

## Menu bar appearance

Open Preferences to choose Ribbon (simple meters by default, with optional history bars or lines) or two-line numbers; width; upper/lower CPU, memory, network or battery-power rows; network lanes; numeric overlays; and color. Settings apply immediately and persist across launches. Appearance includes a live 2× rendering preview.

CPU and memory percentage overlays are enabled by default, prefixed C and M so they remain identifiable without color. With color enabled, CPU meters use mint and memory meters use purple. In Ribbon mode, steady-color numbers sit above a separate meter stroke. Upload/download rates use directional arrows and whole-number K values. K/M/G denote KiB/s, MiB/s and GiB/s, with exact values in the live popup and tooltip. All three numeric channels require at least 52 pt; wider options give the graphs more space. Numeric mode uses the full width for two chosen readings.

## Measurements and limits

Native collectors provide CPU, a VM memory estimate, compression/swap, physical-interface network counters, observable process CPU/physical footprint/disk counters, and battery electrical power. The menu bar memory value is estimated used RAM percentage, not pressure. Process CPU uses 100% per core; machine CPU is normalized to total capacity. Disk rates use measured elapsed intervals, not the timer's nominal cadence.

Battery watts estimate voltage × signed current. The popup shows the observed source and inputs. A zero-current reading while disconnected from external power is unavailable, rather than a valid zero-watt discharge. Instantaneous current is preferred, with a negative average-current fallback on battery. Battery sensing does not provide CPU/GPU/SoC power, adapter wattage or total consumption on AC. Separate per-process CPU power estimates use macOS energy counters when available. Units follow Apple's [IOPMPowerSource documentation](https://developer.apple.com/documentation/kernel/iopmpowersource?changes=la).

SQLite is local at `~/Library/Application Support/Watt/history.sqlite`, outside this checkout. Schema 3 migrates original frame records. Retention is up to 48 hours, subject to a 4 GiB payload quota within an 8 GiB file budget and a 256 MiB free-space reserve. Oldest detail is pruned first. WAL checkpointing is bounded; a transaction/WAL may briefly exceed the file threshold before recovery. Continued writing reports an error if it cannot recover.

Pauses, sleep/wake, restarts, delayed polling, clock discontinuities and write failures reset baselines and create persisted gaps. A timestamp without nearby coverage does not substitute a distant observation. Write failures can delay persisting a gap until recovery. Abrupt termination can lose an unpersisted failure reason; restart still marks unobserved time.

The live cache contains up to 720 frames. Historical queries are bounded to 1,500 frames and 96 MiB of payload. Oversized requests ask for a narrower window instead of silently dropping samples. Totals use complete known intervals and exclude gaps. Earlier records without elapsed metadata can show gauges/peaks but cannot supply reliable CPU time or interval totals. There are no rollups or recovery of expired/unrecorded detail.

Still to implement: hardware temperature/component-power collectors, live validation of privileged energy collection, pressure accounting, incident/build markers and baseline comparison, long-term rollups, exact coalition attribution, export, more accessibility work and measured width parity. iStat and security settings are untouched.

## Validation

```sh
swift test
swift run Watt --smoke-test
swift run Watt --benchmark
```

Automated tests cover identity, counters, retention, quotas/recovery, migrations, gaps, time discontinuities, disk/battery units, appearance persistence, bounded older-history queries and interval accounting. The running history drilldown has been exercised against saved records with process curves and snapshots. See the [recorder benchmark](docs/RECORDER_BENCHMARK.md) for a short recorder-only measurement; it excludes GUI cost, long-duration behavior and causal build overhead.

Outside-click handling uses transient popovers, mouse monitors, focus changes and explicit activation. The automation's Finder actions have not reliably exercised foreground dismissal, so this remains unconfirmed. Debug builds write `window-state.json` alongside history containing window flags, width and a timestamp; no click coordinates or event logs are stored. Actual disk-full recovery, physical sleep/wake, controlled builds and overnight behavior still need validation.

Visual refinement: the popup footer uses one full-width Explorer action, a plain Preferences/Quit utility row. Unsupported sensor status remains in appearance settings rather than a permanent footer warning. Simple meters are the default menu bar graphs. Digits retain native light/dark contrast, with graph strokes below their baselines. [Renderer preview](docs/design/watt-menu-clean.png) uses illustrative values from the actual drawing code at 1× and 4×; reproduce with `swift run Watt --render-menu-preview /tmp/watt-menu-clean.png`.

The [popup refinement preview](docs/design/watt-popup-dashboard.png) is rendered from the actual SwiftUI content with explicit illustrative data, without opening the recording database. Reproduce with `swift run Watt --render-popup-preview /tmp/watt-popup.png`.

CI and signed/notarized releases are documented in [RELEASING.md](docs/RELEASING.md).

Popup layout: Preferences opens a separate layout editor. Metric tiles occupy a configurable two-to-six-column square grid. Drag disabled tiles from Available into the popup preview, reorder them there, or drag them back to hide. A tile can optionally span the full width. Order, visibility, and widths persist. More tiles scroll within the popup; the footer remains reachable.

Per-process CPU energy: supported ARM Macs expose cumulative nanojoules through `proc_pid_rusage(RUSAGE_INFO_V6)`. Watt stores interval deltas, derives estimated watts from measured elapsed time, and records joules over covered historical intervals. Missing/protected/unsupported readings use a dash; a measured zero remains zero. This CPU-only estimate is not Activity Monitor's Energy Impact score, GPU energy, or whole-system power. Kernel semantics: [Apple Recount](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/recount.h).

Apple Energy Impact: the optional signed helper runs a fixed, bounded `powermetrics` capture. Install or remove it in Preferences; macOS requires administrator approval in Login Items & Extensions. The helper and app enforce matching Developer ID teams and exact signing identifiers on their XPC connection. Scores retain their capture timestamps/IDs in SQLite and are separate from CPU watts. Historical scores count unique captures and exclude gaps. The process table only joins matching process lifetimes; missing/stale readings stay unavailable. Live privileged collection requires validation on an approved signed installation.
