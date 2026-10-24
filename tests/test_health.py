import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))

import health  # noqa: E402
import yt_gate  # noqa: E402


class HealthTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["XDG_STATE_HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = self.tmp.name  # no VPN servers
        os.environ["YTWIDGET_COOKIE_PROFILE"] = "/nonexistent"
        health._cache = (0.0, {})
        yt_gate._sleep = lambda s: None
        self.mpv_args = []

        def fake_run(cmd, **kw):
            if "mpv" in cmd[0]:
                self.mpv_args.append(cmd)
                return subprocess.CompletedProcess(cmd, 0, b"", b"")
            return subprocess.CompletedProcess(cmd, 0, "https://stream\n", "")
        yt_gate._run = fake_run
        self.patch = mock.patch.object(health.subprocess, "run", side_effect=fake_run)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()
        yt_gate._run, yt_gate._sleep = subprocess.run, time.sleep
        os.environ.pop("YTWIDGET_COOKIE_PROFILE", None)
        self.tmp.cleanup()

    def test_selftest_is_silent_and_logged(self):
        entry = health.selftest()
        self.assertTrue(entry["ok"])
        self.assertIn("--ao=null", self.mpv_args[0])
        logged = [json.loads(l) for l in health.log_path().read_text().splitlines()]
        self.assertEqual(len(logged), 1)

    def test_selftest_skips_when_blocked(self):
        state = Path(self.tmp.name, "ytwidget", "gate.json")
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text(json.dumps({"blocked_until": time.time() + 600}))
        entry = health.selftest()
        self.assertTrue(entry["skipped"])
        self.assertEqual(self.mpv_args, [])
        self.assertFalse(health.readiness()["ready"])
        self.assertIn("blocking", health.readiness()["reason"])

    def test_summary_pass_rate_and_proven(self):
        now = time.time()
        path = health.log_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        rows = [{"ts": now - i * 3600, "ok": True, "resolve_ms": 1500} for i in range(19)]
        rows.append({"ts": now, "ok": False, "error": "x"})
        rows.append({"ts": now, "ok": False, "skipped": True})
        path.write_text("".join(json.dumps(r) + "\n" for r in rows))
        info = health.summary()
        self.assertEqual(info["runs"], 20)
        self.assertEqual(info["pass_rate"], 0.95)
        self.assertTrue(info["proven"])

    def test_bad_log_lines_are_skipped(self):
        path = health.log_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('[1,2]\n{"ts": "x"}\nnot json\n{"ts": %f, "ok": true}\n' % time.time())
        self.assertEqual(health.summary()["runs"], 1)

    def test_summary_not_proven_with_few_runs(self):
        self.assertFalse(health.summary()["proven"])


if __name__ == "__main__":
    unittest.main()
