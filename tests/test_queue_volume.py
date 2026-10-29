import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))

import queue_session  # noqa: E402


class QueueVolumeTest(unittest.TestCase):
    def test_volume_survives_save_and_load(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "q.json"
            queue_session.save({"items": [{"videoId": "a"}], "index": 0, "volume": 32}, path)
            self.assertEqual(queue_session.load(path)["volume"], 32)

    def test_old_files_without_volume_load_as_unknown(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "q.json"
            path.write_text('{"items": [{"videoId": "a"}], "index": 0}')
            self.assertIsNone(queue_session.load(path)["volume"])


if __name__ == "__main__":
    unittest.main()
