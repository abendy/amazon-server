"""VMAF log parsing: the numbers and the worst moments shown on the review page."""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any

WINDOW_S = 2.0
WINDOW_STEP_S = 1.0
WORST_WINDOWS = 5
STILLS = 3
# The #553 rule, shown as advice only: at least 15% smaller and VMAF mean >= 90.
RULE_MIN_REDUCTION = 0.15
RULE_MIN_VMAF = 90.0


def frame_scores(log: dict[str, Any]) -> list[tuple[int, float]]:
    """(frame number, VMAF) for every scored frame in a libvmaf JSON log."""
    scores: list[tuple[int, float]] = []
    for frame in log.get("frames", []):
        metrics = frame.get("metrics", {})
        if "vmaf" in metrics:
            scores.append((int(frame.get("frameNum", len(scores))), float(metrics["vmaf"])))
    return scores


def percentile(sorted_values: list[float], fraction: float) -> float:
    """The nearest-rank percentile of an ascending list."""
    if not sorted_values:
        return math.nan
    rank = max(1, math.ceil(fraction * len(sorted_values)))
    return sorted_values[rank - 1]


def worst_windows(scores: list[tuple[int, float]], fps: float,
                  count: int = WORST_WINDOWS) -> list[dict[str, Any]]:
    """The lowest-scoring 2-second windows that do not overlap, worst first."""
    if not scores or fps <= 0:
        return []
    last_time = scores[-1][0] / fps
    windows: list[dict[str, Any]] = []
    start = 0.0
    while True:
        end = start + WINDOW_S
        inside = [(n, v) for n, v in scores if start <= n / fps < end]
        if inside:
            worst_n, worst_v = min(inside, key=lambda item: item[1])
            windows.append({
                "start": round(start, 3),
                "end": round(min(end, last_time + 1 / fps), 3),
                "mean": round(sum(v for _, v in inside) / len(inside), 2),
                "worst_time": round(worst_n / fps, 3),
                "worst_vmaf": round(worst_v, 2),
            })
        if end > last_time:
            break
        start += WINDOW_STEP_S
    chosen: list[dict[str, Any]] = []
    for window in sorted(windows, key=lambda w: (w["mean"], w["start"])):
        if all(window["end"] <= c["start"] or window["start"] >= c["end"] for c in chosen):
            chosen.append(window)
        if len(chosen) == count:
            break
    return chosen


def summarize(log_path: Path, fps: float) -> dict[str, Any]:
    """The VMAF summary and worst windows for one attempt."""
    log = json.loads(log_path.read_text())
    scores = frame_scores(log)
    if not scores:
        raise ValueError("The VMAF log holds no frame scores.")
    values = sorted(v for _, v in scores)
    pooled = log.get("pooled_metrics", {}).get("vmaf", {})
    mean = float(pooled.get("mean", sum(values) / len(values)))
    return {
        "vmaf": {
            "mean": round(mean, 2),
            "min": round(values[0], 2),
            "p1": round(percentile(values, 0.01), 2),
            "frames_scored": len(values),
        },
        "worst": worst_windows(scores, fps),
    }


def rule_553(size_before: int, size_after: int, vmaf_mean: float) -> dict[str, Any]:
    """The #553 advice. People decide; this only says whether each part holds."""
    reduction = 1 - size_after / size_before if size_before else 0.0
    return {
        "reduction": round(reduction, 4),
        "smaller_enough": reduction >= RULE_MIN_REDUCTION,
        "vmaf_enough": vmaf_mean >= RULE_MIN_VMAF,
    }
