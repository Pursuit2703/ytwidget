import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))

import playlists  # noqa: E402


class PlaylistCoversTest(unittest.TestCase):
    def test_list_playlists_returns_up_to_four_covers(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "playlists.json"
            items = [{"videoId": str(i), "name": "t", "thumbnail": f"http://x/{i}.jpg"} for i in range(6)]
            playlists.create_playlist("mix", items, path)
            rows = playlists.list_playlists(path)
            self.assertEqual(rows[0]["count"], 6)
            self.assertEqual(rows[0]["covers"], [f"http://x/{i}.jpg" for i in range(4)])

    def test_items_without_thumbnail_are_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "playlists.json"
            playlists.create_playlist("mix", [{"videoId": "a", "name": "t"}], path)
            self.assertEqual(playlists.list_playlists(path)[0]["covers"], [])


if __name__ == "__main__":
    unittest.main()
