#!/usr/bin/env python3
"""Recover the owner of a process macOS has already reparented to launchd.

`bin/browser-stamp` solves this by writing the owner down at launch, which is exact but
needs the launcher's cooperation — Playwright and Puppeteer will never call it. The three
signals here need no cooperation at all, because macOS itself carries them:

  env         A process's environment is copied at fork() and never rewritten, so
              CLAUDE_PID / CLAUDE_CODE_SESSION_ID survive reparenting intact. Measured on
              a live machine: 7 of the orphans at ppid=1 still named their owning agent
              session this way, including a Chrome helper and Docker's backend. It even
              survives `open -a`, which was expected to strip the environment.
  responsible macOS maintains a "responsible process" per pid for TCC — the app a
              permission prompt would name. It resolves to the app rather than the agent
              (an orphaned node returns cmux; a Chrome helper returns Chrome), so it is a
              coarser answer than env, but it generalises the cmux fallback that
              lib/tree.awk otherwise has to hard-code by name.
  pgid        A detached child usually keeps its process group. Weakest of the three — a
              real daemon calls setsid() and loses it — but it is one more ps field in a
              script that is already running, so it costs nothing to try last.

Output, one row per resolved process:

    pid \t pid_start \t owner_pid \t owner_start \t source \t session_id

Both start times are included so lib/tree.awk can refuse a recycled pid on either end,
exactly as it does for the launch stamp and the remembered-parent table.

Results are cached by (pid, start): a process's environment cannot change, so an answer is
computed once and then costs nothing. The cache is pruned to live processes on every run,
which keeps it the size of the orphan set.

PRIVACY: environments hold API keys and tokens. Only the identity variables below are ever
read out of one, and no other part of any environment is stored, printed or returned. That
is also why environments are read one pid at a time rather than with a bulk `ps -axeww` —
besides being more reliable (the bulk form surfaced 2 carriers where per-pid iteration
found 7), it means no unrelated process's secrets are ever in this program's memory.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import os
import subprocess
import sys
from pathlib import Path

IDENTITY_VARS = ("CLAUDE_PID", "CLAUDE_CODE_SESSION_ID", "CMUX_PANEL_ID")

# Never bill a tree to one of these even when a signal points at it: they are the machine
# rather than a piece of anyone's work, and adopting onto them collapses the forest into
# one meaningless root.
NEVER_OWNER = ("launchd", "logind", "loginwindow", "WindowServer", "kernel_task",
               "MacOS/Finder", "MacOS/Dock", "MacOS/SystemUIServer")

# Apple's own daemons are launchd-parented BY DESIGN — being an orphan is their normal
# state, not a lost chain, and "responsible" happily traces one back to Finder or the
# frontmost app. Adopting a hundred of those would bury the forest in false edges, so
# they are never candidates. This is also most of the cost saved: it takes the set that
# needs probing from ~130 processes to a handful.
SYSTEM_PREFIXES = ("/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/",
                   "/Library/Apple/", "/usr/bin/", "/Library/PrivilegedHelperTools/")


def ps_out(args: list[str]) -> str:
    try:
        got = subprocess.run(["ps", *args], capture_output=True, text=True, timeout=4)
        return got.stdout if got.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def start_of(pid: str) -> str:
    """lstart as tree.awk spells it: Sat_Aug_8_13:42:58_2026."""
    parts = ps_out(["-o", "lstart=", "-p", pid]).split()
    return "_".join(parts[:5]) if len(parts) >= 5 else ""


def identity_from_env(pid: str) -> dict[str, str]:
    found: dict[str, str] = {}
    for token in ps_out(["-p", pid, "-Eww"]).split():
        name, sep, value = token.partition("=")
        if sep and name in IDENTITY_VARS and value:
            found.setdefault(name, value)
    return found


_responsible: object = None


def responsible_pid(pid: str) -> int:
    """macOS's own answer to "who is responsible for this process", or 0."""
    global _responsible
    if _responsible is None:
        try:
            lib = ctypes.CDLL(ctypes.util.find_library("System"))
            fn = lib.responsibility_get_pid_responsible_for_pid
            fn.argtypes = [ctypes.c_int]
            fn.restype = ctypes.c_int
            _responsible = fn
        except (OSError, AttributeError):
            _responsible = False
    if not _responsible:
        return 0
    try:
        got = _responsible(int(pid))            # type: ignore[operator]
        return got if got > 1 else 0
    except (ValueError, OSError):
        return 0


def read_procs(path: Path) -> dict[str, dict[str, str]]:
    procs: dict[str, dict[str, str]] = {}
    for line in path.read_text(errors="ignore").splitlines():
        f = line.split("\t", 4)
        if len(f) == 5:
            procs[f[0]] = {"ppid": f[1], "start": f[3], "cmd": f[4]}
    return procs


def usable(cand: str, pid: str, procs: dict[str, dict[str, str]]) -> bool:
    return (bool(cand) and cand != pid and cand in procs
            and not any(bad in procs[cand]["cmd"] for bad in NEVER_OWNER))


def resolve(pid: str, procs: dict[str, dict[str, str]]) -> tuple[str, str, str] | None:
    """(owner_pid, source, session_id) from the strongest signal that answers."""
    ident = identity_from_env(pid)
    session = ident.get("CLAUDE_CODE_SESSION_ID", "")
    if usable(ident.get("CLAUDE_PID", ""), pid, procs):
        return ident["CLAUDE_PID"], "env", session

    rp = str(responsible_pid(pid) or "")
    if usable(rp, pid, procs):
        return rp, "responsible", session

    pgid = ps_out(["-o", "pgid=", "-p", pid]).strip()
    if usable(pgid, pid, procs):
        return pgid, "pgid", session
    return None


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(f"usage: {argv[0]} <procs.tsv> [cache.tsv]", file=sys.stderr)
        return 2
    procs = read_procs(Path(argv[1]))
    cache_path = Path(argv[2]) if len(argv) > 2 else None

    rows: list[list[str]] = []
    known: set[str] = set()
    if cache_path and cache_path.exists():
        for line in cache_path.read_text(errors="ignore").splitlines():
            f = line.split("\t")
            # Same pid AND same start time: still the same process, so the answer holds.
            if len(f) == 6 and f[0] in procs and procs[f[0]]["start"] == f[1]:
                rows.append(f)
                known.add(f[0])

    for pid, info in procs.items():
        if pid == "1" or pid in known:
            continue
        try:
            if int(info["ppid"]) > 1:
                continue                        # not an orphan: the real chain is intact
        except ValueError:
            continue
        if info["cmd"].startswith(SYSTEM_PREFIXES):
            continue
        got = resolve(pid, procs)
        # A miss is cached too, as source "-". Without that, every orphan that resolves
        # to nothing gets re-probed on every render forever, and the cache saves nothing
        # — which is exactly what the first version did: 3.0 s warm against 3.3 s cold.
        rows.append([pid, info["start"], got[0], start_of(got[0]), got[1], got[2]]
                    if got else [pid, info["start"], "", "", "-", ""])

    out = "".join("\t".join(r) + "\n" for r in rows)
    if cache_path:
        tmp = cache_path.with_name(cache_path.name + f".tmp{os.getpid()}")
        tmp.write_text(out)
        tmp.replace(cache_path)
    # The cache keeps the misses; the caller only wants rows that actually resolved.
    sys.stdout.write("".join(line + "\n" for line in out.splitlines()
                             if line.split("\t")[4:5] != ["-"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
