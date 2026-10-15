#!/usr/bin/env python3
"""Read and parse the small system-wide memory summary used by both views."""
import json
import math
import re
import subprocess
import sys
from typing import Callable


# XNU's exported sysctl uses dispatch-note values, not the internal VM enum.
PRESSURE_NAMES = {1: "Normal", 2: "Warning", 4: "Critical"}
SWAP_USED_RE = re.compile(r"\bused\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGTPE]?)\b", re.I)
UNIT_BYTES = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3,
              "T": 1024**4, "P": 1024**5, "E": 1024**6}


def parse_pressure(raw: str) -> str:
    """Map exported XNU pressure values to the three known UI states."""
    try:
        level = int(raw.strip(), 10)
    except (AttributeError, TypeError, ValueError):
        return "Unavailable"
    return PRESSURE_NAMES.get(level, "Unavailable")


def parse_swap_used_gb(raw: str):
    """Read the `used = ...` field from sysctl vm.swapusage, or retain unknown."""
    match = SWAP_USED_RE.search(raw or "")
    if not match:
        return None
    try:
        amount = float(match.group(1))
    except ValueError:
        return None
    if amount < 0 or not math.isfinite(amount):
        return None
    gb = amount * UNIT_BYTES[match.group(2).upper()] / (1024**3)
    return round(gb, 2) if math.isfinite(gb) else None


def _read(command: list, run: Callable) -> str:
    """Run one bounded, read-only macOS sysctl query; failures stay unknown."""
    try:
        result = run(command, capture_output=True, text=True, timeout=0.5, check=False)
    except (OSError, subprocess.SubprocessError):
        return ""
    if getattr(result, "returncode", 1) != 0:
        return ""
    return getattr(result, "stdout", "") or ""


def capture_memory_state(run: Callable = subprocess.run) -> dict:
    """Return pressure and swap used, independently preserving unknown values."""
    pressure = parse_pressure(_read(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], run))
    swap = parse_swap_used_gb(_read(["sysctl", "vm.swapusage"], run))
    return {"pressure": pressure, "swap_used_gb": swap}


def format_summary(state: dict) -> str:
    """Format the compact SwiftBar readout without turning unknown into zero."""
    pressure = state.get("pressure", "Unavailable")
    pressure = pressure if pressure in ("Normal", "Warning", "Critical") else "Unavailable"
    swap = state.get("swap_used_gb")
    swap_text = f"{swap:.2f} GB" if isinstance(swap, (int, float)) and swap >= 0 else "unavailable"
    return f"Memory: {pressure} · swap {swap_text}"


def main() -> None:
    state = capture_memory_state()
    if sys.argv[1:] == ["--summary"]:
        print(format_summary(state))
    else:
        json.dump(state, sys.stdout)


if __name__ == "__main__":
    main()
