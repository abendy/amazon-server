"""VMAF log parsing, worst windows and the #553 advice."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from encode_review import results


def log_with(scores: list[float], pooled_mean: float | None = None) -> dict:
    log = {"frames": [{"frameNum": n, "metrics": {"vmaf": v}} for n, v in enumerate(scores)]}
    if pooled_mean is not None:
        log["pooled_metrics"] = {"vmaf": {"mean": pooled_mean}}
    return log


class ResultsTest(unittest.TestCase):
    def test_summary_numbers(self) -> None:
        scores = [95.0] * 99 + [40.0]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "vmaf.json"
            path.write_text(json.dumps(log_with(scores, pooled_mean=94.45)))
            summary = results.summarize(path, fps=10)
        self.assertEqual(summary["vmaf"]["mean"], 94.45)
        self.assertEqual(summary["vmaf"]["min"], 40.0)
        self.assertEqual(summary["vmaf"]["p1"], 40.0)
        self.assertEqual(summary["vmaf"]["frames_scored"], 100)

    def test_mean_falls_back_to_frames(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "vmaf.json"
            path.write_text(json.dumps(log_with([90.0, 100.0])))
            self.assertEqual(results.summarize(path, fps=24)["vmaf"]["mean"], 95.0)

    def test_empty_log_is_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "vmaf.json"
            path.write_text(json.dumps({"frames": []}))
            with self.assertRaises(ValueError):
                results.summarize(path, fps=24)

    def test_percentile_nearest_rank(self) -> None:
        values = sorted(float(v) for v in range(1, 201))
        self.assertEqual(results.percentile(values, 0.01), 2.0)
        self.assertEqual(results.percentile([7.0], 0.01), 7.0)

    def test_worst_windows_find_the_burst_and_do_not_overlap(self) -> None:
        fps = 10.0
        scores = [96.0] * 300  # 30 seconds
        for frame in range(150, 155):  # a burst at 15.0-15.4 s
            scores[frame] = 50.0
        scores[42] = 70.0  # one bad frame at 4.2 s
        windows = results.worst_windows(list(enumerate(scores)), fps, count=3)
        self.assertEqual(len(windows), 3)
        self.assertLessEqual(windows[0]["start"], 15.0)
        self.assertGreater(windows[0]["end"], 15.4)
        self.assertEqual(windows[0]["worst_vmaf"], 50.0)
        self.assertAlmostEqual(windows[0]["worst_time"], 15.0)
        self.assertEqual(windows[1]["worst_time"], 4.2)
        for a in windows:
            for b in windows:
                if a is not b:
                    self.assertTrue(a["end"] <= b["start"] or a["start"] >= b["end"])
        self.assertEqual([w["mean"] for w in windows], sorted(w["mean"] for w in windows))

    def test_worst_windows_with_subsampled_frames(self) -> None:
        scores = [(n, 90.0 if n != 40 else 30.0) for n in range(0, 96, 2)]  # every 2nd frame
        windows = results.worst_windows(scores, fps=24.0, count=2)
        self.assertEqual(windows[0]["worst_vmaf"], 30.0)
        self.assertAlmostEqual(windows[0]["worst_time"], 40 / 24, places=3)

    def test_worst_windows_short_clip(self) -> None:
        windows = results.worst_windows([(0, 80.0), (1, 85.0)], fps=24.0)
        self.assertEqual(len(windows), 1)
        self.assertEqual(windows[0]["worst_vmaf"], 80.0)

    def test_rule_553_is_advice_on_both_parts(self) -> None:
        self.assertEqual(results.rule_553(100, 80, 92.0),
                         {"reduction": 0.2, "smaller_enough": True, "vmaf_enough": True})
        self.assertFalse(results.rule_553(100, 90, 95.0)["smaller_enough"])
        self.assertFalse(results.rule_553(100, 50, 89.99)["vmaf_enough"])


if __name__ == "__main__":
    unittest.main()
