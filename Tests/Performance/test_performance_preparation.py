import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("ci_performance", ROOT / "scripts/ci-performance.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


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
