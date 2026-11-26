"""The spool: one folder per job, moved between state folders.

Layout under the spool root (``/srv/encode-review`` on staging)::

    incoming/  uploads still arriving in parts (upload.json, original.<ext>.part)
    queue/     jobs waiting for their next attempt
    work/      the one job the worker is running
    done/      jobs whose latest attempt finished
    failed/    jobs whose latest attempt failed
    sends/     one record per attachment sent to production Media (send.py);
               cleanup removes a record's file copy, never the record
    status.json   the worker's heartbeat, read by the admin page
    run.lock      held by the worker for as long as it runs
    state.lock    held briefly by anyone who moves a job or rewrites job.json

WordPress (PHP-FPM) and the worker share the spool through a group. Every move
and every job.json write happens under ``state.lock``, so the two sides never
see half a change.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import shutil
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

STATES = ("incoming", "queue", "work", "done", "failed")
DIRS = (*STATES, "sends")
RETENTION_SECONDS = 7 * 24 * 3600
DISK_FLOOR_BYTES = 10 * 1024**3
JOB_FILE = "job.json"


def now() -> int:
    """Seconds since the epoch, as stored in job.json."""
    return int(time.time())


def write_json(path: Path, data: dict[str, Any]) -> None:
    """Writes JSON through a temp file and a rename, so readers see whole files."""
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(tmp, 0o664)
    os.replace(tmp, path)


def read_json(path: Path) -> dict[str, Any]:
    """Reads a JSON object; raises ValueError when the file holds anything else."""
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path} does not hold a JSON object")
    return data


class Spool:
    """The spool folders and the moves between them."""

    def __init__(self, root: Path | str) -> None:
        self.root = Path(root)

    def path(self, name: str) -> Path:
        return self.root / name

    def ensure(self) -> None:
        """Creates any missing spool folder. The installer sets owners and modes."""
        for name in DIRS:
            self.path(name).mkdir(parents=True, exist_ok=True)

    @contextlib.contextmanager
    def state_lock(self) -> Iterator[None]:
        """The short lock both sides take around a move or a job.json write."""
        with self._lock("state.lock", blocking=True):
            yield

    @contextlib.contextmanager
    def run_lock(self) -> Iterator[bool]:
        """The worker's lock. Yields False when another worker already holds it."""
        with self._lock("run.lock", blocking=False) as held:
            yield held

    @contextlib.contextmanager
    def _lock(self, name: str, blocking: bool) -> Iterator[bool]:
        path = self.path(name)
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o664)
        try:
            flags = fcntl.LOCK_EX if blocking else fcntl.LOCK_EX | fcntl.LOCK_NB
            try:
                fcntl.flock(fd, flags)
            except BlockingIOError:
                yield False
                return
            yield True
        finally:
            os.close(fd)

    # ---- jobs --------------------------------------------------------------

    def job_dirs(self, state: str) -> list[Path]:
        """The job folders in one state folder, oldest name first."""
        folder = self.path(state)
        if not folder.is_dir():
            return []
        return sorted(p for p in folder.iterdir() if p.is_dir() and not p.name.startswith("."))

    def find(self, job_id: str) -> tuple[str, Path] | None:
        """The state and folder of a job, or None."""
        for state in STATES:
            candidate = self.path(state) / job_id
            if candidate.is_dir():
                return state, candidate
        return None

    def load(self, job_dir: Path) -> dict[str, Any]:
        return read_json(job_dir / JOB_FILE)

    def save(self, job_dir: Path, job: dict[str, Any]) -> None:
        """Rewrites job.json and stamps the last activity. Call under state_lock."""
        job["updated_at"] = now()
        write_json(job_dir / JOB_FILE, job)

    def move(self, job_dir: Path, state: str) -> Path:
        """Moves a job folder into another state folder. Call under state_lock."""
        target = self.path(state) / job_dir.name
        os.replace(job_dir, target)
        return target

    def next_queued(self) -> Path | None:
        """The queued job that has waited longest, by queued_at then name."""
        best: tuple[int, str, Path] | None = None
        for job_dir in self.job_dirs("queue"):
            try:
                queued_at = int(self.load(job_dir).get("queued_at", 0))
            except (OSError, ValueError):
                continue
            key = (queued_at, job_dir.name, job_dir)
            if best is None or key[:2] < best[:2]:
                best = key
        return best[2] if best else None

    def claim_next(self) -> Path | None:
        """Moves the next queued job into work/ and returns its new folder."""
        with self.state_lock():
            job_dir = self.next_queued()
            if job_dir is None:
                return None
            return self.move(job_dir, "work")

    def recover_interrupted(self) -> list[str]:
        """Fails any job left in work/ by a stopped worker. Returns their ids.

        A job is in work/ only while a worker runs it, and the run lock allows
        one worker, so anything found there at start-up was cut off.
        """
        recovered: list[str] = []
        with self.state_lock():
            for job_dir in self.job_dirs("work"):
                try:
                    job = self.load(job_dir)
                except (OSError, ValueError):
                    job = {"id": job_dir.name, "attempts": []}
                attempt = current_attempt(job)
                if attempt is not None and attempt.get("status") not in ("done", "failed"):
                    attempt["status"] = "failed"
                    attempt["error"] = "The worker stopped during this attempt. Redo to try again."
                    attempt["finished_at"] = now()
                job["stage"] = "failed"
                self.save(job_dir, job)
                self.move(job_dir, "failed")
                recovered.append(job_dir.name)
        return recovered

    # ---- disk and retention ------------------------------------------------

    def free_bytes(self) -> int:
        usage = shutil.disk_usage(self.root)
        return usage.free

    def last_activity(self, entry: Path) -> int:
        """The updated_at of a job, an upload or a send record, else the newest mtime inside."""
        for name in (JOB_FILE, "upload.json", "record.json"):
            try:
                data = read_json(entry / name) if entry.is_dir() else {}
                if "updated_at" in data:
                    return int(data["updated_at"])
            except (OSError, ValueError):
                pass
        newest = entry.stat().st_mtime
        if entry.is_dir():
            for child in entry.rglob("*"):
                with contextlib.suppress(OSError):
                    newest = max(newest, child.stat().st_mtime)
        return int(newest)

    def cleanup(self, at: int | None = None) -> list[str]:
        """Deletes jobs, and sends' file copies, idle for 7 days. Returns the removed paths.

        work/ is never touched: the worker cleans up between jobs, so a job
        there is running. Approved files already live in WordPress Media.
        """
        at = now() if at is None else at
        removed: list[str] = []
        removed.extend(self.cleanup_sends(at))
        for name in ("incoming", "queue", "done", "failed"):
            folder = self.path(name)
            if not folder.is_dir():
                continue
            for entry in sorted(folder.iterdir()):
                if entry.name.startswith(".") and entry.is_file():
                    continue
                if at - self.last_activity(entry) < RETENTION_SECONDS:
                    continue
                with self.state_lock():
                    if not entry.exists():
                        continue
                    if entry.is_dir():
                        shutil.rmtree(entry)
                    else:
                        entry.unlink()
                removed.append(f"{name}/{entry.name}")
        return removed


    def cleanup_sends(self, at: int) -> list[str]:
        """Drops the file copies of sends idle for 7 days. The records stay.

        A record is the one decision about its attachment (sent, failed or
        unknown), so it must outlive any retention. A send the worker is
        uploading is never touched; half-built folders (".new-*") go too.
        """
        removed: list[str] = []
        folder = self.path("sends")
        if not folder.is_dir():
            return removed
        for entry in sorted(folder.iterdir()):
            if not entry.is_dir():
                continue
            if at - self.last_activity(entry) < RETENTION_SECONDS:
                continue
            with self.state_lock():
                if entry.name.startswith("."):
                    if entry.exists():
                        shutil.rmtree(entry)
                        removed.append(f"sends/{entry.name}")
                    continue
                payload = entry / "file.mp4"
                try:
                    state = read_json(entry / "record.json").get("state")
                except (OSError, ValueError):
                    state = None
                if payload.exists() and state != "sending":
                    payload.unlink()
                    removed.append(f"sends/{entry.name}/file.mp4")
        return removed


def current_attempt(job: dict[str, Any]) -> dict[str, Any] | None:
    """The newest attempt of a job, or None."""
    attempts = job.get("attempts") or []
    return attempts[-1] if attempts else None
