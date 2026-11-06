#!/usr/bin/env python3
"""Best-effort stack diagnostics after a failed gate; never used as a measurement."""
import datetime
import json
import os
import pathlib
import platform
import signal
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "dist" / "performance" / "diagnostics"
EXECUTABLE = ROOT / "dist" / "Watt.app" / "Contents" / "MacOS" / "Watt"
SAMPLE_SECONDS = 5
BENCHMARK_TIMEOUT_SECONDS = 60


def terminate(process):
    """Bound cleanup too, recording an error rather than losing diagnostic metadata."""
    if process is None or process.poll() is not None:
        return None
    try:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=2)
    except (OSError, subprocess.TimeoutExpired) as error:
        return type(error).__name__
    return None


def hardware():
    # Fixed public hardware fields only. No environment, host name, serial,
    # account information, signing inputs or broad system profiler output.
    result = {
        "diagnostics_only": True,
        "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "machine": platform.machine(),
        "macos": platform.mac_ver()[0],
        "kernel_release": platform.release(),
        "hardware": {},
    }
    for name in ("machdep.cpu.brand_string", "hw.model", "hw.physicalcpu", "hw.logicalcpu", "hw.memsize"):
        try:
            command = subprocess.run(["/usr/sbin/sysctl", "-n", name], capture_output=True,
                                     text=True, timeout=3, check=False)
            result["hardware"][name] = {
                "returncode": command.returncode,
                "value": command.stdout.strip()[:4096] if command.returncode == 0 else None,
                "error": command.stderr.strip()[:256] if command.returncode else None,
            }
        except (OSError, subprocess.TimeoutExpired) as error:
            result["hardware"][name] = {"error": type(error).__name__}
    return result


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    report = OUTPUT / "cpu-sample.txt"
    metadata = hardware()
    metadata["profile"] = {
        "workload": "existing --benchmark-ui fixture, unchanged",
        "requested_sample_seconds": SAMPLE_SECONDS,
        "benchmark_timeout_seconds": BENCHMARK_TIMEOUT_SECONDS,
        "partial": True,
    }
    status = metadata["profile"]
    benchmark = sampler = None
    report.unlink(missing_ok=True)
    started = time.monotonic()
    try:
        with (OUTPUT / "stdout").open("wb") as stdout, (OUTPUT / "stderr").open("wb") as stderr:
            if not EXECUTABLE.is_file() or not os.access(EXECUTABLE, os.X_OK):
                raise FileNotFoundError("The candidate release app is not available for diagnostics")
            benchmark = subprocess.Popen([str(EXECUTABLE), "--benchmark-ui"], cwd=ROOT,
                                         stdout=stdout, stderr=stderr, start_new_session=True)
            sampled_at = time.monotonic()
            sampler = subprocess.Popen(["/usr/bin/sample", str(benchmark.pid), str(SAMPLE_SECONDS), "1",
                                        "-mayDie", "-file", str(report)], cwd=ROOT,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                sample_stdout, sample_stderr = sampler.communicate(timeout=SAMPLE_SECONDS + 10)
                status["sampler_returncode"] = sampler.returncode
                status["sampler_stdout"] = sample_stdout.decode(errors="replace")[-4096:]
                status["sampler_stderr"] = sample_stderr.decode(errors="replace")[-4096:]
            except subprocess.TimeoutExpired:
                status["sampler_timeout"] = True
                terminate(sampler)
            status["sampling_elapsed_seconds"] = time.monotonic() - sampled_at
            status["benchmark_exited_during_sampling"] = benchmark.poll() is not None
            try:
                remaining = max(0, BENCHMARK_TIMEOUT_SECONDS - (time.monotonic() - started))
                status["benchmark_returncode"] = benchmark.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                status["benchmark_timeout"] = True
                terminate(benchmark)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        status["error"] = str(error)
    finally:
        for name, process in (("sampler", sampler), ("benchmark", benchmark)):
            error = terminate(process)
            if error:
                status[name + "_cleanup_error"] = error
        status["elapsed_seconds"] = time.monotonic() - started
        status["stack_report_available"] = report.is_file() and report.stat().st_size > 0
        status["partial"] = (status.get("benchmark_exited_during_sampling", True)
                             or status.get("sampler_returncode") != 0
                             or not status["stack_report_available"])
        status["completed"] = (status.get("benchmark_returncode") == 0
                               and status.get("sampler_returncode") == 0
                               and status["stack_report_available"])
        if not status["stack_report_available"]:
            report.write_text("No CPU stack report was produced. See runner-hardware.json for diagnostic failure details.\n")
        # Always preserve these files even if process launch failed.
        (OUTPUT / "stdout").touch(exist_ok=True)
        (OUTPUT / "stderr").touch(exist_ok=True)
        (OUTPUT / "runner-hardware.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    print("Failure-only UI diagnostics saved to dist/performance/diagnostics; gate results are unchanged.")
    return 0 if status["completed"] else 1


if __name__ == "__main__":
    sys.exit(main())
