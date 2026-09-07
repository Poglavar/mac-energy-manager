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

    def test_a_run_job_stamp_is_read_like_the_agent_variables(self):
        """agents/bin/run-job puts AGENT_JOB_* on everything a detached job spawns, because
        macOS hides the job's own environment. They mean the same thing as CLAUDE_PID."""
        env = "PATH=/usr/bin AGENT_JOB_OWNER_PID=4242 AGENT_JOB_OWNER_SESSION=abc-123"
        with mock.patch.object(attribution, "ps_out", return_value=env), \
             mock.patch.object(attribution, "responsible_pid", return_value=1):
            got = attribution.resolve("600", PROCS)
        self.assertEqual(got, ("4242", "env", "abc-123"))

    def test_the_tab_answers_when_the_agent_that_asked_is_dead(self):
        """The durability case, and the common one: a dev server or a bake outlives the
        session that started it. The agent pid in its environment now points at nothing,
        but the cmux TAB is still open and is a truthful owner."""
        env = ("CLAUDE_PID=999 "                       # long gone: not in PROCS
               "CMUX_PANEL_ID=3F2B91C4-0000-4000-8000-000000000001")
        with mock.patch.object(attribution, "ps_out", return_value=env), \
             mock.patch.object(attribution, "responsible_pid", return_value=0), \
             mock.patch.object(attribution, "panel_ttys",
                               return_value={"3F2B91C4-0000-4000-8000-000000000001": "ttys038"}), \
             mock.patch.object(attribution, "tty_leaders", return_value={"ttys038": "4242"}):
            got = attribution.resolve("600", PROCS)
        self.assertEqual(got, ("4242", "panel", ""))

    def test_a_live_agent_outranks_the_tab_it_runs_in(self):
        """The tab is the fallback, not the answer: while the agent is alive it is the
        narrower and more useful owner."""
        with mock.patch.object(attribution, "ps_out", return_value=ENV_WITH_SECRETS), \
             mock.patch.object(attribution, "responsible_pid", return_value=0), \
             mock.patch.object(attribution, "panel_ttys", return_value={"P": "ttys038"}), \
             mock.patch.object(attribution, "tty_leaders", return_value={"ttys038": "1"}):
            got = attribution.resolve("600", PROCS)
        self.assertEqual(got[0:2], ("4242", "env"))

    def test_a_tab_whose_shell_is_gone_is_not_an_owner(self):
        """A closed tab must degrade to the next signal, never to a dead pid."""
        env = "CMUX_PANEL_ID=P"
        with mock.patch.object(attribution, "ps_out", return_value=env), \
             mock.patch.object(attribution, "responsible_pid", return_value=0), \
             mock.patch.object(attribution, "panel_ttys", return_value={"P": "ttys038"}), \
             mock.patch.object(attribution, "tty_leaders", return_value={"ttys038": "31337"}):
            self.assertIsNone(attribution.resolve("600", PROCS))

    def test_tty_leader_is_the_shell_the_tab_owns_not_what_runs_inside_it(self):
        """login is the leader; the zsh and the agent below it share the tty and are not.
        Picking one of those would put the record back on the timescale of a session."""
        ps = ("  1     0 ??\n"
              "300    66 ttys038\n"          # login: parent (cmux) is not on this tty
              "301   300 ttys038\n"          # zsh
              "302   301 ttys038\n"          # claude
              "400    66 ttys039\n")
        attribution._tty_leader = None
        with mock.patch.object(attribution, "ps_out", return_value=ps):
            leaders = attribution.tty_leaders()
        attribution._tty_leader = None
        self.assertEqual(leaders, {"ttys038": "300", "ttys039": "400"})

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
