"""The encode preset, the commands and the container checks."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from encode_review import media

from .helpers import HAVE_FFMPEG, make_clip, make_prores_clip


class PresetTest(unittest.TestCase):
    def test_553_defaults_by_height(self) -> None:
        p1080 = media.make_preset(1080)
        self.assertEqual((p1080.crf, p1080.maxrate_k, p1080.bufsize_k, p1080.level),
                         (21, 5000, 20000, "4.1"))
        p720 = media.make_preset(720)
        self.assertEqual((p720.maxrate_k, p720.bufsize_k, p720.level), (3000, 12000, "3.1"))
        self.assertIsNone(media.make_preset(2160).level)

    def test_reference_command_keeps_size_and_rate_and_plays_in_browsers(self) -> None:
        facts = {"width": 1920, "height": 1080, "fps": 24.0, "duration": 100.0}
        cmd = media.reference_cmd(Path("in.mov"), Path("out.mp4"), facts)
        text = " ".join(cmd)
        for part in ("-map 0:v:0", "-map 0:a:0?", "-c:v libx264", "-crf 12",
                     "-maxrate 74649k", "-bufsize 149298k", "-pix_fmt yuv420p",
                     "-c:a aac", "-movflags +faststart"):
            self.assertIn(part, text)
        # No scaling and no frame rate change: the original's size and rate.
        for absent in ("scale", "-r ", "-vf", "-s "):
            self.assertNotIn(absent, text)
        self.assertEqual(cmd[cmd.index("-threads", cmd.index("-i")) + 1], "2")
        # The disk the copy may take is its cap over the duration, sound included.
        self.assertEqual(media.reference_bytes(facts), int((74649 + 192) * 1000 / 8 * 100))

    def test_browser_plays(self) -> None:
        h264 = {"vcodec": "h264", "pix_fmt": "yuv420p", "acodec": "aac",
                "format": "mov,mp4,m4a,3gp,3g2,mj2"}
        self.assertTrue(media.browser_plays(h264))
        self.assertTrue(media.browser_plays({**h264, "acodec": None}))
        self.assertTrue(media.browser_plays({"vcodec": "vp9", "pix_fmt": "yuv420p",
                                             "acodec": "opus", "format": "matroska,webm"}))
        for unplayable in ({"vcodec": "prores", "pix_fmt": "yuv422p10le"},
                           {"pix_fmt": "yuv420p10le"},            # High 10
                           {"acodec": "pcm_s24le"},               # sound no browser plays
                           {"vcodec": "hevc"},
                           {"format": "mpegts"},
                           {"vcodec": "dnxhd", "pix_fmt": "yuv422p"}):
            self.assertFalse(media.browser_plays({**h264, **unplayable}), unplayable)

    @unittest.skipUnless(HAVE_FFMPEG, "ffmpeg is not installed")
    def test_probe_reads_the_container_and_prores_is_not_playable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            mp4 = media.probe(make_clip(Path(tmp) / "a.mp4", seconds=1))
            mov = media.probe(make_prores_clip(Path(tmp) / "b.mov", seconds=1))
        self.assertIn("mp4", mp4["format"].split(","))
        self.assertTrue(media.browser_plays(mp4))
        self.assertEqual((mov["vcodec"], mov["acodec"]), ("prores", "pcm_s24le"))
        self.assertFalse(media.browser_plays(mov))

    def test_requests_are_clamped(self) -> None:
        self.assertEqual(media.make_preset(1080, crf=10).crf, 18)
        self.assertEqual(media.make_preset(1080, crf=40).crf, 26)
        self.assertEqual(media.make_preset(1080, maxrate_k=50).maxrate_k, 1000)
        self.assertEqual(media.make_preset(1080, maxrate_k=99999).maxrate_k, 12000)
        self.assertEqual(media.make_preset(720, crf=23, maxrate_k=2500).bufsize_k, 10000)

    def test_encode_command_holds_the_553_preset(self) -> None:
        cmd = media.encode_cmd(Path("in.mov"), Path("out.mp4"), media.make_preset(1080))
        text = " ".join(cmd)
        for part in ("-map 0:v:0", "-map 0:a:0?", "-c:v libx264", "-preset slow", "-crf 21",
                     "-maxrate 5000k", "-bufsize 20000k", "-profile:v high", "-level:v 4.1",
                     "-pix_fmt yuv420p", "-c:a aac", "-b:a 128k", "-ac 2",
                     "-movflags +faststart"):
            self.assertIn(part, text)
        self.assertEqual(cmd.count("-threads"), 2)
        self.assertEqual(cmd[cmd.index("-threads", cmd.index("-i")) + 1], "2")

    def test_scoring_commands_use_one_thread_and_subsampling(self) -> None:
        tool = media.vmaf_tool_cmd(Path("r.y4m"), Path("d.y4m"), Path("log.json"))
        self.assertEqual(tool[tool.index("--threads") + 1], "1")
        self.assertEqual(tool[tool.index("--subsample") + 1], str(media.VMAF_SUBSAMPLE))
        self.assertEqual(tool[tool.index("--model") + 1], "version=vmaf_v0.6.1")
        self.assertIn("--json", tool)
        ref = media.y4m_cmd(Path("o.mov"), Path("r.y4m"), scale=(1920, 1080), progress=True)
        self.assertIn("scale=1920:1080:flags=bicubic,format=yuv420p", ref)
        self.assertEqual(ref.count("-threads"), 2)
        self.assertEqual(ref[ref.index("-fps_mode") + 1], "passthrough")
        self.assertIn("-progress", ref)
        dist = media.y4m_cmd(Path("e.mp4"), Path("d.y4m"))
        self.assertIn("format=yuv420p", dist)
        self.assertNotIn("-progress", dist)

    def test_duration_tolerance(self) -> None:
        self.assertTrue(media.durations_match(150.0, 150.15))
        self.assertFalse(media.durations_match(150.0, 150.5))


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg and ffprobe are not installed")
class ContainerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_faststart_check(self) -> None:
        plain = make_clip(self.dir / "plain.mp4", seconds=1)
        fast = make_clip(self.dir / "fast.mp4", seconds=1, faststart=True)
        self.assertFalse(media.is_faststart(plain))
        self.assertTrue(media.is_faststart(fast))
        self.assertLess(media.top_level_boxes(fast).index("moov"),
                        media.top_level_boxes(fast).index("mdat"))

    def test_faststart_false_for_non_mp4(self) -> None:
        junk = self.dir / "junk.mp4"
        junk.write_bytes(b"\x00\x00\x00\x08free")
        self.assertFalse(media.is_faststart(junk))

    def test_probe(self) -> None:
        facts = media.probe(make_clip(self.dir / "c.mp4", seconds=2, size="320x180", rate=25))
        self.assertEqual((facts["width"], facts["height"], facts["fps"]), (320, 180, 25.0))
        self.assertEqual(facts["vcodec"], "h264")
        self.assertEqual(facts["acodec"], "aac")
        self.assertAlmostEqual(facts["duration"], 2.0, delta=0.1)

    def test_probe_rejects_non_video(self) -> None:
        junk = self.dir / "notes.mp4"
        junk.write_text("hello")
        with self.assertRaises(media.MediaError):
            media.probe(junk)


if __name__ == "__main__":
    unittest.main()
