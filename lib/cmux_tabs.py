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


def rows(path):
    try:
        with open(path) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return
    for window in data.get("windows") or []:
        tm = window.get("tabManager") or {}
        for ws in tm.get("workspaces") or []:
            if not isinstance(ws, dict):
                continue
            project = os.path.basename((ws.get("currentDirectory") or "").rstrip("/"))
            title = clean(ws.get("customTitle") or ws.get("processTitle") or "")
            for panel in ws.get("panels") or []:
                if not isinstance(panel, dict):
                    continue
                agent = (panel.get("terminal") or {}).get("agent") or {}
                sid = agent.get("sessionId")
                if not isinstance(sid, str) or len(sid) < 8:
                    continue
                # 8 chars is what the monitor's shortid() pulls out of a command line,
                # so that is the key both sides can agree on without parsing UUIDs.
                yield sid[:8], (title or project), project


def main():
    seen = {}
    # Newest last, so a live window's titles win over a stale previous-session file.
    for path in sorted(glob.glob(SESSION_GLOB), key=os.path.getmtime):
        if path.endswith("-previous.json"):
            continue
        for sid, title, project in rows(path):
            seen[sid] = (title, project)
    out = []
    for sid, (title, project) in seen.items():
        if title or project:
            out.append(f"{sid}\t{title}\t{project}")
    sys.stdout.write("\n".join(out) + ("\n" if out else ""))


if __name__ == "__main__":
    main()
