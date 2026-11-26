"""Shared test helpers: tiny generated clips and jobs laid out as WordPress writes them."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path
from typing import Any

from encode_review import media
from encode_review.spool import Spool, now, write_json

HAVE_FFMPEG = shutil.which(media.FFMPEG) is not None and shutil.which(media.FFPROBE) is not None


def have_vmaf() -> bool:
    return HAVE_FFMPEG and media.vmaf_version() is not None


def make_clip(path: Path, seconds: float = 3, size: str = "320x180", rate: int = 24,
              faststart: bool = False) -> Path:
    """A testsrc clip with a sine tone, encoded small and fast."""
    cmd = [
        media.FFMPEG, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", f"testsrc=size={size}:rate={rate}:duration={seconds}",
        "-f", "lavfi", "-i", f"sine=frequency=440:duration={seconds}",
        "-c:v", "libx264", "-preset", "ultrafast", "-crf", "18", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-shortest",
    ]
    if faststart:
        cmd += ["-movflags", "+faststart"]
    subprocess.run([*cmd, str(path)], check=True)
    return path


def make_prores_clip(path: Path, seconds: float = 3, size: str = "320x180",
                     rate: int = 24) -> Path:
    """A ProRes 422 10-bit clip with PCM sound in a .mov: a browser plays neither."""
    subprocess.run([
        media.FFMPEG, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", f"testsrc=size={size}:rate={rate}:duration={seconds}",
        "-f", "lavfi", "-i", f"sine=frequency=440:duration={seconds}",
        "-c:v", "prores_ks", "-profile:v", "2", "-pix_fmt", "yuv422p10le",
        "-c:a", "pcm_s24le", "-shortest", str(path),
    ], check=True)
    return path


def add_job(spool: Spool, job_id: str, original: Path | None = None, state: str = "queue",
            queued_at: int | None = None, **extra: Any) -> Path:
    """A job folder as the admin page creates it: original, job.json, one waiting attempt."""
    job_dir = spool.path(state) / job_id
    job_dir.mkdir(parents=True)
    name = original.name if original else "original.mp4"
    if original:
        shutil.copy(original, job_dir / ("original" + original.suffix))
    else:
        (job_dir / "original.mp4").write_bytes(b"not a video")
    stamp = now() if queued_at is None else queued_at
    job = {
        "id": job_id,
        "site": "ampas",
        "uploader": {"id": 1, "login": "tester"},
        "original": {"name": name, "file": "original" + (original.suffix if original else ".mp4")},
        "stage": "waiting",
        "attempts": [{"n": 1, "status": "waiting", "crf": None, "maxrate_k": None,
                      "requested_at": stamp}],
        "created_at": stamp,
        "queued_at": stamp,
        "updated_at": stamp,
        **extra,
    }
    write_json(job_dir / "job.json", job)
    return job_dir
