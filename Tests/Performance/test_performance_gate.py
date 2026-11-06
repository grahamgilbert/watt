import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/check-performance.py"
spec = importlib.util.spec_from_file_location("performance_gate", SCRIPT)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class PerformanceGateTests(unittest.TestCase):
    def measurement(self, **changes):
        result = {**gate.WORKLOAD, "schema": 1, "workload": "explorer-render-v1", "warmup_updates": 2, "cpu_ms_per_update": 50,
                  "resident_bytes": 100 * gate.MIB, "peak_resident_bytes": 150 * gate.MIB}
        result.update(changes)
        return result

    def invoke(self, baseline, candidate):
        with tempfile.TemporaryDirectory() as directory:
            directory = pathlib.Path(directory)
            paths = {}
            for kind, values in (("baseline", baseline), ("candidate", candidate)):
                paths[kind] = []
                for index, value in enumerate(values):
                    path = directory / f"{kind}-{index}.json"
                    path.write_text(json.dumps(value))
                    paths[kind].append(str(path))
            output = directory / "summary.json"
            result = subprocess.run([sys.executable, str(SCRIPT), "--baseline", *paths["baseline"],
                                     "--candidate", *paths["candidate"], "--max-cpu-ms", "650",
                                     "--max-resident-mib", "400", "--max-peak-mib", "512",
                                     "--output", str(output)], capture_output=True)
            return result.returncode, json.loads(output.read_text())

    def test_improvements_and_declared_noise_budget_pass(self):
        before = [self.measurement()] * 3
        code, report = self.invoke(before, [self.measurement(cpu_ms_per_update=62,
                                                          resident_bytes=122 * gate.MIB)] * 3)
        self.assertEqual(code, 0)
        self.assertTrue(report["passed"])

    def test_cpu_resident_and_peak_regressions_each_fail(self):
        for changes in ({"cpu_ms_per_update": 63}, {"resident_bytes": 124 * gate.MIB},
                        {"peak_resident_bytes": 181 * gate.MIB}):
            with self.subTest(changes=changes):
                code, report = self.invoke([self.measurement()] * 3, [self.measurement(**changes)] * 3)
                self.assertEqual(code, 1)
                self.assertFalse(report["passed"])

    def test_absolute_budget_rejects_an_improved_but_still_expensive_candidate(self):
        code, report = self.invoke([self.measurement(cpu_ms_per_update=800)] * 3,
                                   [self.measurement(cpu_ms_per_update=700)] * 3)
        self.assertEqual(code, 1)
        self.assertTrue(any("absolute budget" in failure for failure in report["failures"]))

    def test_median_uses_three_runs_instead_of_one_timing_outlier(self):
        code, report = self.invoke([self.measurement()] * 3,
                                   [self.measurement(), self.measurement(),
                                    self.measurement(cpu_ms_per_update=1000)])
        self.assertEqual(code, 0)
        self.assertEqual(report["candidate_median"]["cpu_ms_per_update"], 50)

    def test_no_valid_measurements_or_smaller_workload_cannot_pass(self):
        for changes in ({"cpu_ms_per_update": 0}, {"cpu_ms_per_update": float("nan")},
                        {"resident_bytes": None}, {"peak_resident_bytes": True},
                        {"process_count": 100}, {"updates": 11}, {"warmup_updates": 0},
                        {"schema": 2}, {"workload": "smaller-workload"}):
            with self.subTest(changes=changes):
                code, report = self.invoke([self.measurement()] * 3,
                                           [self.measurement(**changes)] * 3)
                self.assertEqual(code, 1)
                self.assertFalse(report["passed"])

    def test_different_warmup_workload_is_rejected(self):
        code, report = self.invoke([self.measurement()] * 3,
                                   [self.measurement(warmup_updates=3)] * 3)
        self.assertEqual(code, 1)
        self.assertIn("same warmup", report["failures"][0])


if __name__ == "__main__":
    unittest.main()
