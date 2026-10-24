import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))

import audio_cache  # noqa: E402

GOOD = ("https://rr1.googlevideo.com/videoplayback?mime=audio%2Fwebm"
        "&clen=1234&id=abc")


class AudioCacheTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_lookup_miss_and_hit(self):
        self.assertIsNone(audio_cache.lookup("jNQXAC9IVRw", self.dir))
        (self.dir / "jNQXAC9IVRw.webm").write_bytes(b"x")
        self.assertEqual(audio_cache.lookup("jNQXAC9IVRw", self.dir).name,
                         "jNQXAC9IVRw.webm")

    def test_part_file_is_not_a_hit(self):
        (self.dir / "jNQXAC9IVRw.webm.part").write_bytes(b"x")
        self.assertIsNone(audio_cache.lookup("jNQXAC9IVRw", self.dir))

    def test_bad_id_rejected(self):
        self.assertIsNone(audio_cache.lookup("../etc/passwd", self.dir))

    def test_stream_info(self):
        self.assertEqual(audio_cache.stream_info(GOOD), (1234, ".webm"))
        self.assertIsNone(audio_cache.stream_info(GOOD.replace("&clen=1234", "")))
        self.assertIsNone(audio_cache.stream_info(GOOD.replace("audio%2Fwebm", "video%2Fmp4")))
        self.assertIsNone(audio_cache.stream_info(GOOD.replace("1234", str(10 ** 9))))

    def test_evict_removes_oldest_first(self):
        old, new = self.dir / "a.webm", self.dir / "b.webm"
        old.write_bytes(b"x" * 100)
        new.write_bytes(b"x" * 100)
        os.utime(old, (1, 1))
        audio_cache.evict(self.dir, 150)
        self.assertFalse(old.exists())
        self.assertTrue(new.exists())

    def test_stale_part_files_are_removed(self):
        stale, fresh = self.dir / "a.webm.part", self.dir / "b.webm.part"
        stale.write_bytes(b"x")
        fresh.write_bytes(b"x")
        os.utime(stale, (1, 1))
        audio_cache.evict(self.dir, 10 ** 9)
        self.assertFalse(stale.exists())
        self.assertTrue(fresh.exists())


if __name__ == "__main__":
    unittest.main()
