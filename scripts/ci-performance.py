#!/usr/bin/env python3
"""Build a baseline and compare three UI workload runs on this runner."""
import hashlib
import json
import os
import pathlib
import platform
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "dist" / "performance"
HARNESS = pathlib.Path("Sources/Watt/UIPerformanceBenchmark.swift")
PLOT_ADAPTER = pathlib.Path("Sources/Watt/ExplorerPlotCanvas.swift")


def prepare_baseline_renderer(baseline, candidate=ROOT):
    """Use Quartz for the short-lived Canvas baseline that hosted Intel GPUs cannot render.

    Preserve its plotting operations and data preparation. Never rewrite the candidate,
    or replace an existing native backend in a later baseline.
    """
    path = baseline / "Sources/Watt/ProcessExplorerView.swift"
    source = path.read_text()
    marker = "Canvas {context,size in"
    if marker not in source or "ExplorerPlotCanvas {context,size in" in source:
        return {"applied": False}
    if source.count(marker) != 1:
        raise ValueError("Unknown baseline Canvas layout; refusing to change its workload.")
    adapter = (candidate / PLOT_ADAPTER).read_bytes()
    target = baseline / PLOT_ADAPTER
    if target.is_symlink():
        raise ValueError("Unsafe baseline plotting adapter destination.")
    target.write_bytes(adapter)
    path.write_text(source.replace(marker, "ExplorerPlotCanvas {context,size in", 1))
    return {"applied": True, "backend": "native-quartz", "adapter_sha256": hashlib.sha256(adapter).hexdigest()}


def run(command, *, cwd=ROOT, log=None, timeout=900, env=None):
    if log:
        with log.open("w") as handle:
            subprocess.run(command, cwd=cwd, check=True, timeout=timeout,
                           stdout=handle, stderr=subprocess.STDOUT, env=env)
        return ""
    return subprocess.check_output(command, cwd=cwd, text=True, timeout=timeout, env=env).strip()


def baseline_revision():
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    event = json.loads(pathlib.Path(event_path).read_text()) if event_path else {}
    if os.environ.get("GITHUB_EVENT_NAME") == "pull_request":
        requested = event.get("pull_request", {}).get("base", {}).get("sha")
    else:
        requested = event.get("before")
    if requested and requested != "0" * 40:
        if not re.fullmatch(r"[0-9a-fA-F]{40}", requested):
            raise ValueError("The comparison baseline must be an exact commit SHA.")
        return run(["git", "rev-parse", "--verify", requested + "^{commit}"])
    return run(["git", "rev-parse", "--verify", "HEAD^"])


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    if platform.machine() != "x86_64":
        raise ValueError("The calibrated CI comparison requires a native Intel runner.")
    baseline_sha = baseline_revision()
    candidate_sha = run(["git", "rev-parse", "HEAD"])
    harness = (ROOT / HARNESS).read_bytes()
    if b"runUIPerformanceBenchmark" not in harness:
        raise ValueError("Candidate has no compatible UI benchmark harness.")
    metadata = {"baseline_sha": baseline_sha, "candidate_sha": candidate_sha,
                "harness_sha256": hashlib.sha256(harness).hexdigest(),
                "machine": platform.machine(), "macos": platform.mac_ver()[0],
                "developer_dir": os.environ.get("DEVELOPER_DIR"),
                "swift_version": run(["swift", "--version"]),
                "order": ["baseline", "candidate", "candidate", "baseline", "baseline", "candidate"]}
    (OUTPUT / "environment.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    with tempfile.TemporaryDirectory(prefix="watt-performance-", dir=os.environ.get("RUNNER_TEMP")) as temporary:
        scratch = pathlib.Path(temporary)
        baseline = scratch / "baseline"
        baseline.mkdir()
        archive = scratch / "baseline.tar"
        run(["git", "archive", "--format=tar", "--output", str(archive), baseline_sha])
        run(["tar", "-xf", str(archive), "-C", str(baseline)])
        target = baseline / HARNESS
        if not target.parent.resolve().is_relative_to(baseline.resolve()) or target.is_symlink():
            raise ValueError("Unsafe baseline harness destination.")
        target.write_bytes(harness)
        main_path = baseline / "Sources/Watt/main.swift"
        source = main_path.read_text()
        if '"--benchmark-ui"' not in source:
            marker = 'if CommandLine.arguments.contains("--diagnose-settings") {'
            if source.count(marker) != 1:
                raise ValueError("The baseline main.swift has no unique benchmark injection point.")
            hook = 'if CommandLine.arguments.contains("--benchmark-ui") {MainActor.assumeIsolated {runUIPerformanceBenchmark()};exit(0)}\n'
            main_path.write_text(source.replace(marker, hook + marker, 1))
        metadata["baseline_renderer_compatibility"] = prepare_baseline_renderer(baseline)
        (OUTPUT / "environment.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
        # Match the source workload exactly while preserving each revision's app implementation.
        (OUTPUT / "harness.swift").write_bytes(harness)
        run(["zsh", "scripts/build-app.sh", "release"], cwd=baseline, log=OUTPUT / "baseline-build.log",
            env={**os.environ, "UNIVERSAL": "0"})
        executables = {"baseline": baseline / "dist/Watt.app/Contents/MacOS/Watt",
                       "candidate": ROOT / "dist/Watt.app/Contents/MacOS/Watt"}
        counters = {"baseline": 0, "candidate": 0}
        for revision in metadata["order"]:
            counters[revision] += 1
            stem = f"{revision}-{counters[revision]}"
            output = OUTPUT / (stem + ".json")
            output.unlink(missing_ok=True)
            try:
                process = subprocess.run([str(executables[revision]), "--benchmark-ui", "--benchmark-output", str(output)],
                                         cwd=ROOT, capture_output=True, text=True, timeout=180)
            except subprocess.TimeoutExpired as error:
                for kind, content in (("stdout", error.stdout), ("stderr", error.stderr)):
                    if isinstance(content, bytes):
                        content = content.decode(errors="replace")
                    (OUTPUT / (stem + f".{kind}.log")).write_text(content or "")
                raise ValueError(f"{stem}: benchmark did not finish within 180 seconds") from error
            (OUTPUT / (stem + ".stdout.log")).write_text(process.stdout)
            (OUTPUT / (stem + ".stderr.log")).write_text(process.stderr)
            if process.returncode:
                raise ValueError(f"{stem}: benchmark failed with exit status {process.returncode}")
            if not output.exists():
                # The CLI can emit its strict JSON document on stdout instead of a file.
                json.loads(process.stdout)
                output.write_text(process.stdout)
        command = [sys.executable, str(ROOT / "scripts/check-performance.py"), "--baseline"]
        command += [str(OUTPUT / f"baseline-{index}.json") for index in range(1, 4)]
        command += ["--candidate"] + [str(OUTPUT / f"candidate-{index}.json") for index in range(1, 4)]
        command += ["--max-cpu-ms", "650", "--max-resident-mib", "400", "--max-peak-mib", "512",
                    "--output", str(OUTPUT / "summary.json")]
        return subprocess.run(command, cwd=ROOT).returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        OUTPUT.mkdir(parents=True, exist_ok=True)
        (OUTPUT / "failure.json").write_text(json.dumps({"passed": False, "failure": str(error)}, indent=2) + "\n")
        print(f"Performance gate failed: {error}", file=sys.stderr)
        sys.exit(1)
