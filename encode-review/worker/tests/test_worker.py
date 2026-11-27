"""End to end on a tiny clip: encode, score, stills, redo and failure."""

from __future__ import annotations

import hashlib
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from encode_review import media
from encode_review.spool import Spool, read_json, write_json
from encode_review.worker import Worker, main

from .helpers import HAVE_FFMPEG, add_job, have_vmaf, make_clip, make_prores_clip


class WorkerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.spool = Spool(Path(self.tmp.name) / "spool")
        self.spool.ensure()
        self.worker = Worker(self.spool)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_idle_run_once_does_nothing(self) -> None:
        self.assertFalse(self.worker.run_once())

    def test_status_heartbeat(self) -> None:
        self.worker.write_status()
        status = read_json(self.spool.path("status.json"))
        self.assertEqual(status["floor_bytes"], 10 * 1024**3)
        self.assertIn("free_bytes", status)
        self.assertEqual(status["send_configured"], {"ampas": False, "guilds": False})

    def test_heartbeat_stays_fresh_during_a_long_job_and_stops_with_the_worker(self) -> None:
        status_file = self.spool.path("status.json")
        with mock.patch("encode_review.worker.HEARTBEAT_S", 0.1):
            beat = threading.Thread(target=self.worker.heartbeat_loop, daemon=True)
            self.worker.current = "a-long-job"
            beat.start()
            seen = set()
            deadline = time.monotonic() + 5
            while len(seen) < 3 and time.monotonic() < deadline:
                if status_file.exists():
                    seen.add(status_file.stat().st_mtime_ns)
                time.sleep(0.05)
            # The main thread did nothing; the heartbeat kept rewriting the status.
            self.assertGreaterEqual(len(seen), 3)
            self.assertEqual(read_json(status_file)["current"], "a-long-job")
            self.worker.stop.set()
            beat.join(2)
            self.assertFalse(beat.is_alive())
            last = status_file.stat().st_mtime_ns
            time.sleep(0.3)
            self.assertEqual(status_file.stat().st_mtime_ns, last)

    @unittest.skipUnless(HAVE_FFMPEG, "ffmpeg is not installed")
    def test_non_video_fails_with_a_reason(self) -> None:
        add_job(self.spool, "junk")
        self.assertTrue(self.worker.run_once())
        state, folder = self.spool.find("junk")
        self.assertEqual(state, "failed")
        job = read_json(folder / "job.json")
        self.assertEqual(job["stage"], "failed")
        self.assertIn("video", job["attempts"][0]["error"].lower())

    @unittest.skipUnless(HAVE_FFMPEG, "ffmpeg is not installed")
    def test_probe_queued_fills_the_estimate_facts(self) -> None:
        clip = make_clip(Path(self.tmp.name) / "clip.mp4", seconds=1)
        add_job(self.spool, "waiting", original=clip)
        add_job(self.spool, "junk")
        self.worker.probe_queued()
        self.assertEqual(read_json(self.spool.path("queue") / "waiting" / "job.json")["probe"]["width"], 320)
        self.assertIn("probe_error", read_json(self.spool.path("queue") / "junk" / "job.json"))

    @unittest.skipUnless(have_vmaf(), "ffmpeg with libvmaf is not installed")
    def test_encode_score_and_redo(self) -> None:
        clip = make_clip(Path(self.tmp.name) / "Trailer Final.mp4", seconds=4)
        add_job(self.spool, "job1", original=clip)
        self.assertTrue(self.worker.run_once())

        state, folder = self.spool.find("job1")
        self.assertEqual(state, "done")
        job = read_json(folder / "job.json")
        self.assertEqual(job["stage"], "ready")
        attempt = job["attempts"][0]
        self.assertEqual(attempt["status"], "done")
        self.assertEqual((attempt["crf"], attempt["maxrate_k"], attempt["bufsize_k"]), (21, 3000, 12000))
        res = attempt["results"]
        self.assertTrue(res["faststart"])
        self.assertTrue(res["duration_match"])
        self.assertGreater(res["vmaf"]["mean"], 50)
        self.assertLessEqual(res["vmaf"]["min"], res["vmaf"]["p1"])
        self.assertGreaterEqual(len(res["worst"]), 1)
        self.assertGreaterEqual(len(res["stills"]), 1)
        for pair in res["stills"]:
            self.assertTrue((folder / "attempts" / "1" / pair["original"]).is_file())
            self.assertTrue((folder / "attempts" / "1" / pair["encode"]).is_file())
        self.assertTrue((folder / "attempts" / "1" / "encode.mp4").is_file())
        self.assertFalse((folder / "attempts" / "1" / "vmaf.json").exists())
        self.assertIn("rule_553", res)
        self.assertIsNotNone(self.worker.speed)

        # Redo as the admin page does: a new attempt, back into the queue.
        job["attempts"].append({"n": 2, "status": "waiting", "crf": 26, "maxrate_k": 1500})
        job["stage"] = "waiting"
        write_json(folder / "job.json", job)
        self.spool.move(folder, "queue")
        self.assertTrue(self.worker.run_once())
        state, folder = self.spool.find("job1")
        self.assertEqual(state, "done")
        job = read_json(folder / "job.json")
        self.assertEqual([a["status"] for a in job["attempts"]], ["done", "done"])
        self.assertEqual(job["attempts"][1]["bufsize_k"], 6000)
        self.assertTrue((folder / "attempts" / "1" / "encode.mp4").is_file())
        self.assertLess(job["attempts"][1]["results"]["size_after"],
                        job["attempts"][0]["results"]["size_after"])

    @unittest.skipUnless(have_vmaf(), "ffmpeg with libvmaf is not installed")
    def test_caps_from_the_page_set_the_first_cap_and_the_original_is_hashed(self) -> None:
        clip = make_clip(Path(self.tmp.name) / "clip.mp4", seconds=2)
        caps = [{"max_height": 720, "maxrate_k": 2000}, {"max_height": 0, "maxrate_k": 6000}]
        add_job(self.spool, "paged", original=clip, video_caps=caps)
        add_job(self.spool, "plain", original=clip, queued_at=1)
        self.assertTrue(self.worker.run_once())  # plain: queued first, no caps
        self.assertTrue(self.worker.run_once())  # paged
        expected = hashlib.sha256(clip.read_bytes()).hexdigest()
        plain = read_json(self.spool.find("plain")[1] / "job.json")
        paged = read_json(self.spool.find("paged")[1] / "job.json")
        self.assertEqual((plain["attempts"][0]["maxrate_k"], plain["attempts"][0]["bufsize_k"]),
                         (3000, 12000))
        self.assertEqual((paged["attempts"][0]["maxrate_k"], paged["attempts"][0]["bufsize_k"]),
                         (2000, 8000))
        self.assertEqual(paged["video_caps"], caps)
        self.assertEqual(plain["original"]["sha256"], expected)
        self.assertEqual(paged["original"]["sha256"], expected)

    def test_a_finished_job_without_a_hash_gets_one_and_keeps_everything_else(self) -> None:
        # A job whose encode finished before the worker hashed originals.
        attempt = {"n": 1, "status": "done", "crf": 21, "maxrate_k": 3000, "requested_at": 5}
        job_dir = add_job(self.spool, "before-hashing", state="done", queued_at=5,
                          attempts=[attempt], stage="ready")
        (job_dir / "original.mp4").write_bytes(b"the original upload" * 1000)
        before = read_json(job_dir / "job.json")
        self.assertNotIn("sha256", before["original"])

        self.assertTrue(self.worker.hash_finished())
        self.assertFalse(self.worker.hash_finished())  # nothing left to hash

        job = read_json(self.spool.find("before-hashing")[1] / "job.json")
        expected = hashlib.sha256((job_dir / "original.mp4").read_bytes()).hexdigest()
        self.assertEqual(self.spool.find("before-hashing")[0], "done")
        self.assertEqual(job["original"]["sha256"], expected)
        job["original"].pop("sha256")
        self.assertEqual(job, before)  # attempts, stage and the 7-day clock unchanged

    def test_a_finished_job_without_its_original_is_skipped_once(self) -> None:
        job_dir = add_job(self.spool, "no-original", state="done")
        (job_dir / "original.mp4").unlink()
        with self.assertLogs("encode-review", level="WARNING") as logs:
            self.assertFalse(self.worker.hash_finished())
        self.assertFalse(self.worker.hash_finished())  # not retried, not logged again
        self.assertEqual(len(logs.records), 1)
        self.assertNotIn("sha256", read_json(job_dir / "job.json")["original"])

    @unittest.skipUnless(have_vmaf(), "ffmpeg with libvmaf is not installed")
    def test_playable_original_gets_no_reference_copy(self) -> None:
        clip = make_clip(Path(self.tmp.name) / "Trailer.mp4", seconds=2)
        add_job(self.spool, "job1", original=clip)
        self.assertTrue(self.worker.run_once())
        state, folder = self.spool.find("job1")
        job = read_json(folder / "job.json")
        self.assertEqual(state, "done")
        self.assertTrue(job["original_playable"])
        self.assertNotIn("reference", job)
        self.assertFalse((folder / media.REFERENCE_FILE).exists())

    @unittest.skipUnless(have_vmaf(), "ffmpeg with libvmaf is not installed")
    def test_prores_original_gets_a_reference_copy_once_and_vmaf_uses_the_original(self) -> None:
        clip = make_prores_clip(Path(self.tmp.name) / "Trailer ProRes.mov", seconds=3,
                                size="352x198", rate=25)
        add_job(self.spool, "job1", original=clip)
        stages = []
        real_update = self.worker.update

        def spy(job_dir, job, **fields):
            stages.append(job.get("stage"))
            real_update(job_dir, job, **fields)

        plenty = 50 * 1024**3  # this machine's own free disk must not decide the test
        with mock.patch.object(self.worker, "update", side_effect=spy), \
                mock.patch.object(self.spool, "free_bytes", return_value=plenty), \
                mock.patch.object(media, "score", wraps=media.score) as score:
            self.assertTrue(self.worker.run_once())
        state, folder = self.spool.find("job1")
        self.assertEqual(state, "done")
        job = read_json(folder / "job.json")
        self.assertFalse(job["original_playable"])
        self.assertIn("reference", stages)
        self.assertEqual(job["reference"]["file"], media.REFERENCE_FILE)
        self.assertEqual(job["reference"]["crf"], 12)
        copy = media.probe(folder / media.REFERENCE_FILE)
        self.assertTrue(media.browser_plays(copy))
        self.assertEqual((copy["width"], copy["height"], copy["fps"]), (352, 198, 25.0))
        self.assertTrue(media.durations_match(copy["duration"], job["probe"]["duration"]))
        self.assertTrue(media.is_faststart(folder / media.REFERENCE_FILE))
        self.assertEqual(job["reference"]["size"], (folder / media.REFERENCE_FILE).stat().st_size)
        # VMAF scored the encode against the original itself, not the copy.
        self.assertEqual(score.call_args.args[1].name, "original.mov")
        self.assertEqual([p.name for p in folder.iterdir() if p.name.startswith(".")], [])

        # A redo reuses the copy.
        made = (folder / media.REFERENCE_FILE).stat().st_mtime_ns
        job["attempts"].append({"n": 2, "status": "waiting", "crf": 24, "maxrate_k": 2000})
        write_json(folder / "job.json", job)
        self.spool.move(folder, "queue")
        with mock.patch.object(media, "reference_cmd") as again:
            self.assertTrue(self.worker.run_once())
        again.assert_not_called()
        state, folder = self.spool.find("job1")
        self.assertEqual(state, "done")
        self.assertEqual((folder / media.REFERENCE_FILE).stat().st_mtime_ns, made)

    def redo(self, folder: Path, n: int) -> None:
        job = read_json(folder / "job.json")
        job["attempts"].append({"n": n, "status": "waiting", "crf": 21, "maxrate_k": None})
        write_json(folder / "job.json", job)
        self.spool.move(folder, "queue")

    @unittest.skipUnless(have_vmaf(), "ffmpeg with libvmaf is not installed")
    def test_reference_copy_refused_by_the_floor_stops_the_job_until_a_redo(self) -> None:
        clip = make_prores_clip(Path(self.tmp.name) / "Big.mov", seconds=2)
        add_job(self.spool, "job1", original=clip)
        tight = 10 * 1024**3 + 1024  # just above the floor: the copy would go under it
        with mock.patch.object(self.spool, "free_bytes", return_value=tight), \
                mock.patch.object(media, "encode_cmd") as encode:
            self.assertTrue(self.worker.run_once())
        encode.assert_not_called()  # no encode without a moving comparison
        state, folder = self.spool.find("job1")
        job = read_json(folder / "job.json")
        self.assertEqual(state, "failed")
        self.assertEqual(job["attempts"][0]["status"], "failed")
        self.assertIn("10 GB floor", job["attempts"][0]["error"])
        self.assertIn("original is kept", job["reference_error"])
        self.assertNotIn("reference", job)
        self.assertFalse((folder / media.REFERENCE_FILE).exists())
        self.assertEqual((folder / "original.mov").read_bytes(), clip.read_bytes())

        # With space back, a redo makes the copy and the attempt reaches review.
        self.redo(folder, 2)
        with mock.patch.object(self.spool, "free_bytes", return_value=50 * 1024**3):
            self.assertTrue(self.worker.run_once())
        state, folder = self.spool.find("job1")
        job = read_json(folder / "job.json")
        self.assertEqual(state, "done")
        self.assertEqual(job["reference"]["file"], media.REFERENCE_FILE)
        self.assertNotIn("reference_error", job)
        self.assertEqual([a["status"] for a in job["attempts"]], ["failed", "done"])

    @unittest.skipUnless(have_vmaf(), "ffmpeg with libvmaf is not installed")
    def test_failed_reference_copy_stops_the_job_and_keeps_the_original(self) -> None:
        clip = make_prores_clip(Path(self.tmp.name) / "Broken.mov", seconds=2)
        add_job(self.spool, "job1", original=clip)
        broken = [media.FFMPEG, "-nostdin", "-hide_banner", "-f", "lavfi", "-i", "nullsrc",
                  "-c:v", "no-such-encoder", "-f", "null", "-"]
        with mock.patch.object(self.spool, "free_bytes", return_value=50 * 1024**3), \
                mock.patch.object(media, "reference_cmd", return_value=broken), \
                mock.patch.object(media, "encode_cmd") as encode:
            self.assertTrue(self.worker.run_once())
        encode.assert_not_called()
        state, folder = self.spool.find("job1")
        job = read_json(folder / "job.json")
        self.assertEqual(state, "failed")
        self.assertIn("reference copy for side-by-side review failed", job["attempts"][0]["error"])
        self.assertNotIn("reference", job)
        self.assertEqual([p.name for p in folder.iterdir() if p.name.startswith(".")], [])
        self.assertEqual((folder / "original.mov").read_bytes(), clip.read_bytes())

    def test_main_once_refuses_a_second_worker(self) -> None:
        with self.spool.run_lock() as held:
            self.assertTrue(held)
            self.assertEqual(main(["--spool", str(self.spool.root), "--once"]), 1)

    def test_main_cleanup(self) -> None:
        self.assertEqual(main(["--spool", str(self.spool.root), "--cleanup"]), 0)


if __name__ == "__main__":
    unittest.main()
