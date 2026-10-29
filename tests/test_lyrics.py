import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))

import lyrics  # noqa: E402


LRC = "[00:12.50]First line\n[00:15.00]Second line\n[01:02.3]Third <00:03.10>line"


def rec(title, artist, duration, synced="", plain="", instrumental=False, id_=None):
    return {"id": id_ or hash((title, artist, duration)), "trackName": title, "artistName": artist,
            "duration": duration, "syncedLyrics": synced, "plainLyrics": plain,
            "instrumental": instrumental}


class NamesTest(unittest.TestCase):
    def test_clean_title_drops_upload_tags_only(self):
        self.assertEqual(lyrics.clean_title("Guren no Yumiya - Attack on Titan OP1 [Piano]"),
                         "Guren no Yumiya - Attack on Titan OP1")
        self.assertEqual(lyrics.clean_title("Daft Punk - Get Lucky (Official Audio) ft. Pharrell"),
                         "Daft Punk - Get Lucky")
        self.assertEqual(lyrics.clean_title("Song (Remix)"), "Song (Remix)")

    def test_topic_channel_is_the_artist(self):
        self.assertEqual(lyrics.clean_artist("Linked Horizon - Topic"), "Linked Horizon")

    def test_name_pairs_try_both_sides_of_the_dash(self):
        pairs = lyrics.name_pairs("Daft Punk - Get Lucky (Official Video)", "DaftPunkVEVO")
        self.assertEqual(pairs[0], ("Get Lucky", "Daft Punk"))
        self.assertIn(("Daft Punk", "Get Lucky"), pairs)


class ParsingTest(unittest.TestCase):
    def test_parse_lrc(self):
        lines = lyrics.parse_lrc(LRC)
        self.assertEqual([l["ms"] for l in lines], [12500, 15000, 62300])
        self.assertEqual(lines[2]["text"], "Third line")

    def test_parse_lrc_repeated_stamps(self):
        lines = lyrics.parse_lrc("[00:05.00][00:30.00]Chorus\n[00:10.00]Verse")
        self.assertEqual([(l["ms"], l["text"]) for l in lines],
                         [(5000, "Chorus"), (10000, "Verse"), (30000, "Chorus")])

    def test_parse_json3_joins_words_and_skips_blank_events(self):
        data = {"events": [
            {"tStartMs": 0, "dDurationMs": 4000},
            {"tStartMs": 1000, "segs": [{"utf8": "hello"}, {"utf8": " world"}]},
            {"tStartMs": 3000, "aAppend": 1, "segs": [{"utf8": "\n"}]},
            {"tStartMs": 4000, "segs": [{"utf8": "next line"}]},
        ]}
        self.assertEqual(lyrics.parse_json3(data),
                         [{"ms": 1000, "text": "hello world"}, {"ms": 4000, "text": "next line"}])

    def test_music_only_captions_are_rejected(self):
        music = [{"ms": i * 1000, "text": t} for i, t in enumerate(["[Music]", "♪", "[Applause]", "[音楽]", "(Music)"])]
        self.assertTrue(lyrics.is_music_only(music))
        words = [{"ms": i * 1000, "text": f"line {i}"} for i in range(6)]
        self.assertFalse(lyrics.is_music_only(words))


class CandidatesTest(unittest.TestCase):
    def test_length_decides_the_match(self):
        calls = []

        def fetch(url):
            calls.append(url)
            if "/get?" in url:
                return None
            return [rec("Guren no Yumiya", "Linked Horizon", 311, LRC),
                    rec("Guren no Yumiya", "Animenz", 336, LRC)]

        cands = lyrics.lrclib_candidates("Guren no Yumiya [Piano]", "Animenz Piano Sheets", 335, fetch)
        self.assertEqual(cands[0]["duration"], 336)
        self.assertLessEqual(cands[0]["diff"], lyrics.MATCH_TOLERANCE_S)
        self.assertGreater(cands[1]["diff"], lyrics.MATCH_TOLERANCE_S)


class FakeVideo:
    def __init__(self, subs=None, kinds=None, duration_ms=0):
        self.record = {"subs": subs or {}, "subKinds": kinds or {}, "durationMs": duration_ms}
        self.calls = 0

    def __call__(self, video_id):
        self.calls += 1
        return self.record


def run_service(item, fetch, video=None, duration_ms=0, tmp=None, other=False):
    done = threading.Event()
    changes = []

    def changed():
        changes.append(svc.snapshot())
        if svc.snapshot()["status"] not in ("loading",):
            done.set()

    svc = lyrics.LyricsService(changed, video or FakeVideo(), fetch, Path(tmp))
    svc.track_changed(item, duration_ms)
    done.wait(5)
    if other:
        done.clear()
        svc.try_other()
        time.sleep(0.05)
        done.wait(5)
    return svc.snapshot(), svc


class ServiceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp.cleanup()

    def test_synced_lyrics_when_length_matches(self):
        def fetch(url):
            if "/get?" in url:
                return rec("Get Lucky", "Daft Punk", 248, LRC)
            return []
        item = {"videoId": "abc", "name": "Daft Punk - Get Lucky (Official Audio)", "subtitle": "Daft Punk",
                "durationMs": 248500}
        result, _ = run_service(item, fetch, tmp=self.tmp.name)
        self.assertEqual(result["status"], "synced")
        self.assertEqual(result["lines"][0], {"ms": 12500, "text": "First line"})

    def test_cover_of_different_length_falls_back_to_captions(self):
        def fetch(url):
            if "timedtext" in url:
                self.assertIn("fmt=json3", url)
                return {"events": [{"tStartMs": i * 2000, "segs": [{"utf8": f"sung line {i}"}]} for i in range(8)]}
            if "/get?" in url:
                return None
            return [rec("Song", "Band", 200, LRC)]
        video = FakeVideo({"en": "https://www.youtube.com/api/timedtext?v=x&fmt=vtt"}, {"en": "auto"})
        item = {"videoId": "cov", "name": "Band - Song (Cover)", "subtitle": "Someone", "durationMs": 260000}
        result, _ = run_service(item, fetch, video, tmp=self.tmp.name)
        self.assertEqual(result["status"], "captions")
        self.assertEqual(result["source"], "auto")
        self.assertEqual(result["lines"][1]["ms"], 2000)

    def test_instrumental_and_music_only_captions_mean_none(self):
        def fetch(url):
            if "timedtext" in url:
                return {"events": [{"tStartMs": 0, "segs": [{"utf8": "[Music]"}]}]}
            return [] if "/search" in url else None
        video = FakeVideo({"en": "https://www.youtube.com/api/timedtext?v=x&fmt=vtt"}, {"en": "auto"})
        item = {"videoId": "pno", "name": "Theme [Piano]", "subtitle": "Animenz Piano Sheets", "durationMs": 300000}
        result, _ = run_service(item, fetch, video, tmp=self.tmp.name)
        self.assertEqual(result["status"], "none")

        def fetch2(url):
            return rec("Theme", "Animenz", 300, "", "", instrumental=True) if "/get?" in url else []
        item2 = dict(item, videoId="pno2")
        result2, _ = run_service(item2, fetch2, tmp=self.tmp.name)
        self.assertEqual((result2["status"], result2["source"]), ("none", "instrumental"))

    def test_offline_is_not_cached_and_cache_is_reused(self):
        def down(url):
            raise lyrics.Offline("no network")
        item = {"videoId": "off", "name": "A - B", "subtitle": "A", "durationMs": 200000}
        result, _ = run_service(item, down, tmp=self.tmp.name)
        self.assertEqual(result["status"], "offline")
        self.assertFalse((Path(self.tmp.name) / "off.json").exists())

        def up(url):
            return rec("B", "A", 200, LRC) if "/get?" in url else []
        result, _ = run_service(item, up, tmp=self.tmp.name)
        self.assertEqual(result["status"], "synced")
        # Now cached: a dead network still gets the lyrics.
        result, _ = run_service(item, down, tmp=self.tmp.name)
        self.assertEqual(result["status"], "synced")

    def test_try_other_moves_to_the_next_option(self):
        def fetch(url):
            if "timedtext" in url:
                return {"events": [{"tStartMs": i * 1000, "segs": [{"utf8": f"caption {i}"}]} for i in range(6)]}
            if "/get?" in url:
                return rec("B", "A", 200, LRC)
            return []
        video = FakeVideo({"en": "https://www.youtube.com/api/timedtext?v=x"}, {"en": "manual"})
        item = {"videoId": "two", "name": "A - B", "subtitle": "A", "durationMs": 200000}
        result, _ = run_service(item, fetch, video, tmp=self.tmp.name, other=True)
        self.assertEqual((result["status"], result["source"]), ("captions", "manual"))


    def test_try_other_wraps_back_to_the_first_match(self):
        def fetch(url):
            if "timedtext" in url:
                return {"events": [{"tStartMs": 0, "segs": [{"utf8": "[Music]"}]}]}
            return rec("B", "A", 200, LRC) if "/get?" in url else []
        video = FakeVideo({"en": "https://www.youtube.com/api/timedtext?v=x"}, {"en": "auto"})
        item = {"videoId": "wrap", "name": "A - B", "subtitle": "A", "durationMs": 200000}
        result, svc = run_service(item, fetch, video, tmp=self.tmp.name, other=True)
        self.assertEqual(result["status"], "none")      # captions were music only
        done = threading.Event()
        svc._on_change = lambda: done.set() if svc.snapshot()["status"] != "loading" else None
        svc.try_other()
        done.wait(5)
        self.assertEqual(svc.snapshot()["status"], "synced")


if __name__ == "__main__":
    unittest.main()
