"""Queue states, claim order, interrupted jobs, locks and the 7-day cleanup."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from encode_review.spool import RETENTION_SECONDS, Spool, now, read_json, write_json

from .helpers import add_job


class SpoolTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.spool = Spool(self.tmp.name)
        self.spool.ensure()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_ensure_creates_every_folder(self) -> None:
        for name in ("incoming", "queue", "work", "done", "failed", "sends"):
            self.assertTrue(self.spool.path(name).is_dir(), name)

    def test_claim_takes_the_longest_waiting_job(self) -> None:
        add_job(self.spool, "b-newer", queued_at=200)
        add_job(self.spool, "a-older", queued_at=100)
        add_job(self.spool, "c-oldest-name-later", queued_at=50)
        claimed = self.spool.claim_next()
        self.assertEqual(claimed, self.spool.path("work") / "c-oldest-name-later")
        self.assertEqual(self.spool.find("c-oldest-name-later")[0], "work")
        self.assertEqual(self.spool.claim_next().name, "a-older")

    def test_claim_returns_none_on_empty_queue(self) -> None:
        self.assertIsNone(self.spool.claim_next())

    def test_claim_skips_unreadable_job(self) -> None:
        broken = self.spool.path("queue") / "broken"
        broken.mkdir()
        (broken / "job.json").write_text("{not json")
        add_job(self.spool, "good", queued_at=10)
        self.assertEqual(self.spool.claim_next().name, "good")

    def test_save_stamps_last_activity(self) -> None:
        job_dir = add_job(self.spool, "j", queued_at=1)
        job = self.spool.load(job_dir)
        self.spool.save(job_dir, job)
        self.assertGreaterEqual(self.spool.load(job_dir)["updated_at"], now() - 2)

    def test_recover_fails_interrupted_work(self) -> None:
        job_dir = add_job(self.spool, "cut-off", state="work")
        job = self.spool.load(job_dir)
        job["attempts"][0]["status"] = "encoding"
        write_json(job_dir / "job.json", job)
        self.assertEqual(self.spool.recover_interrupted(), ["cut-off"])
        state, folder = self.spool.find("cut-off")
        self.assertEqual(state, "failed")
        recovered = read_json(folder / "job.json")
        self.assertEqual(recovered["stage"], "failed")
        self.assertEqual(recovered["attempts"][0]["status"], "failed")
        self.assertIn("Redo", recovered["attempts"][0]["error"])

    def test_run_lock_admits_one_worker(self) -> None:
        with self.spool.run_lock() as first:
            self.assertTrue(first)
            # flock locks belong to the open file, so a second open contends.
            with self.spool.run_lock() as second:
                self.assertFalse(second)
        with self.spool.run_lock() as again:
            self.assertTrue(again)

    def test_cleanup_removes_only_jobs_idle_for_seven_days(self) -> None:
        at = now()
        old = at - RETENTION_SECONDS - 60
        fresh = at - RETENTION_SECONDS + 3600
        add_job(self.spool, "old-done", state="done", updated_at=old)
        add_job(self.spool, "old-failed", state="failed", updated_at=old)
        add_job(self.spool, "old-queued", state="queue", updated_at=old)
        add_job(self.spool, "fresh-done", state="done", updated_at=fresh)
        add_job(self.spool, "old-but-running", state="work", updated_at=old)
        removed = self.spool.cleanup(at)
        self.assertEqual(sorted(removed), ["done/old-done", "failed/old-failed", "queue/old-queued"])
        self.assertIsNotNone(self.spool.find("fresh-done"))
        self.assertIsNotNone(self.spool.find("old-but-running"))

    def test_cleanup_uses_mtime_without_job_json(self) -> None:
        at = now()
        partial = self.spool.path("incoming") / "partial"
        partial.mkdir()
        part_file = partial / "upload.part"
        part_file.write_bytes(b"x")
        old = at - RETENTION_SECONDS - 60
        for path in (part_file, partial):
            os.utime(path, (old, old))
        send = self.spool.path("sends") / "ampas-7"
        send.mkdir()
        (send / "record.json").write_text('{"state": "queued"}')
        self.assertEqual(self.spool.cleanup(at), ["incoming/partial"])
        self.assertTrue(send.exists())

    def test_cleanup_reads_an_upload_in_parts_by_its_last_part(self) -> None:
        at = 1_800_000_000
        for name, last in (("active", at - 3600), ("abandoned", at - 8 * 24 * 3600)):
            folder = self.spool.path("incoming") / name
            folder.mkdir()
            (folder / "original.mov.part").write_bytes(b"x" * 10)
            write_json(folder / "upload.json", {"id": name, "updated_at": last})
            # The files themselves look old either way; upload.json decides.
            os.utime(folder / "original.mov.part", (at - 9 * 24 * 3600,) * 2)
        self.assertEqual(self.spool.cleanup(at), ["incoming/abandoned"])
        self.assertTrue((self.spool.path("incoming") / "active").is_dir())

    def test_free_bytes_reads_the_spool_filesystem(self) -> None:
        self.assertGreater(self.spool.free_bytes(), 0)


if __name__ == "__main__":
    unittest.main()
