#!/usr/bin/env python3
"""Tests for lib/attribution.py — the owner signals macOS carries for free.

The privacy tests matter as much as the correctness ones: this module reads process
environments, which hold API keys and tokens, so "it only ever takes the identity
variables" has to be a property the tests enforce rather than a claim in a comment.
"""

import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))

import attribution  # noqa: E402

ENV_WITH_SECRETS = (
    "PATH=/usr/bin SHELL=/bin/zsh ANTHROPIC_API_KEY=sk-ant-notarealkey123 "
    "AWS_SECRET_ACCESS_KEY=abcd1234 CLAUDE_PID=4242 "
    "CLAUDE_CODE_SESSION_ID=e4cb37ec-72b5-4fe2-85b1-784c6ded7fc9 HOME=/Users/alice"
)

PROCS = {
    "4242": {"ppid": "100", "start": "S1", "cmd": "/usr/local/bin/claude --session-id e4cb37ec"},
    "600": {"ppid": "1", "start": "S2", "cmd": "/Applications/Google Chrome.app/x --headless"},
    "1": {"ppid": "0", "start": "S0", "cmd": "/sbin/launchd"},
}


class IdentityTests(unittest.TestCase):
    def test_only_identity_variables_are_read_from_an_environment(self):
        with mock.patch.object(attribution, "ps_out", return_value=ENV_WITH_SECRETS):
            got = attribution.identity_from_env("600")
        self.assertEqual(got, {"CLAUDE_PID": "4242",
                               "CLAUDE_CODE_SESSION_ID": "e4cb37ec-72b5-4fe2-85b1-784c6ded7fc9"})
        blob = repr(got)
        self.assertNotIn("sk-ant-", blob)
        self.assertNotIn("AWS_SECRET", blob)

    def test_env_outranks_responsible_and_pgid(self):
        with mock.patch.object(attribution, "ps_out", return_value=ENV_WITH_SECRETS), \
             mock.patch.object(attribution, "responsible_pid", return_value=1):
            got = attribution.resolve("600", PROCS)
        self.assertEqual(got, ("4242", "env", "e4cb37ec-72b5-4fe2-85b1-784c6ded7fc9"))

    def test_responsible_is_used_when_the_environment_says_nothing(self):
        def ps_out(args):
            return "" if "-Eww" in args else "999\n"      # no env; pgid would say 999
        with mock.patch.object(attribution, "ps_out", side_effect=ps_out), \
             mock.patch.object(attribution, "responsible_pid", return_value=4242):
            got = attribution.resolve("600", PROCS)
        self.assertEqual(got, ("4242", "responsible", ""))

    def test_launchd_is_never_an_owner(self):
        """Every orphan's responsible pid can walk to launchd; adopting onto it would
        collapse the whole forest into one root that explains nothing."""
        with mock.patch.object(attribution, "ps_out", return_value=""), \
             mock.patch.object(attribution, "responsible_pid", return_value=1):
            self.assertIsNone(attribution.resolve("600", PROCS))

    def test_a_process_is_never_its_own_owner(self):
        with mock.patch.object(attribution, "ps_out", return_value="CLAUDE_PID=600"), \
             mock.patch.object(attribution, "responsible_pid", return_value=0):
            self.assertIsNone(attribution.resolve("600", PROCS))

    def test_system_daemons_are_not_probed(self):
        """Apple's daemons are launchd-parented by design — being an orphan is their
        normal state, not a lost chain. Probing them was 90% of the cost and produced
        false edges onto Finder."""
        self.assertTrue("/usr/libexec/foo".startswith(attribution.SYSTEM_PREFIXES))
        self.assertFalse("/Applications/Google Chrome.app/x"
                         .startswith(attribution.SYSTEM_PREFIXES))


if __name__ == "__main__":
    unittest.main(verbosity=0)
