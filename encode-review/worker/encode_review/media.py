"""ffprobe and ffmpeg: probing, the encode preset, VMAF scoring and stills."""

from __future__ import annotations

import json
import os
import struct
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
from typing import Any

FFMPEG = os.environ.get("ENCODE_REVIEW_FFMPEG", "ffmpeg")
FFPROBE = os.environ.get("ENCODE_REVIEW_FFPROBE", "ffprobe")
# Ubuntu 24.04's ffmpeg has no libvmaf filter, so scoring runs Netflix's vmaf
# tool, fed raw frames by ffmpeg (infra/encode-review.sh installs it).
VMAF = os.environ.get("ENCODE_REVIEW_VMAF", "vmaf")
VMAF_MODEL = "version=vmaf_v0.6.1"

# The quality range people may pick on the review page (plan: CRF 18-26).
CRF_MIN, CRF_MAX, CRF_DEFAULT = 18, 26, 21
# Bitrate caps people may pick, in kbit/s. The buffer is always 4x the cap:
# a 2x buffer starved a one-frame static burst in the #553 trial.
MAXRATE_MIN_K, MAXRATE_MAX_K = 1000, 12000
BUFFER_FACTOR = 4
# VMAF scores every Nth frame on one thread (plan: "1 thread with frame subsampling").
VMAF_SUBSAMPLE = 2
# Duration match tolerance: AAC priming and frame rounding stay well inside it.
DURATION_TOLERANCE_S = 0.2

# Ruling 17: when no browser plays the original (ProRes and the like), the
# side-by-side view uses a near-lossless H.264 copy at the original's size and
# frame rate. VMAF still scores against the original itself.
REFERENCE_FILE = "reference.mp4"
REFERENCE_CRF = 12
REFERENCE_PRESET = "veryfast"
# The copy's bitrate cap, in bits per pixel per frame: high enough that CRF 12
# rules almost everywhere (grain included), and a bound on its disk use.
REFERENCE_BITS_PER_PIXEL = 1.5
REFERENCE_AUDIO_K = 192
# What every current browser's <video> plays as it is: the codec, the
# containers it may come in (ffprobe format names), 8-bit 4:2:0 pixels and a
# playable sound. Some browsers play more (Chrome on macOS decodes ProRes);
# the copy is for the ones that do not.
BROWSER_VIDEO = {
    "h264": {"mov", "mp4"},
    "vp8": {"webm"},
    "vp9": {"webm", "mp4"},
    "av1": {"webm", "mp4"},
}
BROWSER_PIX_FMTS = {"yuv420p", "yuvj420p"}
BROWSER_AUDIO = {None, "aac", "mp3", "opus", "vorbis", "flac"}


class MediaError(RuntimeError):
    """ffmpeg or ffprobe failed, or the input is not a usable video."""


@dataclass(frozen=True)
class Preset:
    """The encode settings for one attempt."""

    crf: int
    maxrate_k: int
    level: str | None

    @property
    def bufsize_k(self) -> int:
        return self.maxrate_k * BUFFER_FACTOR


def default_maxrate_k(height: int) -> int:
    """The #553 cap: 3 Mbit/s up to 720p, 5 Mbit/s above."""
    return 3000 if height <= 720 else 5000


def level_for(height: int) -> str | None:
    """The #553 levels: 3.1 up to 720p, 4.1 up to 1080p. Above 1080p x264 picks."""
    if height <= 720:
        return "3.1"
    if height <= 1080:
        return "4.1"
    return None


def make_preset(height: int, crf: int | None = None, maxrate_k: int | None = None) -> Preset:
    """A preset for a source height, with requested values clamped to the allowed range."""
    crf = CRF_DEFAULT if crf is None else max(CRF_MIN, min(CRF_MAX, int(crf)))
    if maxrate_k is None:
        maxrate_k = default_maxrate_k(height)
    maxrate_k = max(MAXRATE_MIN_K, min(MAXRATE_MAX_K, int(maxrate_k)))
    return Preset(crf=crf, maxrate_k=maxrate_k, level=level_for(height))


# ---- probe -----------------------------------------------------------------


def run_json(cmd: Sequence[str]) -> dict[str, Any]:
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        tail = proc.stderr.strip().splitlines()[-3:]
        raise MediaError(" ".join(tail) or f"{cmd[0]} exited {proc.returncode}")
    return json.loads(proc.stdout or "{}")


def probe(path: Path) -> dict[str, Any]:
    """The facts the worker and the admin page need about a file."""
    try:
        data = run_json([
            FFPROBE, "-v", "error", "-print_format", "json",
            "-show_format", "-show_streams", str(path),
        ])
    except MediaError as error:
        # ffprobe ends with "<path>: <reason>"; keep the reason, not the spool path.
        reason = str(error).rsplit(": ", 1)[-1]
        raise MediaError(f"This file could not be read as a video ({reason}).") from error
    video = next((s for s in data.get("streams", []) if s.get("codec_type") == "video"
                  and not s.get("disposition", {}).get("attached_pic")), None)
    if video is None:
        raise MediaError("No video stream found. Is this a video file?")
    audio = next((s for s in data.get("streams", []) if s.get("codec_type") == "audio"), None)
    fmt = data.get("format", {})
    fps = parse_rate(video.get("avg_frame_rate")) or parse_rate(video.get("r_frame_rate"))
    duration = float(fmt.get("duration") or video.get("duration") or 0)
    if duration <= 0:
        raise MediaError("The file reports no duration.")
    return {
        "width": int(video.get("width") or 0),
        "height": int(video.get("height") or 0),
        "fps": round(float(fps), 3) if fps else None,
        "vcodec": video.get("codec_name"),
        "pix_fmt": video.get("pix_fmt"),
        "acodec": audio.get("codec_name") if audio else None,
        "duration": round(duration, 3),
        "format": fmt.get("format_name"),
        "size": int(fmt.get("size") or path.stat().st_size),
        "bit_rate": int(fmt.get("bit_rate") or 0),
        "video_bit_rate": int(video.get("bit_rate") or 0),
    }


def browser_plays(facts: dict[str, Any]) -> bool:
    """True when a browser's <video> plays the probed file as it is (ruling 17)."""
    containers = BROWSER_VIDEO.get(facts.get("vcodec") or "", set())
    formats = set((facts.get("format") or "").split(","))
    return (bool(containers & formats) and facts.get("pix_fmt") in BROWSER_PIX_FMTS
            and facts.get("acodec") in BROWSER_AUDIO)


def reference_maxrate_k(facts: dict[str, Any]) -> int:
    """The reference copy's bitrate cap for the original's size and frame rate."""
    pixels_per_s = int(facts["width"]) * int(facts["height"]) * float(facts.get("fps") or 30)
    return max(8000, int(pixels_per_s * REFERENCE_BITS_PER_PIXEL / 1000))


def reference_bytes(facts: dict[str, Any]) -> int:
    """The most the reference copy can take on disk: its cap over the whole duration."""
    kbps = reference_maxrate_k(facts) + REFERENCE_AUDIO_K
    return int(kbps * 1000 / 8 * float(facts["duration"]))


def parse_rate(value: str | None) -> Fraction | None:
    if not value or value in ("0/0", "0"):
        return None
    try:
        rate = Fraction(value)
    except (ValueError, ZeroDivisionError):
        return None
    return rate if rate > 0 else None


# ---- commands --------------------------------------------------------------


def encode_cmd(src: Path, dst: Path, preset: Preset) -> list[str]:
    """The #553 encode: first video and first audio stream, faststart, two x264 threads."""
    cmd = [
        FFMPEG, "-nostdin", "-hide_banner", "-y", "-threads", "2", "-i", str(src),
        "-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "-1",
        "-c:v", "libx264", "-preset", "slow", "-crf", str(preset.crf),
        "-maxrate", f"{preset.maxrate_k}k", "-bufsize", f"{preset.bufsize_k}k",
        "-profile:v", "high",
    ]
    if preset.level:
        cmd += ["-level:v", preset.level]
    cmd += [
        "-pix_fmt", "yuv420p", "-threads", "2",
        "-c:a", "aac", "-b:a", "128k", "-ac", "2",
        "-movflags", "+faststart",
        "-progress", "pipe:1", "-nostats",
        str(dst),
    ]
    return cmd


def reference_cmd(src: Path, dst: Path, facts: dict[str, Any]) -> list[str]:
    """The near-lossless copy for review: the original's size and frame rate, 8-bit 4:2:0
    H.264 so every browser plays it, first video and first audio stream, faststart."""
    rate = reference_maxrate_k(facts)
    return [
        FFMPEG, "-nostdin", "-hide_banner", "-y", "-threads", "2", "-i", str(src),
        "-map", "0:v:0", "-map", "0:a:0?", "-map_metadata", "-1",
        "-c:v", "libx264", "-preset", REFERENCE_PRESET, "-crf", str(REFERENCE_CRF),
        "-maxrate", f"{rate}k", "-bufsize", f"{2 * rate}k",
        "-profile:v", "high", "-pix_fmt", "yuv420p", "-threads", "2",
        "-c:a", "aac", "-b:a", f"{REFERENCE_AUDIO_K}k", "-ac", "2",
        "-movflags", "+faststart",
        "-progress", "pipe:1", "-nostats",
        str(dst),
    ]


def y4m_cmd(src: Path, fifo: Path, scale: tuple[int, int] | None = None,
            progress: bool = False) -> list[str]:
    """Decodes the first video stream to 8-bit 4:2:0 y4m, every frame once, on one thread."""
    filters = "format=yuv420p"
    if scale:
        filters = f"scale={scale[0]}:{scale[1]}:flags=bicubic," + filters
    cmd = [FFMPEG, "-nostdin", "-hide_banner", "-loglevel", "error", "-threads", "1",
           "-i", str(src), "-map", "0:v:0", "-vf", filters, "-fps_mode", "passthrough",
           "-threads", "1"]
    if progress:
        cmd += ["-progress", "pipe:1", "-nostats"]
    return [*cmd, "-f", "yuv4mpegpipe", "-y", str(fifo)]


def vmaf_tool_cmd(reference: Path, distorted: Path, log_path: Path) -> list[str]:
    """The vmaf tool on one thread, scoring every VMAF_SUBSAMPLE-th frame."""
    return [VMAF, "--reference", str(reference), "--distorted", str(distorted),
            "--model", VMAF_MODEL, "--threads", "1", "--subsample", str(VMAF_SUBSAMPLE),
            "--json", "--output", str(log_path), "--quiet"]


def still_cmd(src: Path, seconds: float, dst: Path) -> list[str]:
    return [
        FFMPEG, "-nostdin", "-hide_banner", "-y", "-ss", f"{seconds:.3f}", "-i", str(src),
        "-frames:v", "1", "-vf", "scale='min(960,iw)':-2", "-q:v", "3", str(dst),
    ]


def vmaf_version() -> str | None:
    """The vmaf tool's version, or None when it is missing."""
    try:
        proc = subprocess.run([VMAF, "--version"], capture_output=True, text=True, check=False)
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or proc.stderr.strip() or "unknown"


def ffmpeg_version() -> str:
    proc = subprocess.run([FFMPEG, "-hide_banner", "-version"], capture_output=True, text=True,
                          check=False)
    first = proc.stdout.splitlines()[0] if proc.stdout else ""
    return first.removeprefix("ffmpeg version ").split(" Copyright")[0].strip()


# ---- running ---------------------------------------------------------------


@dataclass
class RunResult:
    seconds: float
    peak_rss_mb: float


def run_ffmpeg(cmd: Sequence[str], log: Path, duration: float,
               on_progress: Callable[[float], None] | None = None) -> RunResult:
    """Runs ffmpeg with -progress on stdout, reporting the fraction done.

    Returns the wall time and the child's peak resident memory. Raises
    MediaError with the end of the log when ffmpeg fails.
    """
    started = time.monotonic()
    with log.open("ab") as log_handle:
        log_handle.write(("$ " + " ".join(cmd) + "\n").encode())
        log_handle.flush()
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=log_handle, text=True)
        assert proc.stdout is not None
        for line in proc.stdout:
            key, _, value = line.strip().partition("=")
            if key == "out_time_us" and on_progress and duration > 0 and value.isdigit():
                on_progress(min(1.0, int(value) / 1e6 / duration))
        proc.stdout.close()
        _, status, usage = os.wait4(proc.pid, 0)
        proc.returncode = os.waitstatus_to_exitcode(status)
    rss = usage.ru_maxrss / (1024 * 1024 if sys.platform == "darwin" else 1024)
    if proc.returncode != 0:
        raise MediaError(f"ffmpeg exited {proc.returncode}: {log_tail(log)}")
    return RunResult(seconds=time.monotonic() - started, peak_rss_mb=round(rss, 1))


def log_tail(log: Path, lines: int = 3) -> str:
    try:
        text = log.read_text(errors="replace").strip().splitlines()
    except OSError:
        return ""
    return " / ".join(text[-lines:])


def score(encode: Path, original: Path, size: tuple[int, int], log_path: Path, run_log: Path,
          duration: float, on_progress: Callable[[float], None] | None = None) -> RunResult:
    """Scores the encode against the original at the original's size with the vmaf tool.

    Two ffmpeg decoders write y4m into named pipes that the vmaf tool reads.
    Success is the vmaf tool's: a decoder that stops on a closed pipe after the
    shorter stream ends is not a failure.
    """
    started = time.monotonic()
    with tempfile.TemporaryDirectory(dir=log_path.parent) as tmp:
        ref, dist = Path(tmp) / "ref.y4m", Path(tmp) / "dist.y4m"
        os.mkfifo(ref)
        os.mkfifo(dist)
        with run_log.open("ab") as log_handle:
            cmds = [vmaf_tool_cmd(ref, dist, log_path),
                    y4m_cmd(original, ref, scale=size, progress=True),
                    y4m_cmd(encode, dist)]
            for cmd in cmds:
                log_handle.write(("$ " + " ".join(cmd) + "\n").encode())
            log_handle.flush()
            vmaf = subprocess.Popen(cmds[0], stdout=log_handle, stderr=log_handle)
            ref_dec = subprocess.Popen(cmds[1], stdout=subprocess.PIPE, stderr=log_handle,
                                       text=True)
            dist_dec = subprocess.Popen(cmds[2], stdout=subprocess.DEVNULL, stderr=log_handle)
            assert ref_dec.stdout is not None
            for line in ref_dec.stdout:
                key, _, value = line.strip().partition("=")
                if key == "out_time_us" and on_progress and duration > 0 and value.isdigit():
                    on_progress(min(1.0, int(value) / 1e6 / duration))
            ref_dec.stdout.close()
            peaks = []
            codes = []
            for proc in (vmaf, ref_dec, dist_dec):
                _, status, usage = os.wait4(proc.pid, 0)
                proc.returncode = os.waitstatus_to_exitcode(status)
                codes.append(proc.returncode)
                peaks.append(usage.ru_maxrss / (1024 * 1024 if sys.platform == "darwin" else 1024))
    if codes[0] != 0 or not log_path.is_file():
        raise MediaError(f"vmaf exited {codes[0]} (decoders {codes[1]}, {codes[2]}): "
                         f"{log_tail(run_log)}")
    # The three run at once, so their peaks add up.
    return RunResult(seconds=time.monotonic() - started, peak_rss_mb=round(sum(peaks), 1))


def make_still(src: Path, seconds: float, dst: Path) -> None:
    proc = subprocess.run(still_cmd(src, seconds, dst), capture_output=True, check=False)
    if proc.returncode != 0 or not dst.exists():
        raise MediaError(f"still at {seconds:.2f}s failed for {src.name}")


# ---- container checks ------------------------------------------------------


def top_level_boxes(path: Path) -> list[str]:
    """The MP4 top-level box types in file order."""
    boxes: list[str] = []
    size_total = path.stat().st_size
    with path.open("rb") as handle:
        offset = 0
        while offset + 8 <= size_total:
            handle.seek(offset)
            header = handle.read(8)
            if len(header) < 8:
                break
            size, kind = struct.unpack(">I4s", header)
            if size == 1:
                size = struct.unpack(">Q", handle.read(8))[0]
            elif size == 0:
                size = size_total - offset
            boxes.append(kind.decode("latin-1"))
            if size < 8:
                break
            offset += size
    return boxes


def is_faststart(path: Path) -> bool:
    """True when the moov box comes before the first mdat box."""
    boxes = top_level_boxes(path)
    if "moov" not in boxes or "mdat" not in boxes:
        return False
    return boxes.index("moov") < boxes.index("mdat")


def durations_match(before: float, after: float) -> bool:
    return abs(before - after) <= DURATION_TOLERANCE_S
