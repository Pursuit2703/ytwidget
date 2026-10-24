import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))

import audio_cache  # noqa: E402
import play_history  # noqa: E402
import search  # noqa: E402

HISTORY = [
    {"videoId": "aaaaaaaaaaa", "name": "Numb", "subtitle": "Linkin Park"},
    {"videoId": "bbbbbbbbbbb", "name": "In the End", "subtitle": "Linkin Park"},
]


class SavedSearchTest(unittest.TestCase):
    def run_query(self, query, saved=("aaaaaaaaaaa",)):
        with mock.patch.object(play_history, "load", return_value=HISTORY), \
             mock.patch.object(search, "_cache_load", return_value={}), \
             mock.patch.object(audio_cache, "lookup",
                               side_effect=lambda vid, *a: Path("/x") if vid in saved else None):
            return [i["name"] for i in search.saved_matches(query, 5)]

    def test_matches_saved_by_title_and_channel(self):
        self.assertEqual(self.run_query("numb linkin park"), ["Numb"])

    def test_unsaved_track_not_offered(self):
        self.assertEqual(self.run_query("in the end"), [])

    def test_all_words_must_match(self):
        self.assertEqual(self.run_query("numb remix"), [])


if __name__ == "__main__":
    unittest.main()
