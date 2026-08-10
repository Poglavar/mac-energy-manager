# lib/load.awk — the cheap "is this machine busy, and who is to blame" reading.
#
# Reads `ps -Ao %cpu=,command= -r` (already sorted by CPU) and emits one compact
# TSV line per top consumer, named with the SHARED labeller so this can never
# disagree with the menu bar or the call graph about what a process is called:
#
#   busy<TAB><total %cpu across all processes>
#   proc<TAB><%cpu><TAB><label>
#
# Deliberately not the full lib/tree.awk pipeline. That builds the whole process
# forest with subtree energy from the rolling history — the right thing for the
# menu and the graph, and far too much for something a browser polls. This is one
# `ps` and one awk pass, so it costs a few milliseconds and never touches the
# sampler's state (see lib/snapshot.sh on why two samplers must not race).
#
# %cpu here is the kernel's per-process figure, which on a multi-core box sums
# well past 100 — that is correct and wanted: 400 on an 8-core machine means half
# the box is busy. The consumer divides by core count.
#
# Load with: awk -f lib/label.awk -f lib/load.awk
#   -v top_n=N   how many consumers to name (default 5)
#   -v min_cpu=X ignore anything under this %cpu (default 1.0)

BEGIN {
  if (top_n == "") top_n = 5
  if (min_cpu == "") min_cpu = 1.0
  total = 0
  n = 0
}

{
  cpu = $1 + 0
  # The command is everything after the %cpu column; rebuilt by substr rather than
  # by blanking $1, because blanking would collapse the runs of spaces inside real
  # command lines (quoted paths, JSON arguments) — the same trap lib/snapshot.sh
  # documents for em_procs.
  cmd = $0
  sub(/^[ \t]*[0-9.]+[ \t]+/, "", cmd)
  if (cmd == "") next
  total += cpu
  if (cpu >= min_cpu && n < top_n) {
    n++
    pcpu[n] = cpu
    plabel[n] = mklabel(cmd)
  }
}

END {
  printf "busy\t%.1f\n", total
  for (i = 1; i <= n; i++) printf "proc\t%.1f\t%s\n", pcpu[i], plabel[i]
}
