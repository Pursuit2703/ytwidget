import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))

import vpn  # noqa: E402
import yt_gate  # noqa: E402

OK = subprocess.CompletedProcess([], 0, "https://stream", "")
BOT = subprocess.CompletedProcess([], 1, "", "ERROR: [youtube] x: Sign in to confirm you're not a bot")
FORBIDDEN = subprocess.CompletedProcess([], 1, "", "ERROR: unable to download: HTTP Error 403: Forbidden")


class FakeTunnel:
    """Stands in for systemctl + wireproxy + ipify. No network, no units."""

    def __init__(self, dead=(), blocked_ports=()):
        self.dead = set(dead)
        self.blocked_ports = set(blocked_ports)
        self.active = False
        self.restarts = []

    def systemctl(self, *args):
        verb = args[0]
        if verb == "restart":
            self.active = True
            self.restarts.append(self.server())
        elif verb == "stop":
            self.active = False
        rc = 0 if (verb != "is-active" or self.active) else 3
        return subprocess.CompletedProcess(args, rc, "", "")

    def endpoint(self):
        try:
            text = vpn.active_link().read_text()
        except OSError:
            return None, None
        name = text.split(" from ", 1)[1].split(" on port ", 1)[0]
        return name, int(vpn.ENDPOINT_RE.search(text)[3])

    def server(self):
        return self.endpoint()[0]

    def exit_ip(self, via_proxy=True, timeout=8.0):
        if not via_proxy:
            return "45.9.230.63"
        name, port = self.endpoint()
        if not self.active or name in self.dead or port in self.blocked_ports:
            return ""
        return f"10.0.0.{ord(name[0])}"


class VpnBase(unittest.TestCase):
    servers = ("a.conf", "b.conf", "c.conf")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["XDG_STATE_HOME"] = self.tmp.name
        os.environ["XDG_CONFIG_HOME"] = self.tmp.name
        os.environ["XDG_DATA_HOME"] = self.tmp.name  # no saved audio
        os.environ["YTWIDGET_COOKIE_PROFILE"] = "/nonexistent"
        vpn.server_dir().mkdir(parents=True)
        for name in self.servers:
            (vpn.server_dir() / name).write_text(
                "[Interface]\nPrivateKey = k\n\n[Peer]\nEndpoint = 1.2.3.4:51820\n")
        self.tunnel = FakeTunnel()
        self.patches = [
            mock.patch.object(vpn, "_systemctl", self.tunnel.systemctl),
            mock.patch.object(vpn, "proxy_listening", lambda timeout=0.5: self.tunnel.active),
            mock.patch.object(vpn, "exit_ip", self.tunnel.exit_ip),
        ]
        for p in self.patches:
            p.start()
        yt_gate._sleep = lambda s: None
        self.calls = []
        self.script = []

        def fake_run(cmd, **kw):
            self.calls.append(cmd)
            return self.script.pop(0) if self.script else OK
        yt_gate._run = fake_run

    def tearDown(self):
        for p in self.patches:
            p.stop()
        yt_gate._run, yt_gate._sleep = subprocess.run, time.sleep
        for key in ("YTWIDGET_COOKIE_PROFILE", "XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"):
            os.environ.pop(key, None)
        self.tmp.cleanup()


class QueueTests(VpnBase):
    def test_queue_syncs_with_folder(self):
        self.assertEqual(vpn.queue(), ["a.conf", "b.conf", "c.conf"])
        (vpn.server_dir() / "b.conf").unlink()
        (vpn.server_dir() / "d.conf").write_text("")
        self.assertEqual(vpn.queue(), ["a.conf", "c.conf", "d.conf"])

    def test_ensure_up_uses_head_and_symlink(self):
        name, gen = vpn.ensure_up()
        self.assertEqual(name, "a.conf")
        self.assertEqual(self.tunnel.server(), "a.conf")
        self.assertEqual(vpn.ensure_up(), (name, gen))  # already healthy: no restart
        self.assertEqual(len(self.tunnel.restarts), 1)

    def test_rotation_moves_blocked_to_end_and_changes_exit_ip(self):
        vpn.ensure_up()
        ip_before = self.tunnel.exit_ip()
        name, _ = vpn.rotate("not a bot")
        self.assertEqual(name, "b.conf")
        self.assertEqual(vpn.queue(), ["b.conf", "c.conf", "a.conf"])
        self.assertEqual(self.tunnel.server(), "b.conf")
        self.assertNotEqual(self.tunnel.exit_ip(), ip_before)

    def test_dead_server_skipped(self):
        self.tunnel.dead = {"a.conf"}
        self.assertEqual(vpn.ensure_up()[0], "b.conf")
        self.assertEqual(vpn.queue()[-1], "a.conf")

    def test_all_dead_raises_and_stops_tunnel(self):
        self.tunnel.dead = set(self.servers)
        with self.assertRaises(vpn.VpnError):
            vpn.ensure_up()
        self.assertFalse(self.tunnel.active)

    def test_no_servers(self):
        for name in self.servers:
            (vpn.server_dir() / name).unlink()
        with self.assertRaises(vpn.VpnError):
            vpn.ensure_up()

    def test_generation_changes_on_switch(self):
        tag = vpn.ensure_up()
        self.assertTrue(vpn.current(tag))
        vpn.rotate()
        self.assertFalse(vpn.current(tag))

    def test_idle_stop(self):
        vpn.ensure_up()
        with mock.patch.object(vpn, "_now", lambda: time.time() + vpn.IDLE_STOP_SECONDS + 5):
            self.assertTrue(vpn.stop_if_idle())
        self.assertFalse(self.tunnel.active)

    def test_stale_rotation_does_not_skip_a_healthy_server(self):
        tag = vpn.ensure_up()
        vpn.rotate("429", tag)            # request A: a -> b
        name, _ = vpn.rotate("429", tag)  # request B saw the same block on a
        self.assertEqual(name, "b.conf")
        self.assertEqual(vpn.queue(), ["b.conf", "c.conf", "a.conf"])

    def test_home_ip_url_not_reused_in_always_mode(self):
        self.assertTrue(vpn.current(None))
        vpn.set_mode("always")
        self.assertFalse(vpn.current(None))

    def test_symlinked_config_is_a_server(self):
        real = Path(self.tmp.name, "elsewhere.conf")
        real.write_text("[Peer]\nEndpoint = 5.6.7.8:51820\n")
        (vpn.server_dir() / "d.conf").symlink_to(real)
        self.assertIn("d.conf", vpn.queue())

    def test_failures_become_vpn_errors(self):
        with mock.patch.object(vpn, "_point_at", side_effect=PermissionError("denied")):
            with self.assertRaises(vpn.VpnError):
                vpn.ensure_up()

    def test_dead_servers_are_remembered_at_the_back(self):
        self.tunnel.dead = set(self.servers)
        with self.assertRaises(vpn.VpnError):
            vpn.ensure_up()
        self.assertEqual(vpn.queue(), ["a.conf", "b.conf", "c.conf"])
        self.tunnel.dead = {"a.conf"}
        self.assertEqual(vpn.ensure_up()[0], "b.conf")

    def test_blocked_port_falls_back_and_is_remembered(self):
        self.tunnel.blocked_ports = {1224}
        vpn.ensure_up()
        self.assertEqual(self.tunnel.endpoint(), ("a.conf", 88))
        self.assertEqual(vpn.status()["port"], 88)
        self.tunnel.restarts.clear()
        vpn.rotate("429")
        self.assertEqual(self.tunnel.endpoint(), ("b.conf", 88))
        self.assertEqual(self.tunnel.restarts, ["b.conf"])  # 88 tried first

    def test_all_ports_blocked_tries_next_server(self):
        self.tunnel.blocked_ports = set(vpn.DEFAULT_PORTS)
        with self.assertRaises(vpn.VpnError):
            vpn.ensure_up()
        self.assertEqual(len(self.tunnel.restarts), len(self.servers) * len(vpn.DEFAULT_PORTS))

    def test_active_conf_is_private_and_source_untouched(self):
        vpn.ensure_up()
        self.assertEqual(vpn.active_link().stat().st_mode & 0o777, 0o600)
        self.assertFalse(vpn.active_link().is_symlink())
        self.assertIn(":51820", (vpn.server_dir() / "a.conf").read_text())
        self.assertIn("Endpoint = 1.2.3.4:1224", vpn.active_link().read_text())
        self.assertNotIn("active.conf", vpn.queue())

    def test_old_symlink_is_replaced(self):
        vpn.active_link().symlink_to("a.conf")
        vpn.ensure_up()
        self.assertFalse(vpn.active_link().is_symlink())
        self.assertIn(":51820", (vpn.server_dir() / "a.conf").read_text())

    def test_config_without_endpoint_is_skipped(self):
        (vpn.server_dir() / "a.conf").write_text("[Interface]\n")
        self.assertEqual(vpn.ensure_up()[0], "b.conf")

    def test_ports_setting_and_mode_keep_each_other(self):
        (vpn.config_dir() / "vpn.json").write_text('{"ports": [443, 0, "x"]}')
        vpn.set_mode("always")
        self.assertEqual(vpn.ports(), [443])
        self.assertEqual(vpn.mode(), "always")
        self.assertEqual(vpn.ports(88), [443])

    def test_mode_file(self):
        self.assertEqual(vpn.mode(), "fallback")
        vpn.set_mode("always")
        self.assertEqual(vpn.mode(), "always")
        with self.assertRaises(ValueError):
            vpn.set_mode("sometimes")


class LadderTests(VpnBase):
    def test_direct_success_never_starts_tunnel(self):
        self.assertIsNone(yt_gate.run(["yt-dlp", "u"], 10).vpn)
        self.assertEqual(self.tunnel.restarts, [])

    def test_blocked_home_ip_rescued_by_vpn_then_held(self):
        self.script = [BOT, OK]
        result = yt_gate.run(["yt-dlp", "-g", "u"], 10)
        self.assertEqual(result.vpn[0], "a.conf")
        self.assertIn("--proxy", self.calls[1])
        # Next request goes straight to the VPN, not back to the blocked IP.
        yt_gate.run(["yt-dlp", "-g", "v"], 10)
        self.assertIn("--proxy", self.calls[2])
        self.assertEqual(len(self.calls), 3)

    def test_blocked_vpn_server_rotates_once_then_breaker(self):
        self.script = [BOT, BOT, FORBIDDEN]
        with self.assertRaises(yt_gate.Blocked):
            yt_gate.run(["yt-dlp", "u"], 10)
        self.assertEqual(len(self.calls), 3)  # direct + 2 VPN servers, no loop
        self.assertTrue(yt_gate.status()["blocked"])

    def test_vpn_403_rotates_to_next_server(self):
        self.script = [BOT, FORBIDDEN, OK]
        result = yt_gate.run(["yt-dlp", "u"], 10)
        self.assertEqual(result.vpn[0], "b.conf")
        self.assertEqual(vpn.queue()[-1], "a.conf")

    def test_always_mode_never_uses_home_ip(self):
        vpn.set_mode("always")
        yt_gate.run(["yt-dlp", "u"], 10)
        self.assertTrue(all("--proxy" in c for c in self.calls))

    def test_always_mode_without_working_server_fails_clearly(self):
        vpn.set_mode("always")
        self.tunnel.dead = set(self.servers)
        with self.assertRaises(yt_gate.Blocked) as ctx:
            yt_gate.run(["yt-dlp", "u"], 10)
        self.assertIn("VPN", str(ctx.exception))
        self.assertEqual(self.calls, [])

    def test_off_mode_never_touches_vpn(self):
        vpn.set_mode("off")
        self.script = [BOT]
        with self.assertRaises(yt_gate.Blocked):
            yt_gate.run(["yt-dlp", "u"], 10)
        self.assertEqual(self.tunnel.restarts, [])

    def test_prefetch_never_rotates(self):
        self.script = [BOT, OK]
        yt_gate.run(["yt-dlp", "u"], 10)  # rescue: VPN on a.conf, hold set
        self.script = [BOT]
        with self.assertRaises(yt_gate.Blocked):
            yt_gate.run(["yt-dlp", "u"], 10, kind="prefetch")
        self.assertEqual(self.tunnel.restarts, ["a.conf"])

    def test_failed_vpn_result_does_not_set_hold(self):
        private = subprocess.CompletedProcess([], 1, "", "ERROR: [youtube] x: Private video")
        self.script = [BOT, private]
        yt_gate.run(["yt-dlp", "u"], 10)
        self.assertFalse(yt_gate.routes_via_vpn())

    def test_vpn_requests_count_against_budget(self):
        self.script = [BOT, OK]
        yt_gate.run(["yt-dlp", "u"], 10)
        self.assertEqual(yt_gate.status()["requests_last_hour"], 2)


class StreamBindingTests(VpnBase):
    def test_cold_video_proxy_survives_subtitle_options(self):
        import video
        command = video.command_line("mpv", "https://youtube.com/watch?v=x", Path("/tmp/s"),
                                     title="t", start_ms=0, volume=1, sub_lang="en",
                                     max_height=720)
        command[-1:-1] = [f"--http-proxy={vpn.PROXY_URL}",
                          f"--ytdl-raw-options-append=proxy={vpn.PROXY_URL}"]
        replace = max(i for i, c in enumerate(command) if c.startswith("--ytdl-raw-options="))
        append = command.index(f"--ytdl-raw-options-append=proxy={vpn.PROXY_URL}")
        self.assertGreater(append, replace)
        self.assertEqual(command[-1], "https://youtube.com/watch?v=x")

    def test_selftest_decodes_through_proxy(self):
        import health
        vpn.set_mode("always")
        mpv_calls = []
        real_run = health.subprocess.run

        def fake(cmd, **kw):
            if "mpv" in str(cmd[0]):
                mpv_calls.append(cmd)
                return subprocess.CompletedProcess(cmd, 0, b"", b"")
            return real_run(cmd, **kw)
        with mock.patch.object(health.subprocess, "run", fake), \
             mock.patch.object(health.shutil, "which", lambda name: "/usr/bin/" + name):
            entry = health.selftest()
        self.assertTrue(entry["ok"], entry)
        self.assertTrue(entry["via_vpn"])
        self.assertIn(f"--http-proxy={vpn.PROXY_URL}", mpv_calls[0])
        self.assertIn("--ao=null", mpv_calls[0])

    def test_player_binds_proxy_and_reresolves_after_switch(self):
        import player
        resolver = player.StreamResolver()
        resolver.cache_filler.schedule = lambda *a, **k: False
        vpn.set_mode("always")
        url = resolver.resolve("jNQXAC9IVRw")
        self.assertEqual(resolver.proxy_for("jNQXAC9IVRw", url), vpn.PROXY_URL)
        self.assertIn("http-proxy", player.loadfile_command(url, {}, resolver.proxy_for("jNQXAC9IVRw", url))[4])
        resolver.resolve("jNQXAC9IVRw")
        self.assertEqual(len(self.calls), 1)  # cached while the server is unchanged
        vpn.rotate()
        resolver.resolve("jNQXAC9IVRw")
        self.assertEqual(len(self.calls), 2)  # server switched: re-resolved

    def test_direct_url_has_no_proxy(self):
        import player
        resolver = player.StreamResolver()
        resolver.cache_filler.schedule = lambda *a, **k: False
        vpn.set_mode("off")
        url = resolver.resolve("jNQXAC9IVRw")
        self.assertIsNone(resolver.proxy_for("jNQXAC9IVRw", url))
        self.assertNotIn("http-proxy", player.loadfile_command(url, {}, None)[4])


if __name__ == "__main__":
    unittest.main()
