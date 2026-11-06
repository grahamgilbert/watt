#!/usr/bin/env python3
"""Compare repeated, identical Watt UI workloads on the same runner."""
import argparse
import json
import math
import pathlib
import statistics
import sys

MIB = 1024 * 1024
WORKLOAD = {"process_count": 800, "frame_count": 120, "updates": 12}
METRICS = ("cpu_ms_per_update", "resident_bytes", "peak_resident_bytes")


def validate_runs(paths):
    if len(paths) != 3:
        raise ValueError("Exactly three measured runs are required for each revision.")
    runs = []
    for path in paths:
        data = json.loads(pathlib.Path(path).read_text())
        if not isinstance(data, dict):
            raise ValueError(f"{path}: expected a JSON object")
        if type(data.get("schema")) is not int or data["schema"] != 1 or data.get("workload") != "explorer-render-v1":
            raise ValueError(f"{path}: unsupported benchmark schema or workload")
        for field, expected in WORKLOAD.items():
            value = data.get(field)
            if type(value) is not int or value != expected:
                raise ValueError(f"{path}: {field} must equal {expected}")
        warmup = data.get("warmup_updates")
        if type(warmup) is not int or warmup < 2:
            raise ValueError(f"{path}: at least two unmeasured warmup updates are required")
        for field in METRICS:
            value = data.get(field)
            if type(value) not in (int, float) or not math.isfinite(value) or value <= 0:
                raise ValueError(f"{path}: {field} must be a finite positive measurement")
        runs.append(data)
    return runs


def compare(baseline, candidate, *, max_cpu_ms, max_resident_mib, max_peak_mib):
    before = {metric: statistics.median(run[metric] for run in baseline) for metric in METRICS}
    after = {metric: statistics.median(run[metric] for run in candidate) for metric in METRICS}
    relative_limits = {
        "cpu_ms_per_update": before["cpu_ms_per_update"] * 1.20 + 2,
        "resident_bytes": before["resident_bytes"] * 1.15 + 8 * MIB,
        "peak_resident_bytes": before["peak_resident_bytes"] * 1.15 + 8 * MIB,
    }
    absolute_limits = {"cpu_ms_per_update": max_cpu_ms, "resident_bytes": max_resident_mib * MIB,
                       "peak_resident_bytes": max_peak_mib * MIB}
    failures = []
    for metric in METRICS:
        if after[metric] > relative_limits[metric]:
            failures.append(f"{metric}: candidate median {after[metric]:.3f} exceeds baseline noise budget {relative_limits[metric]:.3f}")
        if after[metric] > absolute_limits[metric]:
            failures.append(f"{metric}: candidate median {after[metric]:.3f} exceeds absolute budget {absolute_limits[metric]:.3f}")
    return {"passed": not failures, "baseline_median": before, "candidate_median": after,
            "relative_limits": relative_limits, "absolute_limits": absolute_limits, "failures": failures,
            "workload": WORKLOAD, "measured_runs_per_revision": 3}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", nargs=3, required=True)
    parser.add_argument("--candidate", nargs=3, required=True)
    parser.add_argument("--max-cpu-ms", type=float, required=True)
    parser.add_argument("--max-resident-mib", type=float, required=True)
    parser.add_argument("--max-peak-mib", type=float, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        if not all(math.isfinite(value) and value > 0 for value in
                   (args.max_cpu_ms, args.max_resident_mib, args.max_peak_mib)):
            raise ValueError("Absolute budgets must be finite positive values.")
        baseline = validate_runs(args.baseline)
        candidate = validate_runs(args.candidate)
        # Warmup is part of the common harness contract, not a tuning knob per revision.
        if len({run["warmup_updates"] for run in baseline + candidate}) != 1:
            raise ValueError("Baseline and candidate must use the same warmup workload.")
        report = compare(baseline, candidate, max_cpu_ms=args.max_cpu_ms,
                         max_resident_mib=args.max_resident_mib, max_peak_mib=args.max_peak_mib)
    except (ValueError, OSError, TypeError) as error:
        report = {"passed": False, "failures": [str(error)]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
