# lib/snapshot.sh — the two read-only data steps shared by the menu-bar plugin and the
# graph view. Sourced, never executed.
#
#   em_procs  <out>           this moment's process table, as TSV
#   em_energy <procs> <out>   per-pid energy over the window, from the rolling history
#
# Neither of these writes to the sampling state. The plugin owns the sampler — it is
# what rotates the cumulative-cputime snapshot on every render — and everything else
# is a pure reader of the history that produces. Two samplers racing would corrupt
# both of their intervals, and the corruption would look like plausible numbers.

# BASH_SOURCE under bash, $0 when zsh sources this — without the fallback the path
# silently resolves to the caller's cwd and every helper beside this file goes missing.
EM_LIB="${EM_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
STATE_DIR="${STATE_DIR:-$HOME/.cache/energy-manager}"
HIST="${HIST:-$STATE_DIR/history.tsv}"       # rolling log: epoch<TAB>pid<TAB>cpu%
CUR="${CUR:-$STATE_DIR/cur.tsv}"             # latest interval's cpu%: pid<TAB>cpu%
PARENTS="${PARENTS:-$STATE_DIR/parents.tsv}" # pid<TAB>start<TAB>ppid<TAB>parent-start
WINDOW="${WINDOW:-600}"                      # rolling-average window, seconds

# lstart comes along because it is the only cheap way to tell a pid apart from the pid
# that later reuses its number — the parent memory depends on it.
# The command is split off with sub() instead of by blanking fields: blanking rebuilds
# $0 with OFS and would collapse the runs of spaces inside real command lines (JSON
# arguments, quoted paths), corrupting exactly the rows we most want to read.
em_procs() {
  ps -axo pid=,ppid=,user=,lstart=,command= | awk '
    NF > 8 {
      cmd = $0; sub(/^ *([^ ]+ +){8}/, "", cmd)
      if (cmd !~ /<defunct>/)                              # zombies: nothing to bill or kill
        printf "%s\t%s\t%s\t%s_%s_%s_%s_%s\t%s\n", $1, $2, $3, $4, $5, $6, $7, $8, cmd
    }' > "$1"
}

# avg = sum(cpu% for pid over window) / (distinct sample-times in window). Missing
# samples count as zero, so a process active only part of the window is scored on its
# true time-averaged contribution, and the metric self-adjusts right after startup.
# Ranked pids come from the history (so a recent culprit that just went idle still
# shows), filtered to pids still alive; "now" comes from the latest interval.
em_energy() {
  awk -F'\t' -v c="$(( $(date +%s) - WINDOW ))" '
    FILENAME==ARGV[1] { alive[$1]=1; next }                # procs: pid still exists
    FILENAME==ARGV[2] { nowv[$1]=$2; next }                # cur:   cpu% this cycle
    $1>=c   { sum[$2]+=$3; ep[$1]=1 }                      # hist:  per-pid totals, epochs
    END {
      n=0; for (e in ep) n++; if (n<1) n=1;
      for (p in sum) if (p in alive) printf "%s\t%.1f\t%s\n", p, sum[p]/n, (p in nowv ? nowv[p] : "0.0")
    }' "$1" "$CUR" "$HIST" > "$2"
}

# A python3 that will actually RUN, or "" — never the bare name.
#
# /usr/bin/python3 on a Mac without the Xcode Command Line Tools is a stub whose only
# behaviour is to pop a GUI "install the developer tools?" dialog. `command -v` finds it
# and reports success, so a naive check invites this plugin to throw a modal at a new
# user every ten seconds. Prefer a real interpreter elsewhere on PATH, fall back to the
# system one only when the tools are actually installed, and otherwise report none —
# every python3 caller here degrades to doing less rather than failing.
em_python() {
  if [ -n "${EM_PYTHON:-}" ]; then printf '%s' "$EM_PYTHON"; return; fi
  local p
  for p in $(command -v -a python3 2>/dev/null); do
    [ "$p" = /usr/bin/python3 ] || { printf '%s' "$p"; return; }
  done
  if [ -x /usr/bin/python3 ] && xcode-select -p >/dev/null 2>&1; then
    printf '%s' /usr/bin/python3
  fi
}

# em_attrib <procs> <out> — owners recovered from the OS for processes nothing stamped.
#
# Skipped entirely unless there is an orphan the cache has no answer for yet, because a
# python3 start is ~50 ms and this renders every ten seconds. Answers cannot change (a
# process's environment is fixed at fork), so in the steady state there is nothing to do
# and the cache is simply copied. Cold ~190 ms, warm ~40 ms, skipped 0 ms.
em_attrib() {
  local cache="$STATE_DIR/attrib.tsv" out="$2"
  : > "$out"
  local py; py=$(em_python); [ -n "$py" ] || return 0
  touch "$cache" 2>/dev/null
  # Anything orphaned and not already answered for, at this exact start time?
  if awk -F'\t' '
        FILENAME==ARGV[1] { seen[$1 FS $2]=1; next }
        $2+0 <= 1 && $1 != 1 && !(($1 FS $4) in seen) { found=1; exit }
        END { exit(found ? 0 : 1) }' "$cache" "$1" 2>/dev/null; then
    "$py" "$EM_LIB/attribution.py" "$1" "$cache" > "$out" 2>/dev/null
  fi
  # Fall back to the cache whenever the run above was skipped OR failed. Emitting
  # nothing on a failure would silently un-attribute every tree that is already
  # correctly attributed, which reads as "the feature broke" rather than "one probe
  # failed" — and the cached answers are still true, since a pid's owner cannot change.
  [ -s "$out" ] || awk -F'\t' '$5 != "-"' "$cache" > "$out" 2>/dev/null || : > "$out"
}
