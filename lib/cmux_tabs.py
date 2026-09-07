#!/usr/bin/env python3
"""Map coding-agent session ids to the cmux tab they belong to, as TSV.

    session-id-prefix \t tab title \t project

A process table gives you `claude --session-id 0a5cd568-...`, which is true and
unreadable: three of those in a menu tell you nothing about which piece of work is
eating a core. cmux already knows the answer — its sidebar shows "Add building
variation within zoning rules" — and stores it in its session file, keyed by the very
session id the agent was launched with. This is only the join.

Read-only, and defensive about shape: cmux owns this file and may change it, in which
case the right behaviour is to emit nothing and let the monitor fall back to session
ids, never to break the menu.
"""

import glob
import json
import os
import re
import sys

SESSION_GLOB = os.path.expanduser(
    "~/Library/Application Support/cmux/session-*.json")

# cmux prefixes a live tab's title with a status glyph — a Braille spinner frame while
# an agent is working, ✳/⠿ and friends otherwise. They animate, so leaving them in
# would make the label flicker between renders for no information gain.
STATUS_CHARS = re.compile(r"^[\s -⁯✀-➿⠀-⣿■-◿]+")


def clean(title, limit=30):
    t = STATUS_CHARS.sub("", title or "").strip()
    t = re.sub(r"\s+", " ", t)
    return t[:limit].rstrip() if len(t) > limit else t


def load(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def panels(data):
    """(workspace, panel) pairs. cmux owns this shape and may change it, so every level
    is checked rather than assumed."""
    for window in data.get("windows") or []:
        tm = window.get("tabManager") or {}
        for ws in tm.get("workspaces") or []:
            if not isinstance(ws, dict):
                continue
            for panel in ws.get("panels") or []:
                if isinstance(panel, dict):
                    yield ws, panel


def session_files():
    """Newest last, so a live window's state wins over a stale previous-session file."""
    for path in sorted(glob.glob(SESSION_GLOB), key=os.path.getmtime):
        if not path.endswith("-previous.json"):
            yield path


def rows(path):
    data = load(path)
    if data is None:
        return
    for ws, panel in panels(data):
        project = os.path.basename((ws.get("currentDirectory") or "").rstrip("/"))
        title = clean(ws.get("customTitle") or ws.get("processTitle") or "")
        agent = (panel.get("terminal") or {}).get("agent") or {}
        sid = agent.get("sessionId")
        if not isinstance(sid, str) or len(sid) < 8:
            continue
        # 8 chars is what the monitor's shortid() pulls out of a command line,
        # so that is the key both sides can agree on without parsing UUIDs.
        yield sid[:8], (title or project), project


def panel_ttys():
    """{cmux panel id: tty name}, e.g. {"3F2B91C4-...": "ttys038"}.

    The other join this file can serve, and the durable one. A session id names the AGENT
    in a tab, which is gone within hours; a panel id names the TAB, which lives for weeks.
    Something a session detached — a dev server, a bake, a browser — routinely outlives the
    agent that started it, and once that agent exits there is nothing left to bill it to.
    Panel id → tty → the tty's session leader gets it an owner that is still there tomorrow.
    See lib/attribution.py, which reads the panel id back out of the process's environment.
    """
    out = {}
    for path in session_files():
        data = load(path)
        if data is None:
            continue
        for _, panel in panels(data):
            pid, tty = panel.get("id"), panel.get("ttyName")
            if isinstance(pid, str) and isinstance(tty, str) and pid and tty:
                out[pid] = tty
    return out


def main():
    seen = {}
    for path in session_files():
        for sid, title, project in rows(path):
            seen[sid] = (title, project)
    out = []
    for sid, (title, project) in seen.items():
        if title or project:
            out.append(f"{sid}\t{title}\t{project}")
    sys.stdout.write("\n".join(out) + ("\n" if out else ""))


if __name__ == "__main__":
    main()
