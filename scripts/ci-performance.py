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


# Exact pre-performance Swift Charts trace and pointer overlay shipped in 0.1.1.
# Unsupported source shapes fail rather than silently substituting candidate algorithms.
LEGACY_CHART_TRACE_SHA256 = "c89b39b3927600a28777f2b24ed03eda78a6097d8f5ac3874695a7727f4e8842"
LEGACY_CHART_TRACK_SHA256 = "dc5570c539cf2c7e10acf0795ade15e1704cd64790a2386f05203e8fdc74d0e8"
LEGACY_CHART_BODY = r"""    var body:some View {
        // Retain this revision's original points/domain calculations, including the
        // domain's independent point scan. Only the unsupported drawing backend changes.
        let renderedPoints=points
        let renderedDomain=domain
        VStack(spacing:3) {
            ExplorerPlotCanvas {context,size in
                let duration=max(0.001,range.duration)
                let height=max(0.001,renderedDomain.upperBound-renderedDomain.lowerBound)
                func position(_ point:ExplorerPoint)->CGPoint {
                    CGPoint(x:point.time.timeIntervalSince(range.start)/duration*size.width,
                            y:size.height-(point.value-renderedDomain.lowerBound)/height*size.height)
                }
                for segment in Dictionary(grouping:renderedPoints,by:\.series).values {
                    guard let first=segment.first,let last=segment.last else {continue}
                    var line=Path();line.move(to:position(first))
                    for point in segment.dropFirst() {line.addLine(to:position(point))}
                    if metric=="CPU" && processID==nil {
                        var area=line
                        area.addLine(to:CGPoint(x:position(last).x,y:size.height))
                        area.addLine(to:CGPoint(x:position(first).x,y:size.height));area.closeSubpath()
                        context.fill(area,with:.color(color.opacity(0.07)))
                    }
                    context.stroke(line,with:.color(first.channel=="write" ? ExplorerPalette.energy : color),lineWidth:1.5)
                }
                if let cursor,range.start<=cursor,cursor<=range.end {
                    let x=cursor.timeIntervalSince(range.start)/duration*size.width
                    var line=Path();line.move(to:CGPoint(x:x,y:0));line.addLine(to:CGPoint(x:x,y:size.height))
                    context.stroke(line,with:.color(Color.secondary.opacity(0.55)),lineWidth:1)
                }
                for gap in gaps where gap.start<range.end && (gap.end ?? Date())>range.start {
                    let lower=max(range.start,gap.start),upper=min(range.end,gap.end ?? Date())
                    let x=lower.timeIntervalSince(range.start)/duration*size.width
                    context.fill(Path(CGRect(x:x,y:0,width:upper.timeIntervalSince(lower)/duration*size.width,height:size.height)),with:.color(.orange.opacity(0.08)))
                }
            }.clipped()
            if showXAxis {
                GeometryReader {geometry in
                    ForEach(0..<5,id:\.self) {index in
                        let date=range.start.addingTimeInterval(range.duration*Double(index)/4)
                        Text(date.formatted(.dateTime.hour().minute().second()))
                            .font(.system(size:9)).foregroundStyle(.secondary)
                            .frame(width:90,alignment:index==0 ? .leading : index==4 ? .trailing : .center)
                            .position(x:index==0 ? 45 : index==4 ? geometry.size.width-45 : geometry.size.width*Double(index)/4,y:6)
                    }
                }.frame(height:13)
            }
        }
    }
}

"""
LEGACY_CHART_OVERLAY = r"""                .chartOverlay {proxy in
                    GeometryReader {geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged {event in
                            guard let plot=proxy.plotFrame else {return}
                            let x=min(max(0,event.location.x-geometry[plot].origin.x),geometry[plot].width)
                            if let date:Date=proxy.value(atX:x),range.contains(date) {onSelect(date)}
                        })
                    }
                }"""
LEGACY_QUARTZ_OVERLAY = r"""                .overlay {
                    GeometryReader {geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged {event in
                            guard geometry.size.width>0 else {return}
                            let fraction=min(1,max(0,event.location.x/geometry.size.width))
                            onSelect(range.start.addingTimeInterval(range.duration*fraction))
                        })
                    }
                }"""


def normalize_legacy_charts(source):
    """Replace only the known drawing body/ChartProxy overlay; leave model work intact."""
    try:
        trace_start = source.index("struct ExplorerTrace:View {")
        trace_end = source.index("// Existing callers can keep", trace_start)
        track_start = source.index("private struct ExplorerSystemTrack:View {")
        track_end = source.index("\nprivate struct ProcessInspector", track_start)
    except ValueError as error:
        raise ValueError("Unknown baseline Swift Charts layout; refusing to change its workload.") from error
    trace, track = source[trace_start:trace_end], source[track_start:track_end]
    if (hashlib.sha256(trace.encode()).hexdigest() != LEGACY_CHART_TRACE_SHA256 or
            hashlib.sha256(track.encode()).hexdigest() != LEGACY_CHART_TRACK_SHA256):
        raise ValueError("Unknown baseline Swift Charts implementation; refusing to change its workload.")
    marker = "    var body:some View {"
    if trace.count(marker) != 1 or track.count(LEGACY_CHART_OVERLAY) != 1:
        raise ValueError("Unknown baseline Swift Charts body or pointer overlay.")
    # Everything before the body includes the unmodified old points/domain properties.
    rewritten_trace = trace[:trace.index(marker)] + LEGACY_CHART_BODY
    return source.replace(trace, rewritten_trace, 1).replace(LEGACY_CHART_OVERLAY, LEGACY_QUARTZ_OVERLAY, 1)


def prepare_baseline_renderer(baseline, candidate=ROOT):
    """Normalize unsupported historical rendering backends without candidate model changes."""
    path = baseline / "Sources/Watt/ProcessExplorerView.swift"
    source = path.read_text()
    if "ExplorerPlotCanvas {context,size in" in source:
        return {"applied": False}
    marker = "Canvas {context,size in"
    if marker in source:
        if source.count(marker) != 1:
            raise ValueError("Unknown baseline Canvas layout; refusing to change its workload.")
        rewritten = source.replace(marker, "ExplorerPlotCanvas {context,size in", 1)
        previous_backend = "swiftui-canvas"
        reason = "Hosted Intel Metal unavailable; plotting operations and data preparation preserved."
    elif "Chart {" in source:
        rewritten = normalize_legacy_charts(source)
        previous_backend = "swift-charts"
        reason = "Hosted Intel Metal unavailable; original points/domain preparation retained, drawing and pointer overlay normalized."
    else:
        return {"applied": False}
    adapter = (candidate / PLOT_ADAPTER).read_bytes()
    target = baseline / PLOT_ADAPTER
    if target.is_symlink():
        raise ValueError("Unsafe baseline plotting adapter destination.")
    target.write_bytes(adapter)
    path.write_text(rewritten)
    return {"applied": True, "backend": "native-quartz", "previous_backend": previous_backend,
            "reason": reason, "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
            "adapter_sha256": hashlib.sha256(adapter).hexdigest()}


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
