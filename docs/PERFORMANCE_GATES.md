# Performance regression checks

CI compares the candidate app with its base revision on the same native Intel
GitHub-hosted macOS runner. Pull requests use the exact PR base commit; pushes use
the previous commit from the push event. Manual and reusable workflow runs use
the candidate's parent when the event has no base commit.

The check copies the candidate's deterministic UI harness into the baseline,
builds both in release configuration with the same toolchain, and runs each
revision three times. The run order is baseline/candidate/candidate/baseline/
baseline/candidate to reduce order effects. Every process performs two unmeasured
warmup updates before measuring 12 Explorer updates, each with 120 frames and 800
processes. The harness uses fixture readings and an offscreen native window. It
does not open the recording database, register a helper, collect live energy
readings, or test battery life.

The gate compares the median process CPU time per update, resident memory after
the workload, and the largest resident-memory sample observed at update
boundaries. The latter is a sampled peak, not proof of the process's instantaneous
high-water mark. Build time is excluded.

| Measurement | Allowed relative variation | Candidate absolute ceiling |
| --- | --- | --- |
| CPU milliseconds per update | baseline × 1.20 + 2 ms | 500 ms |
| Resident memory | baseline × 1.15 + 8 MiB | 400 MiB |
| Sampled peak resident memory | baseline × 1.15 + 8 MiB | 512 MiB |

The relative allowance accounts for timing, allocator and graphics-service noise
on hosted runners. Three-run medians avoid treating one scheduling interruption
as a source regression. Absolute ceilings prevent an already expensive baseline
from making every candidate acceptable. Initial ceilings are deliberately broad
across Intel runner generations; tighten them using retained same-runner results
rather than extrapolating from Apple Silicon measurements. A change exceeding
either limit fails CI. Missing runs, unsupported workloads, zero/non-finite
measurements and mismatched warmup conditions also fail instead of passing an
empty check.

Every attempted check saves its base/candidate SHAs, harness hash, toolchain,
raw JSON measurements, build/process logs and comparison summary in a
`performance-...` workflow artifact, including failures. `scripts/check-performance.py`
has regression tests that deliberately exceed CPU, resident-memory and peak-memory
limits and verify that those candidates are rejected.

This is a repeatable Explorer CPU/memory gate. It does not yet cover background
recorder/helper overhead, disk traffic, wakeups, sustained leaks, or every user
interaction. It must not be described as proof that a change has no performance
impact. Release workflows call this CI workflow and stop if verification fails.
Repository merge rules remain separate: the current release publisher pushes
signed feeds directly to `main`, so enabling branch protection requires preserving
that publication path rather than simply making every direct push illegal.

Run checker tests locally with:

```sh
python3 -m unittest discover -s Tests/Performance -v
```

`scripts/ci-performance.py` is for an Intel macOS runner with a full checkout and
the candidate's release app already built in `dist/Watt.app`.
