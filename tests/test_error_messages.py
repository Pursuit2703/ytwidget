import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))

from player import playback_error_message  # noqa: E402


class PlaybackErrorMessageTests(unittest.TestCase):
    def test_ssl_eof_is_a_clean_network_message(self):
        raw = ("ERROR: [youtube] NZSYKbInWIg: Unable to download API page: [SSL: "
               "UNEXPECTED_EOF_WHILE_READING] EOF occurred in violation of protocol (_ssl.c:1082)")
        self.assertEqual(playback_error_message(raw),
                         "Could not reach YouTube. Check the connection and try again.")

    def test_rate_limit_wins_over_network_words(self):
        self.assertIn("rate-limiting", playback_error_message("HTTP Error 429: Too Many Requests"))

    def test_unknown_error_strips_prefix(self):
        self.assertEqual(playback_error_message("ERROR: something odd"), "something odd")


if __name__ == "__main__":
    unittest.main()
