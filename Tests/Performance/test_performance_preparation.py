import importlib.util
import hashlib
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("ci_performance", ROOT / "scripts/ci-performance.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


# Exact legacy trace and track from 844f6ea (v0.1.1); model properties are part of the fixture.
LEGACY_SWIFT_CHARTS_SOURCE = r'''import SwiftUI
import Charts

private struct ExplorerSystemTrack:View {
    let title:String
    let value:String
    let subtitle:String
    let metric:String
    let color:Color
    let frames:[Frame]
    let range:DateInterval
    let cursor:Date?
    let gaps:[RecordingGap]
    let onSelect:(Date)->Void
    var body:some View {
        HStack(spacing:16) {
            VStack(alignment:.leading,spacing:3) {
                HStack(spacing:10) {Text(title).fontWeight(.semibold).foregroundStyle(color);Text(value).monospacedDigit()}.font(.system(size:11))
                Text(subtitle).font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width:255,alignment:.leading)
            ExplorerTrace(frames:frames,range:range,cursor:cursor,processID:nil,metric:metric,gaps:gaps,showXAxis:metric=="Disk")
                .frame(height:metric=="Disk" ? 61 : 42)
                .chartOverlay {proxy in
                    GeometryReader {geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged {event in
                            guard let plot=proxy.plotFrame else {return}
                            let x=min(max(0,event.location.x-geometry[plot].origin.x),geometry[plot].width)
                            if let date:Date=proxy.value(atX:x),range.contains(date) {onSelect(date)}
                        })
                    }
                }.accessibilityLabel("\(title) timeline")
        }.padding(.vertical,6).overlay(alignment:.bottom) {if metric != "Disk" {Divider().opacity(0.5)}}
    }
}

private struct ProcessInspector:View {}

struct ExplorerTrace:View {
    let frames:[Frame]
    let range:DateInterval
    let cursor:Date?
    let processID:String?
    let metric:String
    let gaps:[RecordingGap]
    var showXAxis=false
    private var color:Color {metric=="Memory" ? ExplorerPalette.memory : metric=="Disk" ? ExplorerPalette.disk : metric=="Energy" ? ExplorerPalette.energy : ExplorerPalette.cpu}
    private var points:[ExplorerPoint] {
        let correctedProcessCPU=processID != nil && metric=="CPU" && frames.contains {$0.processCPUAccounting != nil}
        var result:[ExplorerPoint]=[];var run=0
        for frame in frames.sorted(by:{$0.time<$1.time}) {
            let process=processID.flatMap {id in frame.processes.first {$0.id==id}}
            let elapsed=frame.elapsed ?? 0
            let blocked=elapsed>0 && gaps.contains {$0.start<frame.time && ($0.end ?? .distantFuture)>frame.time.addingTimeInterval(-elapsed)}
            var values:[(String,Double)]=[]
            if !blocked {
                switch metric {
                case "Memory":
                    if processID == nil {values=[("value",Double(frame.memory)/1048576)]}
                    else if let process {values=[("value",Double(process.memory)/1048576)]}
                case "Disk":
                    if elapsed>0 {
                        if processID == nil {
                            let reads=frame.processes.compactMap(\.read),writes=frame.processes.compactMap(\.written)
                            if !reads.isEmpty {values.append(("read",reads.reduce(0.0) {$0+Double($1)}/elapsed/1048576))}
                            if !writes.isEmpty {values.append(("write",writes.reduce(0.0) {$0+Double($1)}/elapsed/1048576))}
                        } else if let process {
                            if let read=process.read {values.append(("read",Double(read)/elapsed/1048576))}
                            if let written=process.written {values.append(("write",Double(written)/elapsed/1048576))}
                        }
                    }
                case "Energy":if let watts=process?.cpuPowerWatts(elapsed:frame.elapsed) {values=[("value",watts)]}
                default:
                    if processID == nil {values=[("value",frame.cpu)]}
                    else if let cpu=process?.cpu,!correctedProcessCPU || frame.processCPUAccounting != nil {values=[("value",cpu)]}
                }
            }
            if values.isEmpty {run+=1;continue}
            for (channel,value) in values where value.isFinite {
                result.append(ExplorerPoint(time:frame.time,value:value,series:(frame.segment ?? "legacy")+"-\(run)-"+channel,channel:channel))
            }
        }
        return result
    }
    private var domain:ClosedRange<Double> {
        if metric=="CPU" && processID==nil {return 0...100}
        if metric=="Memory" && processID==nil {return 0...Double(ProcessInfo.processInfo.physicalMemory)/1048576}
        return 0...max(1,(points.map(\.value).max() ?? 1)*1.08)
    }
    var body:some View {
        Chart {
            ForEach(points) {point in
                if metric=="CPU" && processID==nil {
                    AreaMark(x:.value("Time",point.time),y:.value("Value",point.value),series:.value("Series",point.series)).foregroundStyle(color.opacity(0.07))
                }
                LineMark(x:.value("Time",point.time),y:.value("Value",point.value),series:.value("Series",point.series))
                    .foregroundStyle(point.channel=="write" ? ExplorerPalette.energy : color).lineStyle(StrokeStyle(lineWidth:1.5))
            }
            if let cursor {RuleMark(x:.value("Cursor",cursor)).foregroundStyle(.secondary.opacity(0.55)).lineStyle(StrokeStyle(lineWidth:1))}
            ForEach(gaps.filter {$0.start<range.end && ($0.end ?? Date())>range.start}) {gap in
                RectangleMark(xStart:.value("Gap",max(range.start,gap.start)),xEnd:.value("Gap end",min(range.end,gap.end ?? Date()))).foregroundStyle(.orange.opacity(0.08))
            }
        }.chartXScale(domain:range.start...range.end).chartYScale(domain:domain).chartYAxis(.hidden).chartLegend(.hidden)
            .chartXAxis {
                if showXAxis {
                    AxisMarks(values:.automatic(desiredCount:5)) {value in
                        AxisValueLabel {
                            if let date=value.as(Date.self) {Text(date.formatted(.dateTime.hour().minute().second())).font(.system(size:9)).foregroundStyle(.secondary)}
                        }
                    }
                }
            }
    }
}

// Existing callers can keep the shared trace API.
'''


class BaselinePreparationTests(unittest.TestCase):
    def prepare(self, source, adapter=b"candidate adapter"):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = pathlib.Path(temporary.name)
        baseline, candidate = root / "baseline", root / "candidate"
        for path in (baseline, candidate):
            (path / "Sources/Watt").mkdir(parents=True)
        view = baseline / "Sources/Watt/ProcessExplorerView.swift"
        view.write_text(source)
        (candidate / ci.PLOT_ADAPTER).write_bytes(adapter)
        return baseline, candidate, view

    def test_canvas_platform_patch_preserves_plotting_work_and_records_backend(self):
        source = "projection\nCanvas {context,size in\nexisting drawing operations\n}\n"
        baseline, candidate, view = self.prepare(source)
        metadata = ci.prepare_baseline_renderer(baseline, candidate)
        self.assertTrue(metadata["applied"])
        self.assertEqual(view.read_text().replace("ExplorerPlotCanvas", "Canvas"), source)
        self.assertEqual((baseline / ci.PLOT_ADAPTER).read_bytes(), b"candidate adapter")
        self.assertEqual(len(metadata["adapter_sha256"]), 64)


    def test_legacy_swift_charts_preserves_old_points_and_domain_and_removes_proxy(self):
        source = LEGACY_SWIFT_CHARTS_SOURCE
        baseline, candidate, view = self.prepare(source)
        metadata = ci.prepare_baseline_renderer(baseline, candidate)
        rewritten = view.read_text()
        start = source.index("struct ExplorerTrace:View {")
        body = source.index("    var body:some View {", start)
        self.assertIn(source[start:body], rewritten, "The baseline model algorithms must remain byte-identical")
        self.assertIn("let renderedPoints=points", rewritten)
        self.assertIn("let renderedDomain=domain", rewritten)
        self.assertIn("context.fill(area", rewritten)
        self.assertIn("context.stroke(line", rewritten)
        self.assertIn("ForEach(0..<5", rewritten)
        self.assertNotIn("Chart {", rewritten)
        self.assertNotIn(".chartOverlay", rewritten)
        self.assertNotIn("proxy.value", rewritten)
        self.assertIn("event.location.x/geometry.size.width", rewritten)
        self.assertEqual(metadata["previous_backend"], "swift-charts")
        self.assertEqual(metadata["source_sha256"], hashlib.sha256(source.encode()).hexdigest())
        self.assertEqual((baseline / ci.PLOT_ADAPTER).read_bytes(), b"candidate adapter")
        self.assertEqual((candidate / ci.PLOT_ADAPTER).read_bytes(), b"candidate adapter")

    def test_changed_legacy_model_fails_before_source_or_adapter_is_written(self):
        source = LEGACY_SWIFT_CHARTS_SOURCE.replace("frames.sorted(by:", "frames.reversed().sorted(by:")
        baseline, candidate, view = self.prepare(source)
        with self.assertRaisesRegex(ValueError, "Unknown baseline Swift Charts implementation"):
            ci.prepare_baseline_renderer(baseline, candidate)
        self.assertEqual(view.read_text(), source)
        self.assertFalse((baseline / ci.PLOT_ADAPTER).exists())

    def test_unknown_chart_structure_is_not_silently_replaced(self):
        source = "struct ExplorerTrace:View {var body:some View {Chart {}}}"
        baseline, candidate, view = self.prepare(source)
        with self.assertRaisesRegex(ValueError, "Unknown baseline Swift Charts layout"):
            ci.prepare_baseline_renderer(baseline, candidate)
        self.assertEqual(view.read_text(), source)


    def test_existing_native_backend_is_never_replaced(self):
        baseline, candidate, view = self.prepare("ExplorerPlotCanvas {context,size in\nold operations\n}")
        original = b"original native backend"
        (baseline / ci.PLOT_ADAPTER).write_bytes(original)
        self.assertFalse(ci.prepare_baseline_renderer(baseline, candidate)["applied"])
        self.assertEqual((baseline / ci.PLOT_ADAPTER).read_bytes(), original)

    def test_unknown_layout_fails_instead_of_rewriting_multiple_charts(self):
        baseline, candidate, _ = self.prepare("Canvas {context,size in}\nCanvas {context,size in}")
        with self.assertRaises(ValueError):
            ci.prepare_baseline_renderer(baseline, candidate)


if __name__ == "__main__":
    unittest.main()
