# lib/parents.awk — maintains the memory of who spawned whom across renders.
#
#   awk -f lib/parents.awk parents.tsv procs.tsv > parents.tsv.new
#   parents.tsv  pid \t cstart \t ppid \t pstart      (last cycle's memory)
#   procs.tsv    pid \t ppid \t user \t start \t command
#
# macOS reparents a process to launchd the moment its parent exits, which severs the
# call chain exactly when it gets interesting: the build a coding agent kicked off
# outlives the agent's shell and then looks like a top-level app of its own.
#
# The catch is that the remembered parent is, by definition, the process that just
# died — so pointing at it is useless. Instead we climb: when a remembered parent is
# gone, we re-anchor to ITS remembered parent, and so on, until we reach an ancestor
# that is still running. Last cycle's file is what makes this possible — every process
# that died since then was alive when it was written, so its own parent is recorded
# there too. That also means nothing has to be retained for dead pids: a record is
# kept only while its process lives, so the file stays the size of the process table.
#
# Every record carries the start times of both processes, and a re-anchor only happens
# when they still match. Pids get recycled, and without that check a subtree could be
# grafted onto a stranger that merely inherited the number.

BEGIN { FS = "\t"; OFS = "\t" }

FILENAME == ARGV[1] { OCS[$1] = $2; OPP[$1] = $3; OPS[$1] = $4; next }
{ PP[$1] = $2; ST[$1] = $4 }

function alive(p, start) { return (p in ST) && ST[p] == start }

END {
  for (p in PP) {
    # Normal case: the real parent is right there. Record it and move on.
    if (PP[p] > 1 && (PP[p] in ST)) { print p, ST[p], PP[p], ST[PP[p]]; continue }
    if (!(p in OPP) || OCS[p] != ST[p]) continue      # nothing remembered, or a recycled pid
    a = OPP[p]; as = OPS[p]
    for (i = 0; i < 32 && !alive(a, as); i++) {       # climb to the nearest living ancestor
      if (!(a in OPP)) break
      nas = OPS[a]; a = OPP[a]; as = nas
    }
    if (alive(a, as) && a != p) print p, ST[p], a, as
  }
}
