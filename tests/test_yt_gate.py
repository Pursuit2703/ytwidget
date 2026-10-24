import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))

import yt_gate  # noqa: E402

OK = subprocess.CompletedProcess([], 0, "https://stream", "")
BLOCKED = subprocess.CompletedProcess([], 1, "", "ERROR: [youtube] x: Sign in to confirm you're not a bot")
PRIVATE = subprocess.CompletedProcess([], 1, "", "ERROR: [youtube] x: Private video")


class GateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["XDG_STATE_HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = self.tmp.name  # no VPN servers
        profile = Path(self.tmp.name, "profile")
        profile.mkdir()
        (profile / "cookies.sqlite").write_bytes(b"")
        os.environ["YTWIDGET_COOKIE_PROFILE"] = str(profile)
        self.clock = [1000.0]
        self.calls = []
        self.script = []
        yt_gate._now = lambda: self.clock[0]
        yt_gate._sleep = lambda s: self.clock.__setitem__(0, self.clock[0] + s)

        def fake_run(cmd, **kw):
            self.calls.append(cmd)
            return self.script.pop(0) if self.script else OK
        yt_gate._run = fake_run

    def tearDown(self):
        import time
        yt_gate._now, yt_gate._sleep, yt_gate._run = time.time, time.sleep, subprocess.run
        os.environ.pop("YTWIDGET_COOKIE_PROFILE", None)
        self.tmp.cleanup()

    def test_success_passes_through_without_cookies(self):
        result = yt_gate.run(["yt-dlp", "-g", "u"], 10)
        self.assertEqual(result.stdout, "https://stream")
        self.assertNotIn("--cookies-from-browser", self.calls[0])

    def test_requests_are_spaced(self):
        yt_gate.run(["yt-dlp", "a"], 10)
        before = self.clock[0]
        yt_gate.run(["yt-dlp", "b"], 10)
        self.assertGreaterEqual(self.clock[0] - before, yt_gate.MIN_GAP[0])

    def test_block_retries_once_with_cookies_then_keeps_them(self):
        self.script = [BLOCKED, OK]
        result = yt_gate.run(["yt-dlp", "-g", "u"], 10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(self.calls), 2)
        self.assertIn("--cookies-from-browser", self.calls[1])
        yt_gate.run(["yt-dlp", "-g", "v"], 10)
        self.assertIn("--cookies-from-browser", self.calls[2])
        self.assertTrue(yt_gate.status()["using_cookies"])

    def test_block_with_cookies_opens_breaker_and_never_retries_again(self):
        self.script = [BLOCKED, BLOCKED]
        with self.assertRaises(yt_gate.Blocked):
            yt_gate.run(["yt-dlp", "u"], 10)
        self.assertEqual(len(self.calls), 2)
        with self.assertRaises(yt_gate.Blocked):
            yt_gate.run(["yt-dlp", "u"], 10)
        self.assertEqual(len(self.calls), 2)
        self.assertTrue(yt_gate.status()["blocked"])

    def test_breaker_survives_restart_and_expires(self):
        self.script = [BLOCKED, BLOCKED]
        with self.assertRaises(yt_gate.Blocked):
            yt_gate.run(["yt-dlp", "u"], 10)
        self.clock[0] += yt_gate.BACKOFF_SECONDS[0] + 1
        self.assertFalse(yt_gate.status()["blocked"])
        self.assertEqual(yt_gate.run(["yt-dlp", "u"], 10).returncode, 0)

    def test_backoff_grows_with_repeated_blocks(self):
        for expected in yt_gate.BACKOFF_SECONDS[:2]:
            self.script = [BLOCKED, BLOCKED]
            with self.assertRaises(yt_gate.Blocked):
                yt_gate.run(["yt-dlp", "u"], 10)
            self.assertAlmostEqual(yt_gate.status()["seconds_left"], expected, delta=1)
            self.clock[0] += expected + 1

    def test_ordinary_error_does_not_trip_breaker(self):
        self.script = [PRIVATE]
        result = yt_gate.run(["yt-dlp", "u"], 10)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(yt_gate.status()["blocked"])
        self.assertEqual(len(self.calls), 1)

    def test_no_firefox_profile_goes_straight_to_breaker(self):
        os.environ["YTWIDGET_COOKIE_PROFILE"] = "/nonexistent"
        self.script = [BLOCKED]
        with self.assertRaises(yt_gate.Blocked):
            yt_gate.run(["yt-dlp", "u"], 10)
        self.assertEqual(len(self.calls), 1)

    def test_hourly_budget(self):
        for _ in range(yt_gate.HOURLY_CAP):
            yt_gate.run(["yt-dlp", "u"], 10)
        with self.assertRaises(yt_gate.Blocked):
            yt_gate.run(["yt-dlp", "u"], 10)
        self.assertEqual(len(self.calls), yt_gate.HOURLY_CAP)

    def test_healthy_false_when_blocked(self):
        self.assertTrue(yt_gate.healthy())
        self.script = [BLOCKED, BLOCKED]
        with self.assertRaises(yt_gate.Blocked):
            yt_gate.run(["yt-dlp", "u"], 10)
        self.assertFalse(yt_gate.healthy())


if __name__ == "__main__":
    unittest.main()


class GateEdgeTest(GateTest):
    def test_429_inside_video_id_is_not_a_block(self):
        self.script = [subprocess.CompletedProcess([], 1, "", "ERROR: [youtube] aB429xyz_-Q: Video unavailable")]
        yt_gate.run(["yt-dlp", "u"], 10)
        self.assertFalse(yt_gate.status()["blocked"])
        self.assertEqual(len(self.calls), 1)

    def test_failed_cookie_retry_does_not_turn_cookies_on(self):
        cookie_err = subprocess.CompletedProcess([], 1, "", "ERROR: could not copy cookie database")
        self.script = [BLOCKED, cookie_err]
        with self.assertRaises(yt_gate.Blocked):
            yt_gate.run(["yt-dlp", "u"], 10)
        self.assertFalse(yt_gate.status()["using_cookies"])

    def test_broken_cookies_are_dropped_and_retried_plain(self):
        self.script = [BLOCKED, OK]
        yt_gate.run(["yt-dlp", "u"], 10)
        self.assertTrue(yt_gate.status()["using_cookies"])
        self.script = [subprocess.CompletedProcess([], 1, "", "ERROR: failed to decrypt cookie"), OK]
        result = yt_gate.run(["yt-dlp", "u"], 10)
        self.assertEqual(result.returncode, 0)
        self.assertNotIn("--cookies-from-browser", self.calls[-1])
        self.assertFalse(yt_gate.status()["using_cookies"])

    def test_concurrent_block_counts_one_strike(self):
        self.script = [BLOCKED, BLOCKED]
        with self.assertRaises(yt_gate.Blocked):
            yt_gate.run(["yt-dlp", "u"], 10)
        # A second request that was already in flight also sees a block.
        with yt_gate._transaction() as state:
            state["blocked_until"] = self.clock[0] + 100
        self.assertEqual(yt_gate.status()["strikes"], 1)

    def test_prefetch_skips_instead_of_queueing(self):
        with yt_gate._transaction() as state:
            state["last_start"] = self.clock[0] + 60
        with self.assertRaises(yt_gate.Blocked):
            yt_gate.run(["yt-dlp", "u"], 10, kind="prefetch")
        self.assertEqual(self.calls, [])

    def test_corrupt_state_file_is_survivable(self):
        path = yt_gate._state_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("{not json")
        self.assertEqual(yt_gate.run(["yt-dlp", "u"], 10).returncode, 0)
