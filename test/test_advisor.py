#!/usr/bin/env python3
import contextlib
import json
import os
import sys
import time
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))

import advisor


class AdvisorTests(unittest.TestCase):
    def fixture_graph(self):
        return {
            "sample_age": 4.2,
            "total": 82.0,
            "nodes": [
                {
                    "pid": "100",
                    "parent": "",
                    "label": "cmux",
                    "self": 2.0,
                    "self_now": 1.0,
                    "sub": 62.0,
                    "sub_now": 71.0,
                    "nproc": 4,
                    "flag": False,
                    "cmd": "cmux --token secret-root",
                },
                {
                    "pid": "101",
                    "parent": "100",
                    "label": "codex · abcdef12",
                    "self": 3.0,
                    "self_now": 2.0,
                    "sub": 60.0,
                    "sub_now": 70.0,
                    "cmd": "codex --api-key secret-agent",
                },
                {
                    "pid": "102",
                    "parent": "101",
                    "label": "Google Chrome",
                    "self": 1.0,
                    "self_now": 1.0,
                    "sub": 57.0,
                    "sub_now": 68.0,
                    "cmd": "Chrome --password secret-browser",
                },
                {
                    "pid": "103",
                    "parent": "102",
                    "label": "Chrome tab",
                    "self": 56.0,
                    "self_now": 67.0,
                    "sub": 56.0,
                    "sub_now": 67.0,
                    "cmd": "Chrome Helper https://private.example",
                },
            ],
            "links": [],
        }

    def test_sanitizer_keeps_chain_and_drops_commands(self):
        clean = advisor.sanitize_graph(self.fixture_graph())
        encoded = json.dumps(clean)
        self.assertNotIn("secret-", encoded)
        hottest = clean["hottest_individual_processes"][0]
        self.assertEqual(
            hottest["chain"],
            "cmux › codex · abcdef12 › Google Chrome › Chrome tab",
        )
        self.assertEqual(clean["top_process_trees"][0]["avg_cpu_subtree"], 62.0)

    def test_focus_context_is_only_the_frontmost_app(self):
        """No trigger reads terminal text, so none may be collected.

        An earlier version could capture the tail of the focused cmux terminal to give
        an LLM more to judge with. Nothing consumes it now, and a snapshot that carries
        screen contents is a privacy leak that no threshold pays for. Deleting the
        collector is the fix; this keeps it deleted.
        """
        with mock.patch.object(advisor, "collect_frontmost_app",
                               return_value={"name": "cmux", "bundle": "com.cmuxterm.app"}):
            value = advisor.collect_focus_context()
        self.assertEqual(value, {"frontmost_app": {"name": "cmux",
                                                   "bundle": "com.cmuxterm.app"}})
        self.assertNotIn("screen_tail", json.dumps(value))

    # ---- deterministic triggers ------------------------------------------------
    # Each of these must be able to go red: the point of replacing the LLM was that a
    # rule can be stated, tested, and shown to fail, which "is anything wrong?" cannot.

    @staticmethod
    def mem_snapshot(free_mb, swapouts, when="2026-07-29T12:30:00+02:00"):
        return {
            "captured_at": when,
            "memory": {"swap_free_mb": free_mb, "swapouts": swapouts,
                       "top_rss": [{"name": "Google Chrome", "gb": 6.2}]},
            "energy": {"top_process_trees": []},
            "user_idle_seconds": 0,
        }

    def test_swap_exhaustion_warns_when_sustained(self):
        cfg = dict(advisor.DEFAULT_CONFIG)
        hist = [{"captured_at": "2026-07-29T12:00:00+02:00", "swap_free_mb": 700, "swapouts": 1_000_000},
                {"captured_at": "2026-07-29T12:00:00+02:00", "swap_free_mb": 700, "swapouts": 1_000_000}]
        out = advisor.trigger_memory(self.mem_snapshot(600, 1_200_000), hist, cfg)
        self.assertIsNotNone(out)
        self.assertTrue(out["warn"])
        self.assertEqual(out["fingerprint"], "memory:swap-exhaustion")
        self.assertIn("Google Chrome 6.2 GB", out["body"])

    def test_healthy_swap_never_warns(self):
        cfg = dict(advisor.DEFAULT_CONFIG)
        self.assertIsNone(advisor.trigger_memory(self.mem_snapshot(8000, 1_200_000), [], cfg))

    def test_swap_low_but_quiet_is_not_an_emergency(self):
        # Full-but-idle swap is untidy; full AND churning is what stalls every keystroke.
        cfg = dict(advisor.DEFAULT_CONFIG)
        hist = [{"captured_at": "2026-07-29T12:00:00+02:00", "swap_free_mb": 700, "swapouts": 1_200_000},
                {"captured_at": "2026-07-29T12:00:00+02:00", "swap_free_mb": 700, "swapouts": 1_200_000}]
        self.assertIsNone(advisor.trigger_memory(self.mem_snapshot(700, 1_200_000), hist, cfg))

    def test_critical_swap_fires_immediately_without_history(self):
        cfg = dict(advisor.DEFAULT_CONFIG)
        out = advisor.trigger_memory(self.mem_snapshot(100, 1), [], cfg)
        self.assertEqual(out["severity"], "critical")

    @staticmethod
    def drain_snapshot(label, avg, idle=1800):
        return {
            "captured_at": "2026-07-29T12:30:00+02:00",
            "user_idle_seconds": idle,
            "focus": {"frontmost_app": {"name": "Finder"}},
            "energy": {"top_process_trees": [{"label": label, "avg_cpu_subtree": avg}]},
            "memory": {},
        }

    def test_unattended_drain_warns_when_you_are_away(self):
        cfg = dict(advisor.DEFAULT_CONFIG)
        hist = [{"top_process_trees": [{"label": "Google Chrome", "avg_cpu": 180}]}] * 2
        out = advisor.trigger_unattended_drain(self.drain_snapshot("Google Chrome", 180), hist, cfg)
        self.assertIsNotNone(out)
        self.assertIn("away", out["title"])

    def test_automation_browser_is_left_to_the_reaper(self):
        # 70% of the old advisor's notifications were this case. browser-reap kills it on
        # its own timer, so an alert here is noise about work already scheduled.
        cfg = dict(advisor.DEFAULT_CONFIG)
        hist = [{"top_process_trees": [{"label": "Chrome auto · 123-frames", "avg_cpu": 180}]}] * 2
        self.assertIsNone(advisor.trigger_unattended_drain(
            self.drain_snapshot("Chrome auto · 123-frames", 180), hist, cfg))

    def test_drain_at_the_keyboard_is_not_reported(self):
        cfg = dict(advisor.DEFAULT_CONFIG)
        hist = [{"top_process_trees": [{"label": "Google Chrome", "avg_cpu": 180}]}] * 2
        self.assertIsNone(advisor.trigger_unattended_drain(
            self.drain_snapshot("Google Chrome", 180, idle=5), hist, cfg))

    def test_single_spike_is_not_sustained(self):
        cfg = dict(advisor.DEFAULT_CONFIG)
        self.assertIsNone(advisor.trigger_unattended_drain(
            self.drain_snapshot("Google Chrome", 180), [], cfg))

    def test_quiet_machine_produces_no_warning(self):
        cfg = dict(advisor.DEFAULT_CONFIG)
        out = advisor.evaluate_triggers(self.drain_snapshot("Finder", 2, idle=10), [], cfg)
        self.assertFalse(out["warn"])
        self.assertEqual(out["reason"], "no trigger fired")

    def test_a_broken_trigger_cannot_stop_the_others(self):
        def boom(*_a):
            raise RuntimeError("bad rule")
        original = advisor.TRIGGERS
        advisor.TRIGGERS = (boom, advisor.trigger_memory)
        try:
            out = advisor.evaluate_triggers(self.mem_snapshot(100, 1), [], dict(advisor.DEFAULT_CONFIG))
            self.assertTrue(out["warn"])
        finally:
            advisor.TRIGGERS = original

    def test_duplicate_notification_is_suppressed(self):
        response = {
            "warn": True,
            "severity": "warning",
            "title": "Runaway tab",
            "body": "Chrome is still hot.",
            "reason": "sustained",
            "fingerprint": "chrome:tab",
        }
        cfg = dict(advisor.DEFAULT_CONFIG)
        yes, _ = advisor.notification_decision(response, None, cfg, 2000)
        self.assertTrue(yes)
        no, reason = advisor.notification_decision(
            response,
            {"fingerprint": "chrome:tab", "notified_at_epoch": 1900},
            cfg,
            2000,
        )
        self.assertFalse(no)
        self.assertIn("cooldown", reason)

    @mock.patch("advisor.run_command")
    def test_notification_uses_swiftbar_without_a_click_action(self, run_command):
        run_command.return_value.returncode = 0
        advisor.post_notification("Chrome & Docker", "Still hot — inspect later.")

        args = run_command.call_args.args[0]
        self.assertEqual(args[:2], ["/usr/bin/open", "-g"])
        url = urlparse(args[2])
        self.assertEqual((url.scheme, url.netloc), ("swiftbar", "notify"))
        query = parse_qs(url.query)
        self.assertEqual(query["plugin"], ["energy"])
        self.assertEqual(query["title"], ["Chrome & Docker"])
        self.assertEqual(query["body"], ["Still hot — inspect later."])
        self.assertNotIn("href", query)
        self.assertNotIn("bash", query)

    @staticmethod
    @contextlib.contextmanager
    def fixed_timezone(name="Etc/GMT-2"):
        """Pin the zone so the assertion tests the CONVERSION, not the runner's location.

        These timestamps are rendered in local time on purpose — an alert history is read
        by a person sitting at the machine. Asserting a bare local string therefore baked
        in the author's UTC+2, and the test failed the moment it ran anywhere else (a UTC
        CI runner: 07:12 against the expected 09:12). Local rendering is right; a test
        that only passes in one timezone is not.
        """
        old = os.environ.get("TZ")
        os.environ["TZ"] = name
        time.tzset()
        try:
            yield
        finally:
            if old is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = old
            time.tzset()

    def test_notification_history_imports_last_alert_and_keeps_timestamps(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            old = {
                "fingerprint": "docker:old",
                "notified_at": "2026-07-29T09:12:00+02:00",
                "notified_at_epoch": 1785309120.0,
                "response": {
                    "severity": "warning",
                    "confidence": 0.91,
                    "title": "Old Docker alert",
                    "body": "Docker stayed hot.",
                    "reason": "Unrelated to foreground work.",
                    "fingerprint": "docker:old",
                },
            }
            (state / "last-notification.json").write_text(json.dumps(old))
            with self.fixed_timezone():                 # the epoch above is 09:12 at UTC+2
                rows = advisor.notification_message_rows(state, 5)
                self.assertEqual(rows[0]["timestamp"], "2026-07-29 09:12")
            self.assertEqual(rows[0]["title"], "Old Docker alert")

            new = {
                "fingerprint": "chrome:new",
                "notified_at": "2026-07-29T09:17:00+02:00",
                "notified_at_epoch": 1785309420.0,
                "response": {
                    "severity": "critical",
                    "confidence": 0.95,
                    "title": "Chrome | runaway\n tab",
                    "body": "A renderer is still hot.",
                    "reason": "Persisted for three snapshots.",
                    "fingerprint": "chrome:new",
                },
            }
            advisor.append_notification(state, new)
            rows = advisor.notification_message_rows(state, 5)
            self.assertEqual([row["title"] for row in rows], ["Chrome runaway tab", "Old Docker alert"])
            self.assertEqual(len((state / "notifications.jsonl").read_text().splitlines()), 2)

    def test_launch_agent_uses_requested_interval_and_low_priority(self):
        payload = advisor.launch_agent_payload(
            600,
            Path("/tmp/energy-advisor-test"),
            Path("/tmp/advisor.json"),
        )
        self.assertEqual(payload["StartInterval"], 600)
        self.assertEqual(payload["Nice"], 10)
        self.assertFalse(payload["RunAtLoad"])
        self.assertEqual(payload["ProgramArguments"][-1], "run")


if __name__ == "__main__":
    unittest.main()
