#!/usr/bin/env python3
"""Headless tests for the shared macOS memory pressure and swap readout."""
import os
import subprocess
import sys
import unittest
from types import SimpleNamespace

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from memory import capture_memory_state, format_summary, parse_pressure, parse_swap_used_gb


class MemorySummaryTests(unittest.TestCase):
    def test_exported_pressure_levels(self):
        self.assertEqual(parse_pressure("1\n"), "Normal")
        self.assertEqual(parse_pressure("2\n"), "Warning")
        self.assertEqual(parse_pressure("4\n"), "Critical")

    def test_internal_enum_values_and_bad_values_are_not_misread_as_green(self):
        for value in ("0", "3", "5", "", "noise"):
            with self.subTest(value=value):
                self.assertEqual(parse_pressure(value), "Unavailable")

    def test_swap_parser_supports_units_and_rejects_missing_values(self):
        self.assertEqual(parse_swap_used_gb("vm.swapusage: total = 8.00G used = 1536.00M free = 6.50G"), 1.5)
        self.assertEqual(parse_swap_used_gb("total=1G used=512K free=0"), 0.0)
        self.assertIsNone(parse_swap_used_gb("vm.swapusage: unavailable"))
        self.assertIsNone(parse_swap_used_gb(f"used = {'9' * 400}G"))

    def test_summary_keeps_unavailable_explicit(self):
        self.assertEqual(format_summary({"pressure": "Unavailable", "swap_used_gb": None}),
                         "Memory: Unavailable · swap unavailable")

    def test_capture_runs_two_bounded_read_only_sysctl_calls(self):
        calls = []
        outputs = ["2\n", "total = 8.00G used = 1024.00M free = 7.00G"]

        def run(command, **kwargs):
            calls.append((command, kwargs))
            return SimpleNamespace(returncode=0, stdout=outputs.pop(0))

        self.assertEqual(capture_memory_state(run), {"pressure": "Warning", "swap_used_gb": 1.0})
        self.assertEqual([call[0] for call in calls], [
            ["sysctl", "-n", "kern.memorystatus_vm_pressure_level"],
            ["sysctl", "vm.swapusage"],
        ])
        self.assertTrue(all(call[1]["timeout"] == 0.5 and call[1]["check"] is False for call in calls))

    def test_timeout_and_command_failure_stay_unavailable(self):
        def timeout(*_args, **_kwargs):
            raise subprocess.TimeoutExpired("sysctl", 0.5)

        self.assertEqual(capture_memory_state(timeout), {"pressure": "Unavailable", "swap_used_gb": None})

        def failure(*_args, **_kwargs):
            return SimpleNamespace(returncode=1, stdout="")

        self.assertEqual(capture_memory_state(failure), {"pressure": "Unavailable", "swap_used_gb": None})


if __name__ == "__main__":
    unittest.main()
