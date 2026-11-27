"""The queue worker: one encode at a time, plus a light helper thread.

The main loop takes the oldest queued job, encodes it with the #553 preset,
scores it with VMAF, makes stills of the worst moments and moves it to done/
or failed/. Between jobs it writes the heartbeat and runs the 7-day cleanup.

The helper thread never encodes. It probes newly queued uploads, so the queue
view can show a time estimate, and it runs sends to production and their
lookups, so a send does not wait behind a long encode. It also hashes
finished jobs that have no SHA-256 yet, so approval can record it.

The heartbeat thread rewrites status.json every HEARTBEAT_S seconds for as
long as the process lives, so the admin page sees a live encoder during a
long encode and a stale heartbeat within HEARTBEAT_STALE (plugin) of a stop.
"""

from __future__ import annotations

import argparse
import hashlib
import logging
import os
import shutil
import sys
import threading
import time
from pathlib import Path
from typing import Any

from . import media, results, send
from .spool import DISK_FLOOR_BYTES, Spool, current_attempt, now, read_json, write_json

LOG = logging.getLogger("encode-review")
POLL_S = 5
CLEANUP_EVERY_S = 3600
PROGRESS_EVERY_S = 5
HEARTBEAT_S = 20
HASH_CHUNK = 1024 * 1024
# Seconds of work per second of video until the first job measures it
# (plan: about 10-20 minutes for a 2-3 minute trailer).
DEFAULT_SPEED = 6.0


def sha256_file(path: Path) -> str:
    """The SHA-256 of a file, read in 1 MiB parts."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(HASH_CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def gigabytes(size: int) -> str:
    """A size for people: GB with one decimal, or whole MB under 1 GB."""
    if size < 1024**3:
        return f"{round(size / 1024**2)} MB"
    return f"{size / 1024**3:.1f} GB"


class Worker:
    def __init__(self, spool: Spool) -> None:
        self.spool = spool
        self.current: str | None = None
        self.speed: float | None = None
        self.last_cleanup = 0.0
        self.environment: dict[str, Any] = {}
        self.stop = threading.Event()
        self.unhashable: set[str] = set()

    # ---- heartbeat ---------------------------------------------------------

    def load_speed(self) -> None:
        try:
            status = read_json(self.spool.path("status.json"))
            value = status.get("speed")
            self.speed = float(value) if value else None
        except (OSError, ValueError):
            self.speed = None

    def write_status(self) -> None:
        status = {
            "updated_at": now(),
            "pid": os.getpid(),
            "current": self.current,
            "free_bytes": self.spool.free_bytes(),
            "floor_bytes": DISK_FLOOR_BYTES,
            "speed": round(self.speed, 3) if self.speed else None,
            "default_speed": DEFAULT_SPEED,
            "send_configured": send.configured_sites(),
            **self.environment,
        }
        with self.spool.state_lock():
            write_json(self.spool.path("status.json"), status)

    # ---- job steps ---------------------------------------------------------

    def update(self, job_dir: Path, job: dict[str, Any], **attempt_fields: Any) -> None:
        attempt = current_attempt(job)
        if attempt is not None:
            attempt.update(attempt_fields)
        with self.spool.state_lock():
            self.spool.save(job_dir, job)

    def ensure_probe(self, job_dir: Path, job: dict[str, Any]) -> dict[str, Any]:
        if not job.get("probe"):
            job["probe"] = media.probe(job_dir / job["original"]["file"])
        return job["probe"]

    def ensure_sha256(self, job_dir: Path, job: dict[str, Any]) -> None:
        """Records the original's SHA-256 in job.json, once per job, while the original is
        on disk: approval copies it into the file's record and then deletes the original."""
        if job["original"].get("sha256"):
            return
        job["original"]["sha256"] = sha256_file(job_dir / job["original"]["file"])
        self.update(job_dir, job)

    def run_job(self, job_dir: Path) -> Path:
        """Runs the newest attempt of a claimed job. Returns the job's final folder."""
        job = self.spool.load(job_dir)
        attempt = current_attempt(job)
        if attempt is None:
            return self.fail(job_dir, job, "The job has no attempt to run.")
        self.current = job_dir.name
        self.write_status()
        number = int(attempt["n"])
        out_dir = job_dir / "attempts" / str(number)
        if out_dir.exists():
            shutil.rmtree(out_dir)
        (out_dir / "stills").mkdir(parents=True)
        log = out_dir / "ffmpeg.log"
        started = time.monotonic()
        try:
            source = self.ensure_probe(job_dir, job)
            original = job_dir / job["original"]["file"]
            self.ensure_sha256(job_dir, job)
            reference_s = self.ensure_reference(job_dir, job, original, source, log)
            preset = media.make_preset(source["height"], attempt.get("crf"), attempt.get("maxrate_k"),
                                       job.get("video_caps"))
            attempt.update(crf=preset.crf, maxrate_k=preset.maxrate_k, bufsize_k=preset.bufsize_k,
                           level=preset.level)
            job["stage"] = "encoding"
            self.update(job_dir, job, status="encoding", started_at=now(), progress=0.0,
                        error=None)

            encode_path = out_dir / "encode.mp4"
            encoded = media.run_ffmpeg(media.encode_cmd(original, encode_path, preset), log,
                                       source["duration"], self.progress_writer(job_dir, job))
            after = media.probe(encode_path)

            job["stage"] = "scoring"
            self.update(job_dir, job, status="scoring", progress=0.0)
            vmaf_log = out_dir / "vmaf.json"
            scored = media.score(encode_path, original, (source["width"], source["height"]),
                                 vmaf_log, log, source["duration"],
                                 self.progress_writer(job_dir, job))
            summary = results.summarize(vmaf_log, after["fps"] or source["fps"] or 24.0)
            stills = self.make_stills(original, encode_path, out_dir, summary["worst"])
            vmaf_log.unlink()

            attempt_results = {
                "size_before": source["size"],
                "size_after": after["size"],
                "bit_rate_before": source["bit_rate"],
                "bit_rate_after": after["bit_rate"],
                "duration_before": source["duration"],
                "duration_after": after["duration"],
                "duration_match": media.durations_match(source["duration"], after["duration"]),
                "faststart": media.is_faststart(encode_path),
                **summary,
                "stills": stills,
                "rule_553": results.rule_553(source["size"], after["size"],
                                             summary["vmaf"]["mean"]),
                "timings": {"encode_s": round(encoded.seconds, 1),
                            "score_s": round(scored.seconds, 1),
                            "total_s": round(time.monotonic() - started, 1)},
                "peak_rss_mb": {"encode": encoded.peak_rss_mb, "score": scored.peak_rss_mb},
            }
        except (media.MediaError, ValueError, OSError, KeyError) as error:
            LOG.warning("job %s attempt %s failed: %s", job_dir.name, number, error)
            return self.fail(job_dir, job, str(error))

        # The estimate is for an attempt; a reference copy is made once per job.
        self.learn_speed(time.monotonic() - started - reference_s, source["duration"])
        job["stage"] = "ready"
        self.update(job_dir, job, status="done", progress=1.0, finished_at=now(),
                    results=attempt_results)
        with self.spool.state_lock():
            final = self.spool.move(job_dir, "done")
        LOG.info("job %s attempt %s done: VMAF %.2f, %d -> %d bytes, %.0fs", job_dir.name, number,
                 attempt_results["vmaf"]["mean"], source["size"], after["size"],
                 attempt_results["timings"]["total_s"])
        return final

    def ensure_reference(self, job_dir: Path, job: dict[str, Any], original: Path,
                         source: dict[str, Any], log: Path) -> float:
        """Makes the job's reference copy when no browser plays the original (ruling 17).

        Once per job; a redo reuses it. It counts toward the disk floor: it is made
        only when its largest possible size still leaves the floor free. Without it
        there is no moving comparison, so a refused or failed copy fails the attempt
        before the encode (ruling 19 item 2): the job stops in failed/ with the
        original kept, the page offers no approval, and a redo tries the copy again.
        Returns its seconds.
        """
        playable = media.browser_plays(source)
        job["original_playable"] = playable
        target = job_dir / media.REFERENCE_FILE
        if playable or target.is_file():
            return 0.0
        need = media.reference_bytes(source)
        free = self.spool.free_bytes()
        if free - need < DISK_FLOOR_BYTES:
            job["reference_error"] = (
                f"No reference copy for side-by-side review: it can take up to {gigabytes(need)} "
                f"and the server has {gigabytes(free)} free, under the 10 GB floor once it is "
                "made. The original is kept. Remove old jobs, then redo to make it.")
            raise media.MediaError(job["reference_error"])
        job["stage"] = "reference"
        self.update(job_dir, job, status="reference", started_at=now(), progress=0.0, error=None)
        partial = job_dir / f".{media.REFERENCE_FILE}.part.mp4"
        try:
            made = media.run_ffmpeg(media.reference_cmd(original, partial, source), log,
                                    source["duration"], self.progress_writer(job_dir, job))
            os.replace(partial, target)
        except (media.MediaError, OSError) as error:
            partial.unlink(missing_ok=True)
            LOG.warning("job %s: reference copy failed: %s", job_dir.name, error)
            job["reference_error"] = (
                f"The reference copy for side-by-side review failed: {error}. The original is "
                "kept. Redo to try again, or upload the original again.")
            raise media.MediaError(job["reference_error"]) from error
        job.pop("reference_error", None)
        job["reference"] = {
            "file": media.REFERENCE_FILE,
            "size": target.stat().st_size,
            "crf": media.REFERENCE_CRF,
            "seconds": round(made.seconds, 1),
            "peak_rss_mb": made.peak_rss_mb,
        }
        self.update(job_dir, job)
        LOG.info("job %s: reference copy %d bytes in %.0fs", job_dir.name,
                 job["reference"]["size"], made.seconds)
        return made.seconds

    def progress_writer(self, job_dir: Path, job: dict[str, Any]):
        last = [0.0]

        def write(fraction: float) -> None:
            if time.monotonic() - last[0] >= PROGRESS_EVERY_S:
                last[0] = time.monotonic()
                self.update(job_dir, job, progress=round(fraction, 3))

        return write

    def make_stills(self, original: Path, encode: Path, out_dir: Path,
                    worst: list[dict[str, Any]]) -> list[dict[str, Any]]:
        stills: list[dict[str, Any]] = []
        for index, window in enumerate(worst[: results.STILLS], start=1):
            pair = {"time": window["worst_time"], "vmaf": window["worst_vmaf"]}
            for side, src in (("original", original), ("encode", encode)):
                name = f"stills/{index}-{side}.jpg"
                media.make_still(src, window["worst_time"], out_dir / name)
                pair[side] = name
            stills.append(pair)
        return stills

    def fail(self, job_dir: Path, job: dict[str, Any], message: str) -> Path:
        job["stage"] = "failed"
        self.update(job_dir, job, status="failed", error=message, finished_at=now())
        with self.spool.state_lock():
            return self.spool.move(job_dir, "failed")

    def learn_speed(self, seconds: float, duration: float) -> None:
        if duration <= 0:
            return
        sample = seconds / duration
        self.speed = sample if self.speed is None else round(0.7 * self.speed + 0.3 * sample, 3)

    # ---- helper thread -----------------------------------------------------

    def probe_queued(self) -> None:
        """Probes queued jobs that have none yet, for the queue view's estimate."""
        for job_dir in self.spool.job_dirs("queue"):
            try:
                job = self.spool.load(job_dir)
                if job.get("probe") or job.get("probe_error"):
                    continue
                try:
                    facts: dict[str, Any] = {"probe": media.probe(job_dir / job["original"]["file"])}
                except media.MediaError as error:
                    facts = {"probe_error": str(error)}
                with self.spool.state_lock():
                    if not (job_dir / "job.json").exists():
                        continue  # claimed or removed meanwhile
                    fresh = self.spool.load(job_dir)
                    fresh.update(facts)
                    write_json(job_dir / "job.json", fresh)
            except (OSError, ValueError, KeyError) as error:
                LOG.warning("probe of %s skipped: %s", job_dir.name, error)

    def hash_finished(self) -> bool:
        """Hashes one finished job that has no SHA-256 yet. Returns True when it hashed one.

        A job whose encode ran before the worker hashed originals sits in done/
        without one, and approval waits for it (the page says so), because approval
        deletes the original. Only the hash is added: the job keeps its attempts,
        its place and its 7-day clock (updated_at). A job a redo moves meanwhile is
        hashed by its next attempt instead.
        """
        for job_dir in self.spool.job_dirs("done"):
            if job_dir.name in self.unhashable:
                continue
            try:
                job = self.spool.load(job_dir)
                if job["original"].get("sha256"):
                    continue
                digest = sha256_file(job_dir / job["original"]["file"])
                with self.spool.state_lock():
                    if not (job_dir / "job.json").exists():
                        continue  # moved by a redo, or removed, meanwhile
                    fresh = self.spool.load(job_dir)
                    if fresh["original"].get("file") != job["original"]["file"]:
                        continue
                    fresh["original"]["sha256"] = digest
                    write_json(job_dir / "job.json", fresh)
            except (OSError, ValueError, KeyError) as error:
                self.unhashable.add(job_dir.name)
                LOG.warning("hash of %s skipped: %s", job_dir.name, error)
                continue
            LOG.info("job %s: original hashed for approval", job_dir.name)
            return True
        return False

    def run_sends(self) -> None:
        """Uploads queued sends, then settles unknown ones whose lookup is due."""
        for folder in send.pending_sends(self.spool):
            record = send.process_send(self.spool, folder)
            LOG.info("send %s: %s %s", folder.name, record.get("state"),
                     record.get("production_id") or send.current_try(record).get("error") or "")
        for folder in send.due_checks(self.spool):
            record = send.check_send(self.spool, folder)
            LOG.info("send %s lookup: %s %s", folder.name, record.get("state"),
                     record.get("production_id") or record.get("check_error") or "")

    def helper_loop(self) -> None:
        while not self.stop.is_set():
            try:
                self.probe_queued()
                self.run_sends()
                self.hash_finished()
            except Exception:  # noqa: BLE001 - the helper must outlive any one bad file
                LOG.exception("helper pass failed")
            self.stop.wait(POLL_S)

    def heartbeat_loop(self) -> None:
        while not self.stop.wait(HEARTBEAT_S):
            try:
                self.write_status()
            except Exception:  # noqa: BLE001 - a full disk must not end the heartbeat
                LOG.exception("heartbeat failed")

    # ---- main loop ---------------------------------------------------------

    def housekeeping(self, force: bool = False) -> None:
        if force or time.monotonic() - self.last_cleanup >= CLEANUP_EVERY_S:
            removed = self.spool.cleanup()
            if removed:
                LOG.info("cleanup removed %s", ", ".join(removed))
            self.last_cleanup = time.monotonic()
        self.write_status()

    def run_once(self) -> bool:
        """Runs the next queued job, if any. Returns True when it ran one."""
        job_dir = self.spool.claim_next()
        if job_dir is None:
            return False
        try:
            self.run_job(job_dir)
        finally:
            self.current = None
            self.write_status()
        return True

    def run_forever(self) -> None:
        for target, name in ((self.helper_loop, "helper"), (self.heartbeat_loop, "heartbeat")):
            threading.Thread(target=target, name=name, daemon=True).start()
        while not self.stop.is_set():
            self.housekeeping()
            if not self.run_once():
                self.stop.wait(POLL_S)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Encode review queue worker")
    parser.add_argument("--spool", default=os.environ.get("ENCODE_REVIEW_SPOOL",
                                                          "/srv/encode-review"))
    parser.add_argument("--once", action="store_true",
                        help="run the next queued job, then the helper pass, and exit")
    parser.add_argument("--cleanup", action="store_true", help="run the 7-day cleanup and exit")
    parser.add_argument("--resolve-send", metavar="SITE-ID",
                        help="settle an unknown send by hand: with --production-id when "
                             "production Media has it, with --absent when it does not")
    settle = parser.add_mutually_exclusive_group()
    settle.add_argument("--production-id", type=int)
    settle.add_argument("--absent", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, stream=sys.stdout,
                        format="%(levelname)s %(message)s")

    spool = Spool(args.spool)
    spool.ensure()
    if args.cleanup:
        for path in spool.cleanup():
            print(f"removed {path}")
        return 0
    if args.resolve_send:
        if not (args.production_id or args.absent):
            parser.error("--resolve-send needs --production-id or --absent")
        try:
            record = send.resolve(spool, args.resolve_send, args.production_id)
        except (OSError, ValueError) as error:
            LOG.error("%s", error)
            return 1
        print(f"{args.resolve_send}: {record['state']}")
        return 0

    with spool.run_lock() as held:
        if not held:
            LOG.error("another worker holds %s", spool.path("run.lock"))
            return 1
        worker = Worker(spool)
        worker.environment = {"ffmpeg": media.ffmpeg_version(), "vmaf": media.vmaf_version()}
        worker.load_speed()
        for job_id in spool.recover_interrupted():
            LOG.warning("job %s was cut off by a stop; marked failed", job_id)
        for key in send.recover_interrupted(spool):
            LOG.warning("send %s was cut off by a stop; outcome unknown until a lookup", key)
        worker.housekeeping(force=True)
        if args.once:
            worker.run_once()
            worker.probe_queued()
            worker.run_sends()
            while worker.hash_finished():
                pass
            return 0
        LOG.info("worker started on %s (ffmpeg %s, vmaf %s)", spool.root,
                 worker.environment["ffmpeg"], worker.environment["vmaf"])
        worker.run_forever()
    return 0
