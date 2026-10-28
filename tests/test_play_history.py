import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))

import play_history  # noqa: E402


def track(vid, name="t"):
    return {"videoId": vid, "name": name}


class PlayHistoryTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "history.json"

    def tearDown(self):
        self.dir.cleanup()

    def test_new_track_has_count_one_and_timestamp(self):
        rows = play_history.remember(track("a"), [], self.path, now=1000)
        self.assertEqual(rows[0]["plays"], 1)
        self.assertEqual(rows[0]["playedAt"], 1000)

    def test_replay_moves_to_top_and_counts(self):
        rows = play_history.remember(track("a"), [], self.path, now=1000)
        rows = play_history.remember(track("b"), rows, self.path, now=1100)
        rows = play_history.remember(track("a"), rows, self.path, now=1200)
        self.assertEqual([r["videoId"] for r in rows], ["a", "b"])
        self.assertEqual(rows[0]["plays"], 2)
        self.assertEqual(rows[0]["playedAt"], 1200)

    def test_old_entry_without_count_counts_as_one_play(self):
        rows = play_history.remember(track("a"), [track("a")], self.path, now=5)
        self.assertEqual(rows[0]["plays"], 2)

    def test_clear_empties_file(self):
        rows = play_history.remember(track("a"), [], self.path, now=1)
        self.assertEqual(play_history.load(self.path), rows)
        self.assertEqual(play_history.clear(self.path), [])
        self.assertEqual(play_history.load(self.path), [])


if __name__ == "__main__":
    unittest.main()
