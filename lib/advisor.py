#!/usr/bin/env python3
"""Periodic anomaly check for mac-energy-manager.

The SwiftBar plugin remains the only sampler. This module is a slow, independent
reader: it snapshots the graph plus memory and foreground metadata, evaluates a small
set of deterministic triggers against that and a short history, and notifies at most
once per condition per cooldown.

It used to ask an LLM "is anything wrong?" every five minutes. Across 2,824 runs it
answered yes 741 times (26%); the cooldown let 20 through, and every one was either a
leaked automation browser — which browser-reap now kills by itself — or Postgres doing
its job. Detection is not a judgement call. It is a threshold on a number, and a rule
you can read, test, and deliberately make fail.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parent.parent
LABEL = "app.energymanager.alerts"   # LaunchAgent label; also the plist filename
DEFAULT_CONFIG: dict[str, Any] = {
    "interval_seconds": 1800,
    "swap_free_floor_mb": 1024,
    "swap_free_critical_mb": 256,
    "swapout_rate_min": 50,
    "idle_seconds_min": 1200,
    "unattended_cpu_min": 100,
    "notification_cooldown_seconds": 1800,
    "history_entries_examined": 12,
    "history_entries_retained": 288,
}
NOTIFICATION_HISTORY_RETAINED = 20


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")


def state_root() -> Path:
    base = Path(os.environ.get("STATE_DIR", Path.home() / ".cache" / "energy-manager"))
    return Path(os.environ.get("ENERGY_ADVISOR_STATE_DIR", base / "advisor"))


def config_path() -> Path:
    return Path(
        os.environ.get(
            "ENERGY_ADVISOR_CONFIG",
            Path.home() / ".config" / "energy-manager" / "advisor.json",
        )
    )


def load_config(path: Path | None = None) -> dict[str, Any]:
    cfg = dict(DEFAULT_CONFIG)
    path = path or config_path()
    try:
        loaded = json.loads(path.read_text())
        if isinstance(loaded, dict):
            cfg.update(loaded)
    except FileNotFoundError:
        pass
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"cannot read advisor config {path}: {exc}") from exc
    return cfg


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def run_command(
    args: list[str],
    *,
    timeout: float,
    input_text: str | None = None,
    check: bool = False,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        input=input_text,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=check,
    )


def collect_graph() -> dict[str, Any]:
    proc = run_command(
        [str(REPO / "bin" / "energy-graph"), "json", "0.3", "0"],
        timeout=25,
        check=True,
    )
    return json.loads(proc.stdout)


def process_chain(node: dict[str, Any], by_pid: dict[str, dict[str, Any]]) -> str:
    labels = [str(node.get("label", "?"))]
    parent = str(node.get("parent", ""))
    for _ in range(64):
        if not parent or parent not in by_pid:
            break
        item = by_pid[parent]
        labels.insert(0, str(item.get("label", "?")))
        parent = str(item.get("parent", ""))
    return " › ".join(labels)


def sanitize_graph(graph: dict[str, Any]) -> dict[str, Any]:
    """Remove command lines while preserving enough shape for anomaly judgment."""
    nodes = [n for n in graph.get("nodes", []) if isinstance(n, dict)]
    by_pid = {str(n.get("pid")): n for n in nodes}
    root_for: dict[str, str] = {}

    def find_root(pid: str) -> str:
        if pid in root_for:
            return root_for[pid]
        seen: list[str] = []
        cur = pid
        for _ in range(64):
            seen.append(cur)
            parent = str(by_pid.get(cur, {}).get("parent", ""))
            if not parent or parent not in by_pid:
                break
            cur = parent
        for item in seen:
            root_for[item] = cur
        return cur

    roots = [n for n in nodes if not n.get("parent") or str(n.get("parent")) not in by_pid]
    roots.sort(key=lambda n: float(n.get("sub", 0)), reverse=True)
    root_rows: list[dict[str, Any]] = []
    for root in roots[:14]:
        rid = str(root.get("pid"))
        descendants = [
            n for n in nodes if str(n.get("pid")) != rid and find_root(str(n.get("pid"))) == rid
        ]
        descendants.sort(key=lambda n: float(n.get("self", 0)), reverse=True)
        root_rows.append(
            {
                "pid": rid,
                "label": root.get("label", "?"),
                "avg_cpu_subtree": round(float(root.get("sub", 0)), 1),
                "now_cpu_subtree": round(float(root.get("sub_now", 0)), 1),
                "avg_cpu_own": round(float(root.get("self", 0)), 1),
                "process_count": int(root.get("nproc", 1)),
                "flagged_for_mode": bool(root.get("flag", False)),
                "hotspots": [
                    {
                        "pid": str(n.get("pid")),
                        "label": n.get("label", "?"),
                        "avg_cpu_own": round(float(n.get("self", 0)), 1),
                        "now_cpu_own": round(float(n.get("self_now", 0)), 1),
                        "chain": process_chain(n, by_pid),
                    }
                    for n in descendants[:4]
                    if float(n.get("self", 0)) >= 0.1
                ],
            }
        )

    hottest = sorted(nodes, key=lambda n: float(n.get("self", 0)), reverse=True)
    hot_rows = [
        {
            "pid": str(n.get("pid")),
            "label": n.get("label", "?"),
            "avg_cpu_own": round(float(n.get("self", 0)), 1),
            "now_cpu_own": round(float(n.get("self_now", 0)), 1),
            "chain": process_chain(n, by_pid),
        }
        for n in hottest[:20]
        if float(n.get("self", 0)) >= 0.1
    ]
    db_links = [
        {
            "source_pid": str(link.get("source", "")),
            "source_label": link.get("source_label", "?"),
            "source_chain": link.get("chain", "?"),
            "database": link.get("database", "?"),
            "container": link.get("container", "?"),
            "host_port": link.get("port"),
            "connected_host_clients": link.get("candidates", 1),
        }
        for link in graph.get("links", [])
        if isinstance(link, dict)
    ]
    return {
        "sample_age_seconds": graph.get("sample_age"),
        "total_visible_avg_cpu": graph.get("total", 0),
        "top_process_trees": root_rows,
        "hottest_individual_processes": hot_rows,
        "docker_database_clients": db_links,
    }


def collect_frontmost_app() -> dict[str, Any]:
    script = (
        'ObjC.import("AppKit");'
        "var a=$.NSWorkspace.sharedWorkspace.frontmostApplication;"
        'a ? JSON.stringify({name:ObjC.unwrap(a.localizedName),'
        "bundle:ObjC.unwrap(a.bundleIdentifier),pid:Number(a.processIdentifier)}) : '{}'"
    )
    try:
        proc = run_command(["osascript", "-l", "JavaScript", "-e", script], timeout=4)
        if proc.returncode == 0:
            value = json.loads(proc.stdout.strip() or "{}")
            if isinstance(value, dict):
                return value
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
        pass
    return {}


def collect_focus_context() -> dict[str, Any]:
    """Which app you are looking at, and nothing else.

    Used by one trigger, to stay quiet about the thing you are actively working in.
    An earlier version also asked cmux for the focused workspace title and could be
    configured to capture the last twelve lines of that terminal, because an LLM was
    being asked to judge the situation and more context made it judge better. No
    threshold needs terminal text, so reading it would be collecting private output
    — prompts, tokens, whatever is on screen — for nothing.
    """
    return {"frontmost_app": collect_frontmost_app()}


def collect_idle_seconds() -> float | None:
    try:
        proc = run_command(["ioreg", "-c", "IOHIDSystem"], timeout=4)
        match = re.search(r'"HIDIdleTime"\s*=\s*(\d+)', proc.stdout)
        return round(int(match.group(1)) / 1_000_000_000, 1) if match else None
    except (OSError, subprocess.TimeoutExpired):
        return None


def collect_power() -> dict[str, Any]:
    try:
        proc = run_command(["pmset", "-g", "batt"], timeout=4)
        text = " ".join(line.strip() for line in proc.stdout.splitlines() if line.strip())
        source = re.search(r"Now drawing from '([^']+)'", text)
        percent = re.search(r"(\d+)%", text)
        return {
            "source": source.group(1) if source else None,
            "battery_percent": int(percent.group(1)) if percent else None,
        }
    except (OSError, subprocess.TimeoutExpired):
        return {}


def collect_memory() -> dict[str, Any]:
    """Swap headroom, swap traffic, and who is holding the RAM.

    The monitor is otherwise CPU-only, and CPU is the wrong number for the failure that
    actually makes this machine unusable: once swap fills, everything stalls on disk
    while the ⚡ figure stays unremarkable. Both readings together cost about 5 ms.
    """
    out: dict[str, Any] = {}
    try:
        usage = run_command(["sysctl", "-n", "vm.swapusage"], timeout=4).stdout
        for key in ("total", "used", "free"):
            m = re.search(rf"{key}\s*=\s*([\d.]+)M", usage)
            if m:
                out[f"swap_{key}_mb"] = round(float(m.group(1)), 1)
    except (OSError, subprocess.TimeoutExpired):
        pass
    try:
        vm = run_command(["vm_stat"], timeout=4).stdout
        for key, field in (("Swapouts", "swapouts"), ("Swapins", "swapins")):
            m = re.search(rf"{key}:\s*(\d+)", vm)
            if m:
                out[field] = int(m.group(1))          # cumulative since boot; rate is a delta
    except (OSError, subprocess.TimeoutExpired):
        pass
    # Aggregated by program, because "Chrome" is fifty processes of 300 MB and no single
    # row of a per-process list would ever show where the memory went.
    try:
        ps = run_command(["ps", "-axo", "rss=,comm="], timeout=8).stdout
        totals: dict[str, int] = {}
        for line in ps.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) != 2 or not parts[0].isdigit():
                continue
            name = parts[1].split("/")[-1].strip()
            # Roll helpers into their app: Chrome's memory lives in fifty renderer
            # processes, and listing the biggest one understates it by several GB.
            name = re.sub(r" Helper.*$| \(Renderer\)| \(GPU\)", "", name).strip()
            if name:
                totals[name] = totals.get(name, 0) + int(parts[0])
        top = sorted(totals.items(), key=lambda kv: kv[1], reverse=True)[:5]
        out["top_rss"] = [{"name": n, "gb": round(kb / 1048576, 1)} for n, kb in top if kb > 262144]
    except (OSError, subprocess.TimeoutExpired):
        pass
    return out


def current_mode() -> str:
    base = Path(os.environ.get("STATE_DIR", Path.home() / ".cache" / "energy-manager"))
    try:
        return (base / "mode").read_text().strip() or "coding"
    except OSError:
        return "coding"


def build_snapshot(
    graph: dict[str, Any] | None = None,
) -> dict[str, Any]:
    raw = graph or collect_graph()
    return {
        "captured_at": now_iso(),
        "activity_mode": current_mode(),
        "user_idle_seconds": collect_idle_seconds(),
        "power": collect_power(),
        "memory": collect_memory(),
        "focus": collect_focus_context(),
        "energy": sanitize_graph(raw),
    }


def history_summary(snapshot: dict[str, Any]) -> dict[str, Any]:
    focus = snapshot.get("focus", {})
    app = focus.get("frontmost_app", {}) if isinstance(focus.get("frontmost_app"), dict) else {}
    roots = snapshot.get("energy", {}).get("top_process_trees", [])
    return {
        "captured_at": snapshot.get("captured_at"),
        "activity_mode": snapshot.get("activity_mode"),
        "frontmost_app": app.get("name"),
        "power_source": snapshot.get("power", {}).get("source"),
        "user_idle_seconds": snapshot.get("user_idle_seconds"),
        "swap_free_mb": snapshot.get("memory", {}).get("swap_free_mb"),
        "swapouts": snapshot.get("memory", {}).get("swapouts"),
        "top_process_trees": [
            {
                "label": row.get("label"),
                "avg_cpu": row.get("avg_cpu_subtree"),
                "now_cpu": row.get("now_cpu_subtree"),
            }
            for row in roots[:8]
        ],
    }


def read_history(path: Path, limit: int) -> list[dict[str, Any]]:
    try:
        lines = path.read_text().splitlines()
    except FileNotFoundError:
        return []
    rows: list[dict[str, Any]] = []
    for line in lines[-limit:]:
        try:
            value = json.loads(line)
            if isinstance(value, dict):
                rows.append(value)
        except json.JSONDecodeError:
            continue
    return rows


def append_history(path: Path, snapshot: dict[str, Any], retain: int) -> list[dict[str, Any]]:
    existing = read_history(path, max(retain - 1, 0))
    rows = (existing + [history_summary(snapshot)])[-retain:]
    atomic_write(path, "".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows))
    return rows



def _no_warning(reason: str) -> dict[str, Any]:
    return {"warn": False, "severity": "info",
            "title": "", "body": "", "reason": reason, "fingerprint": ""}


def _sustained(history: list[dict[str, Any]], predicate, runs: int = 2) -> bool:
    """True when the last `runs` recorded snapshots all satisfy predicate.

    Everything here fires on a condition that has persisted across runs rather than on
    one reading. A single sample is how the previous version talked itself into warning
    on 26% of its runs: at any instant something is always the biggest number.
    """
    recent = history[-runs:]
    return len(recent) >= runs and all(predicate(h) for h in recent)


def trigger_memory(snapshot: dict[str, Any], history: list[dict[str, Any]],
                   cfg: dict[str, Any]) -> dict[str, Any] | None:
    """Swap is nearly gone and the machine is still writing to it.

    This is the failure that made this laptop unusable — 18 GB of 19 GB swap in use,
    load average in the forties, fans at full — and it is invisible to every other part
    of this tool, because CPU% stays unremarkable while everything stalls on disk. No
    reaper fixes it: the memory is held by things you are actually using.
    """
    mem = snapshot.get("memory") or {}
    free = mem.get("swap_free_mb")
    if free is None:
        return None
    floor = float(cfg.get("swap_free_floor_mb", 1024))
    critical = float(cfg.get("swap_free_critical_mb", 256))

    # Swap traffic as a rate, from the cumulative counters. Headroom alone is not enough:
    # swap sitting full but quiet is merely untidy, while swap full AND churning is the
    # state where every keystroke waits on the disk.
    rate = None
    prev = history[-1] if history else None
    if prev and mem.get("swapouts") is not None and prev.get("swapouts") is not None:
        try:
            dt_s = (dt.datetime.fromisoformat(str(snapshot["captured_at"]))
                    - dt.datetime.fromisoformat(str(prev["captured_at"]))).total_seconds()
            if dt_s > 0:
                rate = max(0.0, (int(mem["swapouts"]) - int(prev["swapouts"])) / dt_s)
        except (ValueError, KeyError, TypeError):
            rate = None

    urgent = free <= critical
    churning = free <= floor and (rate is None or rate >= float(cfg.get("swapout_rate_min", 50)))
    if not (urgent or churning):
        return None
    if not urgent and not _sustained(history, lambda h: (h.get("swap_free_mb") or 1e9) <= floor):
        return None

    hogs = ", ".join(f"{r['name']} {r['gb']} GB" for r in (mem.get("top_rss") or [])[:3])
    rate_txt = f", writing {rate:.0f} pages/s" if rate else ""
    return {
        "warn": True,
        "severity": "critical" if urgent else "warning",
        "title": "Swap is nearly full — the Mac is about to crawl",
        "body": f"{free:.0f} MB of swap left{rate_txt}. Holding the most memory: {hogs or 'unknown'}.",
        "reason": f"swap_free_mb={free} rate={rate} floor={floor} critical={critical}",
        "fingerprint": "memory:swap-exhaustion",
    }


def trigger_unattended_drain(snapshot: dict[str, Any], history: list[dict[str, Any]],
                             cfg: dict[str, Any]) -> dict[str, Any] | None:
    """Something expensive is running, you are not at the machine, and nothing will
    clean it up.

    Automation browsers are deliberately excluded: browser-reap kills those on its own
    timer, and an alert about work already scheduled to be undone is pure noise. That
    exclusion is most of why this fires so much less than its predecessor, 70% of whose
    notifications were exactly the case the reaper now handles.
    """
    idle = snapshot.get("user_idle_seconds")
    idle_min = float(cfg.get("idle_seconds_min", 1200))
    if idle is None or float(idle) < idle_min:
        return None
    trees = (snapshot.get("energy") or {}).get("top_process_trees") or []
    floor = float(cfg.get("unattended_cpu_min", 100))
    focus = ((snapshot.get("focus") or {}).get("frontmost_app") or {}).get("name") or ""

    for tree in trees:
        label = str(tree.get("label") or "")
        avg = float(tree.get("avg_cpu_subtree") or 0)
        if avg < floor:
            continue
        if "auto ·" in label:                      # browser-reap owns these
            continue
        if focus and focus.lower() in label.lower():
            continue
        if not _sustained(history, lambda h: any(
                str(t.get("label")) == label and float(t.get("avg_cpu") or 0) >= floor
                for t in (h.get("top_process_trees") or []))):
            continue
        mins = int(float(idle) // 60)
        return {
            "warn": True,
            "severity": "warning",
                "title": f"{label} is burning CPU while you are away",
            "body": f"{avg:.0f}% CPU sustained, and you have been idle {mins} min. "
                    f"Nothing will stop this on its own.",
            "reason": f"label={label} avg={avg} idle_s={idle} floor={floor}",
            "fingerprint": f"unattended:{label[:40]}",
        }
    return None


TRIGGERS = (trigger_memory, trigger_unattended_drain)


def evaluate_triggers(snapshot: dict[str, Any], history: list[dict[str, Any]],
                      cfg: dict[str, Any]) -> dict[str, Any]:
    """Deterministic replacement for the LLM analyzer.

    The previous version asked a model "is anything wrong?" every five minutes and it
    answered yes 26% of the time — 741 warnings across 2,824 runs, of which the cooldown
    let 20 through, all of them either a leaked browser (now auto-reaped) or Postgres
    doing its job. Detection is not a judgement call; it is a threshold on a number that
    is either crossed or not, and a rule that can be read, tested, and made to go red.
    """
    for trigger in TRIGGERS:
        try:
            hit = trigger(snapshot, history, cfg)
        except Exception as exc:                    # a broken rule must not stop the rest
            hit = None
            sys.stderr.write(f"trigger {trigger.__name__} failed: {exc}\n")
        if hit:
            return hit
    return _no_warning("no trigger fired")



def response_fingerprint(response: dict[str, Any]) -> str:
    supplied = str(response.get("fingerprint", "")).strip()
    if supplied:
        return supplied
    raw = f"{response.get('title', '')}\0{response.get('body', '')}"
    return hashlib.sha256(raw.encode()).hexdigest()[:20]


def notification_decision(
    response: dict[str, Any],
    previous: dict[str, Any] | None,
    cfg: dict[str, Any],
    now_epoch: float,
) -> tuple[bool, str]:
    if not response.get("warn"):
        return False, "analyzer said no warning"
    fingerprint = response_fingerprint(response)
    if previous and previous.get("fingerprint") == fingerprint:
        elapsed = now_epoch - float(previous.get("notified_at_epoch", 0))
        cooldown = float(cfg["notification_cooldown_seconds"])
        if response.get("severity") == "critical":
            cooldown = min(cooldown, 600)
        if elapsed < cooldown:
            return False, "duplicate warning in cooldown"
    return True, "new actionable warning"


def post_notification(title: str, body: str) -> None:
    # Notifications posted by `osascript` belong to Script Editor, so clicking one
    # launches Script Editor and exposes the implementation instead of the alert.
    # SwiftBar is already our native host and its notification URL does nothing on
    # click when neither href nor command is supplied. The full text remains in the
    # bounded notification history and the SwiftBar dropdown for later reading.
    query = urllib.parse.urlencode({"plugin": "energy", "title": title, "body": body})
    proc = run_command(["/usr/bin/open", "-g", f"swiftbar://notify?{query}"], timeout=8)
    if proc.returncode != 0:
        raise RuntimeError(f"notification failed: {proc.stderr.strip()}")


def notification_key(notice: dict[str, Any]) -> str:
    epoch = notice.get("notified_at_epoch")
    if epoch is not None:
        return f"epoch:{epoch}"
    response = notice.get("response", {})
    return f"{notice.get('notified_at', '')}\0{response.get('fingerprint', '')}"


def recent_notifications(state: Path, limit: int = 5) -> list[dict[str, Any]]:
    """Return posted notifications newest-first, including the pre-history last alert."""
    rows = read_history(state / "notifications.jsonl", NOTIFICATION_HISTORY_RETAINED)
    try:
        last = json.loads((state / "last-notification.json").read_text())
        if isinstance(last, dict) and notification_key(last) not in {
            notification_key(row) for row in rows
        }:
            rows.append(last)
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        pass
    return list(reversed(rows[-max(0, limit):]))


def append_notification(state: Path, notice: dict[str, Any]) -> None:
    # recent_notifications also imports the single alert written by versions before
    # notifications.jsonl existed, so the upgrade preserves the popup the user just saw.
    rows = list(reversed(recent_notifications(state, NOTIFICATION_HISTORY_RETAINED)))
    rows.append(notice)
    rows = rows[-NOTIFICATION_HISTORY_RETAINED:]
    atomic_write(
        state / "notifications.jsonl",
        "".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n" for row in rows),
    )


def message_field(value: Any) -> str:
    # Tabs/newlines would corrupt the CLI record; "|" is SwiftBar's metadata delimiter.
    without_delimiters = re.sub(r"[\t\r\n|]+", " ", str(value or ""))
    return re.sub(r"\s+", " ", without_delimiters).strip()


def notification_message_rows(state: Path, limit: int = 5) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for notice in recent_notifications(state, limit):
        response = notice.get("response", {})
        raw_time = str(notice.get("notified_at", ""))
        try:
            local_time = dt.datetime.fromisoformat(raw_time).astimezone()
            stamp = local_time.strftime("%Y-%m-%d %H:%M")
        except ValueError:
            stamp = raw_time
        rows.append(
            {
                "timestamp": message_field(stamp),
                "severity": message_field(response.get("severity", "warning")),
                "title": message_field(response.get("title", "Energy monitor warning")),
                "body": message_field(response.get("body", "")),
                "reason": message_field(response.get("reason", "")),
            }
        )
    return rows


def append_run_log(state: Path, row: dict[str, Any]) -> None:
    path = state / "runs.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as fh:
        fh.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")


def acquire_lock(state: Path) -> Path | None:
    lock = state / "run.lock"
    state.mkdir(parents=True, exist_ok=True)
    try:
        lock.mkdir()
        return lock
    except FileExistsError:
        try:
            if time.time() - lock.stat().st_mtime > 600:
                lock.rmdir()
                lock.mkdir()
                return lock
        except OSError:
            pass
    return None


def run_advisor(cfg: dict[str, Any], *, notify: bool = True) -> dict[str, Any]:
    state = state_root()
    lock = acquire_lock(state)
    if lock is None:
        return {"status": "skipped", "reason": "another advisor run is active"}
    started = time.time()
    try:
        snapshot = build_snapshot()
        sample_age = snapshot.get("energy", {}).get("sample_age_seconds")
        if sample_age is None or float(sample_age) > 45:
            result = {"status": "skipped", "reason": "energy samples are stale", "sample_age": sample_age}
            append_run_log(state, {"at": now_iso(), **result})
            return result
        history = append_history(
            state / "history.jsonl",
            snapshot,
            int(cfg["history_entries_retained"]),
        )
        recent = history[-int(cfg["history_entries_examined"]):]
        response = evaluate_triggers(snapshot, recent, cfg)
        atomic_write(state / "last-result.json", json.dumps(response, indent=2) + "\n")
        previous = None
        try:
            previous = json.loads((state / "last-notification.json").read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        should_notify, decision_reason = notification_decision(response, previous, cfg, time.time())
        notified = False
        if should_notify and notify:
            post_notification(response["title"] or "Energy monitor warning", response["body"])
            notice = {
                "fingerprint": response_fingerprint(response),
                "notified_at": now_iso(),
                "notified_at_epoch": time.time(),
                "response": response,
            }
            append_notification(state, notice)
            atomic_write(state / "last-notification.json", json.dumps(notice, indent=2) + "\n")
            notified = True
        result = {
            "status": "ok",
            "response": response,
            "notification": "posted" if notified else decision_reason if notify else "disabled for this run",
            "duration_seconds": round(time.time() - started, 2),
        }
        append_run_log(state, {"at": now_iso(), **result})
        return result
    except Exception as exc:
        result = {
            "status": "error",
            "error": str(exc),
            "duration_seconds": round(time.time() - started, 2),
        }
        append_run_log(state, {"at": now_iso(), **result})
        return result
    finally:
        try:
            lock.rmdir()
        except OSError:
            pass


def launch_agent_payload(interval: int, state: Path, cfg_path: Path) -> dict[str, Any]:
    executable = str(REPO / "bin" / "energy-advisor")
    return {
        "Label": LABEL,
        "ProgramArguments": [executable, "run"],
        "StartInterval": interval,
        "RunAtLoad": False,
        "ProcessType": "Background",
        "LowPriorityIO": True,
        "Nice": 10,
        "EnvironmentVariables": {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "ENERGY_ADVISOR_CONFIG": str(cfg_path),
        },
        "StandardOutPath": str(state / "launchd.out.log"),
        "StandardErrorPath": str(state / "launchd.err.log"),
    }


def install_agent(cfg: dict[str, Any], interval: int | None = None) -> Path:
    interval = int(interval or cfg["interval_seconds"])
    if interval < 60:
        raise RuntimeError("interval must be at least 60 seconds")
    state = state_root()
    state.mkdir(parents=True, exist_ok=True)
    cfg_path = config_path()
    if not cfg_path.exists():
        atomic_write(cfg_path, json.dumps(cfg, indent=2) + "\n")
    plist_path = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"
    plist_path.parent.mkdir(parents=True, exist_ok=True)
    payload = launch_agent_payload(interval, state, cfg_path)
    fd, tmp_name = tempfile.mkstemp(prefix=plist_path.name + ".", dir=plist_path.parent)
    try:
        with os.fdopen(fd, "wb") as fh:
            plistlib.dump(payload, fh, sort_keys=False)
        os.replace(tmp_name, plist_path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
    domain = f"gui/{os.getuid()}"
    subprocess.run(["launchctl", "bootout", domain, str(plist_path)], capture_output=True)
    proc = subprocess.run(["launchctl", "bootstrap", domain, str(plist_path)], text=True, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError(f"launchctl bootstrap failed: {proc.stderr.strip()}")
    return plist_path


def uninstall_agent() -> None:
    plist_path = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"
    domain = f"gui/{os.getuid()}"
    subprocess.run(["launchctl", "bootout", domain, str(plist_path)], capture_output=True)
    try:
        plist_path.unlink()
    except FileNotFoundError:
        pass


def status() -> dict[str, Any]:
    state = state_root()
    plist_path = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"
    proc = subprocess.run(
        ["launchctl", "print", f"gui/{os.getuid()}/{LABEL}"],
        text=True,
        capture_output=True,
    )
    last = None
    try:
        last = json.loads((state / "last-result.json").read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    return {
        "installed": plist_path.exists(),
        "loaded": proc.returncode == 0,
        "config": str(config_path()),
        "state": str(state),
        "last_result": last,
    }


def make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Periodic anomaly check for mac-energy-manager")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("snapshot", help="print the sanitized state the triggers see")
    sub.add_parser("explain", help="show what the triggers see and whether any fires")
    run = sub.add_parser("run", help="take one snapshot and evaluate the triggers")
    run.add_argument("--no-notify", action="store_true", help="analyze and log, but do not notify")
    messages = sub.add_parser("messages", help="show recent posted notifications")
    messages.add_argument("limit", nargs="?", type=int, default=5)
    messages.add_argument("--tsv", action="store_true", help="machine-readable rows for SwiftBar")
    install = sub.add_parser("install", help="install/reload the per-user launch agent")
    install.add_argument("interval", nargs="?", type=int, help="seconds; defaults to config (300)")
    sub.add_parser("uninstall", help="unload and remove the launch agent")
    sub.add_parser("status", help="show launch-agent and last-result status")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = make_parser().parse_args(argv)
    try:
        cfg = load_config()
        if args.command == "snapshot":
            print(
                json.dumps(
                    build_snapshot(),
                    ensure_ascii=False,
                    indent=2,
                )
            )
        elif args.command == "explain":
            snapshot = build_snapshot()
            recent = read_history(
                state_root() / "history.jsonl",
                int(cfg["history_entries_examined"]),
            )
            mem = snapshot.get("memory", {})
            print(f"swap free   : {mem.get('swap_free_mb')} MB "
                  f"(floor {cfg['swap_free_floor_mb']}, critical {cfg['swap_free_critical_mb']})")
            print(f"top memory  : " + ", ".join(
                f"{r['name']} {r['gb']} GB" for r in (mem.get("top_rss") or [])[:4]))
            print(f"user idle   : {snapshot.get('user_idle_seconds')} s "
                  f"(threshold {cfg['idle_seconds_min']})")
            print(f"history     : {len(recent)} snapshot(s)\n")
            for trigger in TRIGGERS:
                hit = trigger(snapshot, recent, cfg)
                print(f"  {trigger.__name__:<28} {'FIRES: ' + hit['title'] if hit else 'quiet'}")
        elif args.command == "run":
            result = run_advisor(cfg, notify=not args.no_notify)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0 if result.get("status") in {"ok", "skipped"} else 1
        elif args.command == "messages":
            rows = notification_message_rows(state_root(), max(0, min(args.limit, 20)))
            if args.tsv:
                for row in rows:
                    print(
                        "\t".join(
                            str(row[key])
                            for key in (
                                "timestamp",
                                "severity",
                                "title",
                                "body",
                                "reason",
                            )
                        )
                    )
            else:
                for row in rows:
                    print(
                        f"{row['timestamp']}  [{row['severity']} {row['confidence']:.0%}]"
                        f"  {row['title']}"
                    )
                    if row["body"]:
                        print(f"  {row['body']}")
                    if row["reason"]:
                        print(f"  Why: {row['reason']}")
        elif args.command == "install":
            path = install_agent(cfg, args.interval)
            print(f"installed {path} ({args.interval or cfg['interval_seconds']}s)")
        elif args.command == "uninstall":
            uninstall_agent()
            print("uninstalled")
        elif args.command == "status":
            print(json.dumps(status(), ensure_ascii=False, indent=2))
    except Exception as exc:
        print(f"energy-advisor: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
