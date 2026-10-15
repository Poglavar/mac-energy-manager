#!/usr/bin/env python3
"""Turn lib/tree.awk's TSV records into the JSON the graph page draws.

Reads the records on stdin, writes one JSON object on stdout. Kept in Python purely
for the JSON escaping: process command lines are full of quotes, backslashes and
non-ASCII, and hand-rolling that in awk is how you get a page that silently fails to
parse. Everything upstream of here is still the same shared awk pipeline the menu bar
uses, so the two views can never disagree about the numbers.
"""
import json
import os
import sys
import time
from memory import capture_memory_state


def main() -> None:
    nodes, roots, links, attrib = [], {}, [], {}
    for line in sys.stdin:
        f = line.rstrip("\n").split("\t")
        if not f:
            continue
        if f[0] == "R" and len(f) >= 10:
            roots[f[1]] = {"nproc": int(f[4]), "flag": f[6] == "1", "crit": f[7] == "1"}
        elif f[0] == "T" and len(f) >= 12:
            nodes.append({
                "pid": f[1],
                "parent": f[2],          # "" for a root; already past any elided plumbing
                "self": float(f[3]),
                "self_now": float(f[4]),
                "sub": float(f[5]),
                "sub_now": float(f[6]),
                "hog": f[7] == "1",
                "label": f[9],
                "via": f[10],            # wrappers collapsed into this edge
                "cmd": f[11],
            })
        elif f[0] == "A" and len(f) >= 4:
            # How this node was re-grafted, so a surprising edge in the diagram can be
            # questioned instead of taken on faith. "stamp" and "memory" are recorded
            # evidence; "env"/"responsible"/"pgid" are read back out of the OS.
            attrib[f[1]] = {"how": f[2], "session": f[4] if len(f) > 4 else ""}
        elif f[0] == "D" and len(f) >= 11:
            links.append({
                "source": f[1],
                "target": f[2],
                "container_id": f[3],
                "container": f[4],
                "database": f[5],
                "port": int(f[6]),
                "sockets": int(f[7]),
                "candidates": int(f[8]),
                "source_label": f[9],
                "chain": f[10],
                "kind": "database-client",
            })

    for n in nodes:
        if n["pid"] in attrib:
            n["attributed"] = attrib[n["pid"]]["how"]
            if attrib[n["pid"]]["session"]:
                n["session"] = attrib[n["pid"]]["session"]
        if n["parent"] == "":
            n.update(roots.get(n["pid"], {"nproc": 1, "flag": False, "crit": False}))

    # How old the newest sample is. The plugin is the sampler; if it is not running
    # the history stops advancing, and the page must say so rather than present
    # ten-minute-old averages as the current state.
    cur = os.environ.get("EM_CUR", "")
    try:
        sample_age = round(time.time() - os.path.getmtime(cur), 1)
    except OSError:
        sample_age = None

    json.dump({
        "generated": time.time(),
        "sample_age": sample_age,
        "memory": capture_memory_state(),
        "nodes": nodes,
        # Causal cross-process links are separate from the process forest. In
        # particular, they never affect subtree totals or kill semantics.
        "links": links,
        # Scale reference for the colour ramp: the heaviest single process on screen.
        # Subtree totals are excluded — a root's total would flatten every real spender.
        "peak": max((n["self"] for n in nodes), default=0.0),
        "total": round(sum(n["self"] for n in nodes), 1),
    }, sys.stdout)


if __name__ == "__main__":
    main()
