# lib/tree.awk — builds the process forest for mac-energy-manager and ranks it by energy.
#
# The plugin used to fold every process straight into its top-level app and throw the
# chain away, so a heavy grandchild showed up either as an orphan row or not at all.
# This keeps the whole call chain: who spawned whom, what each node costs by itself,
# and what its entire subtree costs. Roots are ranked by the subtree total; the tree
# under each root is emitted as ready-to-render rows.
#
# Pure text-in / text-out on purpose — it never shells out to ps, so it can be tested
# headlessly from fixtures (see test/run-tests.sh).
#
# Inputs, in this argument order (all TSV; command must be the last field):
#   energy.tsv   pid \t self_avg \t self_now         per-process energy over the window
#   parents.tsv  pid \t cstart \t ppid \t pstart     remembered real parents (see plugin)
#   procs.tsv    pid \t ppid \t user \t start \t command
#   dbclients.tsv client-pid \t container-id \t container-name \t db-kind
#                 \t host-port \t socket-count \t distinct-client-count
#   owners.tsv   key \t owner-pid \t owner-start \t label
#                 who asked for an automation browser, recorded by bin/browser-stamp at
#                 launch. See resolve_parents() for why this cannot be discovered later.
#                 key is a --user-data-dir path (hand-launched Chrome, matched against
#                 argv) or "pid:<n>" (a daemon, matched against the process itself).
#   tabs.tsv     session-id-prefix \t tab title \t project    (lib/cmux_tabs.py)
#                 what a human calls the agent session, so a row can read
#                 "claude · Enhance parking spot" instead of "claude · 7ba7d89b".
#
# Output records, TSV, first field is the record type. Each R is immediately followed
# by its own K, H and T rows, and roots come out in rank order:
#   R \t pid \t sub_avg \t sub_now \t nproc \t self_avg \t flag \t crit \t label \t cmd
#   K \t pid \t comma-separated subtree pids, leaves first (for "stop whole tree")
#   H \t pid \t self_avg \t label \t ancestor-chain          (energy hotspot inside the tree)
#   T \t pid \t vparent \t self_avg \t self_now \t sub_avg \t sub_now \t hog \t prefix \t label \t via \t cmd
#       vparent = the pid this node hangs off in the DRAWN tree (empty for a root),
#       i.e. after plumbing has been elided — what a graph view needs to draw edges.
#   D \t client-pid \t docker-pid \t container-id \t container-name \t db-kind
#       \t host-port \t sockets \t client-count \t client-label \t full-client-chain
#       A D record is a causal socket link, never process ancestry. It does not change
#       aggregation, kill lists, or real parent fields.
#
# Knobs (-v): top_n tree_min root_min elide_max hog_min max_rows plumbing allow me
#             flag_min db_force

BEGIN {
  FS = "\t"; OFS = "\t"
  if (top_n     == "") top_n     = 12
  if (tree_min  == "") tree_min  = 0.3    # hide subtrees cheaper than this
  if (elide_max == "") elide_max = 0.5    # a link this cheap is plumbing, not a spender
  if (hog_min   == "") hog_min   = 3      # self-cost that makes a node a hotspot
  if (max_rows  == "") max_rows  = 24     # per-tree row budget (threshold self-raises)
  if (flag_min  == "") flag_min  = 3
  if (root_min  == "") root_min  = 0.05   # a root this cheap is not worth a row at all
}

FILENAME == ARGV[1] { SA[$1] = $2 + 0; SN[$1] = $3 + 0; next }
FILENAME == ARGV[2] { RCS[$1] = $2; RP[$1] = $3 + 0; RPS[$1] = $4; next }
FILENAME == ARGV[3] {
  PP[$1] = $2 + 0; USR[$1] = $3; START[$1] = $4; CMD[$1] = $5; ALIVE[$1] = 1
  next
}
FILENAME == ARGV[4] {
  i = ++DBN
  DBPID[i] = $1 + 0; DBCID[i] = $2; DBCNAME[i] = $3; DBKIND[i] = $4
  DBPORT[i] = $5; DBSOCK[i] = $6 + 0; DBCOUNT[i] = $7 + 0
  DBCLIENT[$1 + 0] = 1
  next
}
FILENAME == ARGV[5] { OWNP[$1] = $2 + 0; OWNS[$1] = $3; next }
FILENAME == ARGV[6] { TAB[$1] = $2; TABPROJ[$1] = $3; next }
FILENAME == ARGV[7] {
  ATCS[$1] = $2; ATP[$1] = $3 + 0; ATPS[$1] = $4; ATSRC[$1] = $5; ATSID[$1] = $6; next
}

# Memoised label lookup (mklabel lives in lib/label.awk, loaded alongside).
# An agent whose session id cmux can name is shown by that name instead: the id is
# what the machine calls the session, the tab title is what you call it, and only one
# of those answers "which piece of work is eating a core right now".
function lab(p) { if (!(p in LBL)) LBL[p] = mklabel_tab(CMD[p]); return LBL[p] }

# ---- forest construction ----------------------------------------------------

# True when q is already below p, i.e. re-parenting p under q would make a cycle.
function descends(q, p,   i) {
  for (i = 0; i < 64 && (q in PP); i++) { if (q == p) return 1; q = PP[q] }
  return 0
}

function resolve_parents(   p, q, cmux, u) {
  # Docker's Linux VM runs as a launchd-parented XPC service, so no amount of ppid
  # walking reaches Docker. Adopt it explicitly while com.docker.backend is running.
  for (p in PP)
    if (CMD[p] ~ /Docker\.app\/Contents\/MacOS\/com\.docker\.backend( |$)/ && PP[p] <= 1) DOCK = p
  # agent-browser is a shared daemon: it deliberately detaches from the CLI process
  # that started it, so macOS exposes no truthful Codex-vs-Claude owner afterwards.
  # cmux is the narrowest stable owner we can prove on this machine. Billing the
  # daemon there keeps its Chrome subtree with the agent workload without inventing
  # a particular session.
  for (p in PP) if (CMD[p] ~ /\.app\/Contents\/MacOS\/cmux$/ && PP[p] <= 1) cmux = p
  for (p in PP) {
    if (PP[p] > 1) continue
    if (DOCK != "" && CMD[p] ~ /com\.apple\.Virtualization\.VirtualMachine/) { PP[p] = DOCK + 0; continue }
    # A hand-launched automation browser is reparented to launchd within milliseconds
    # of launch — far inside the sampling interval — so no poller can ever witness who
    # started it. bin/browser-stamp records the owner at launch instead, and here we
    # only join on the profile path, which Chrome repeats in the argv of every helper
    # it spawns. Start times must match for the same reason they must for RP below:
    # a recycled pid must never inherit a fifty-process browser tree.
    u = udd(CMD[p])
    # A daemon is keyed by pid AND start time, so the row stops matching the moment
    # that pid is recycled into some other process.
    if (u == "" || !(u in OWNP)) u = "pid:" p ":" START[p]
    if ((u in OWNP) && (OWNP[u] in ALIVE) && OWNS[u] == START[OWNP[u]] \
        && OWNP[u] != p && !descends(OWNP[u], p)) {
      PP[p] = OWNP[u] + 0; ORPHAN[p] = 1; SRC[p] = "stamp"; continue
    }
    # A process whose parent exits is reparented to launchd and its call chain is
    # lost. We recorded the real parent on an earlier cycle: restore it, but only if
    # that parent is still alive and is still the SAME process — start times must
    # match on both ends, so a recycled pid can never graft a subtree onto a stranger.
    # This outranks the signals below because it is an edge we actually witnessed.
    if ((p in RP) && adopt(p, RP[p]) && RPS[p] == START[RP[p]] && RCS[p] == START[p]) {
      PP[p] = RP[p] + 0; ORPHAN[p] = 1; SRC[p] = "memory"; continue
    }
    # Nothing recorded this one at launch and nobody witnessed it being orphaned — but
    # macOS carries the answer anyway. lib/attribution.py reads it back out of the
    # process's own environment (copied at fork, so it survives reparenting), the TCC
    # "responsible process", or the process group, in that order of strength. Same
    # recycle guard on both ends as everything above.
    if ((p in ATP) && adopt(p, ATP[p]) && ATPS[p] == START[ATP[p]] && ATCS[p] == START[p]) {
      PP[p] = ATP[p] + 0; ORPHAN[p] = 1; SRC[p] = ATSRC[p]; continue
    }
    # Last resort: bill an agent-browser daemon to cmux, which is the narrowest owner
    # provable when every signal above has come up empty.
    if (cmux != "" && CMD[p] ~ /(^|\/)agent-browser(-darwin-[^ ]+)?( |$)/) {
      PP[p] = cmux + 0; SRC[p] = "cmux"; continue
    }
  }
}

# A candidate parent is usable when it is a different, living process that is not
# already below us — the cycle check is what stops a subtree being grafted onto itself.
function adopt(p, q) {
  return (q != "" && q != p && q > 1 && (q in ALIVE) && !descends(q, p))
}

function mark_db_paths(   i, p, j) {
  if (!db_force) return
  for (i = 1; i <= DBN; i++) {
    p = DBPID[i]
    for (j = 0; j < 64 && p > 1 && (p in ALIVE); j++) {
      DBFORCE[p] = 1
      if (!(p in PP) || PP[p] <= 1 || PP[p] == p) break
      p = PP[p]
    }
  }
}

function build_kids(   p, r) {
  for (p in PP) {
    r = PP[p]
    if (r > 1 && (r in PP) && r != p) KIDS[r] = KIDS[r] " " p
    else ROOT[p] = 1                       # child of launchd (or of nothing) = top level
  }
}

function calc(p,   i, n, a, c) {
  if (p in DONE) return
  DONE[p] = 1
  SUBA[p] = SA[p]; SUBN[p] = SN[p]; NPROC[p] = 1
  n = split(KIDS[p], a, " ")
  for (i = 1; i <= n; i++) {
    c = a[i]; calc(c)
    SUBA[p] += SUBA[c]; SUBN[p] += SUBN[c]; NPROC[p] += NPROC[c]
  }
}

# ---- ranking / emission -----------------------------------------------------

function sortdesc(arr, n, key,   i, j, t) {     # insertion sort; n is small everywhere
  for (i = 2; i <= n; i++) {
    t = arr[i]; j = i - 1
    while (j >= 1 && (key == "self" ? SA[arr[j]] < SA[t] : SUBA[arr[j]] < SUBA[t])) { arr[j + 1] = arr[j]; j-- }
    arr[j + 1] = t
  }
}

function vcount(p, thr,   i, n, a, k) {
  if (SUBA[p] < thr && !(p in DBFORCE)) return 0
  k = 1
  n = split(KIDS[p], a, " ")
  for (i = 1; i <= n; i++) k += vcount(a[i], thr)
  return k
}

# Post-order pid list: killing leaves before their parents avoids respawns.
function subpids(p,   i, n, a, s) {
  s = ""
  n = split(KIDS[p], a, " ")
  for (i = 1; i <= n; i++) s = s subpids(a[i]) ","
  return s p
}

function hotspots(root, p,   i, n, a) {
  if (p != root && SA[p] >= hog_min) HS[++HSN] = p
  n = split(KIDS[p], a, " ")
  for (i = 1; i <= n; i++) hotspots(root, a[i])
}

# The top-level process a pid ends up under, after re-grafting.
function rootof(p,   i) {
  for (i = 0; i < 64; i++) {
    if (!(p in PP) || PP[p] <= 1 || PP[p] == p || !(PP[p] in ALIVE)) return p
    p = PP[p]
  }
  return p
}

function chainof(root, p,   q, s, i) {
  s = ""; q = PP[p]
  for (i = 0; i < 64 && q != root && (q in PP) && q > 1; i++) {
    s = (s == "" ? lab(q) : lab(q) " › " s); q = PP[q]
  }
  return (s == "" ? lab(root) : lab(root) " › " s)
}

function fullchain(p,   q, s, i) {
  s = lab(p); q = PP[p]
  for (i = 0; i < 64 && q > 1 && (q in PP); i++) {
    s = lab(q) " › " s
    if (PP[q] == q) break
    q = PP[q]
  }
  return s
}

function isplumbing(p,   b) {
  b = bname(argv0(CMD[p]))
  sub(/^-/, "", b)
  # Elision is for launch plumbing, not for every quiet single-child process.
  # Codex, node harnesses, browsers, Docker clients, etc. are semantic levels in
  # the call graph even when their own CPU rounds to zero.
  return b ~ /^(login|zsh|bash|sh|dash|ksh|fish|env|nohup|script)$/
}

# Emits one T row per visible node, depth-first, heaviest branch first.
function walk(root, p, vpar, pfx, islast, via,   i, n, a, vis, m, j, hog, mypfx, nextpfx) {
  n = split(KIDS[p], a, " ")
  m = 0
  for (i = 1; i <= n; i++) if (SUBA[a[i]] >= THR || (a[i] in DBFORCE)) vis[++m] = a[i]
  sortdesc(vis, m)
  # Plumbing: a cheap node with a single visible child is a link in the chain, not a
  # spender. Collapse it into a "via" crumb on its descendant so the shell wrappers
  # between an app and its real hog do not bury the hog in noise.
  if (!plumbing && p != root && isplumbing(p) && SA[p] < elide_max && m == 1) {
    walk(root, vis[1], vpar, pfx, islast, (via == "" ? lab(p) : via " › " lab(p)))
    return
  }
  hog = (SA[p] >= hog_min || (SUBA[root] > 0 && SA[p] >= 0.25 * SUBA[root])) ? 1 : 0
  mypfx  = (p == root) ? "" : pfx (islast ? "└─ " : "├─ ")
  nextpfx = (p == root) ? "" : pfx (islast ? "   " : "│  ")
  printf "T\t%s\t%s\t%.1f\t%.1f\t%.1f\t%.1f\t%d\t%s\t%s\t%s\t%s\n",
         p, vpar, SA[p], SN[p], SUBA[p], SUBN[p], hog, mypfx, lab(p), via, CMD[p]
  for (j = 1; j <= m; j++) walk(root, vis[j], p, nextpfx, (j == m), "")
}

END {
  resolve_parents(); mark_db_paths(); build_kids()
  for (p in ROOT) calc(p)

  n = 0
  for (p in ROOT) if (SUBA[p] >= root_min || (p in DBFORCE)) RL[++n] = p
  sortdesc(RL, n)
  if (n > top_n) n = top_n

  for (i = 1; i <= n; i++) {
    r = RL[i]
    crit = (mklabel(CMD[r]) ~ /^(WindowServer|loginwindow|launchd|kernel_task|kernelmanagerd)$/) ? 1 : 0
    # Flagged = your own app, actually drawing power, and not expected in this mode.
    flag = 0
    if (!crit && me != "" && USR[r] == me && SUBA[r] >= flag_min)
      flag = (allow != "" && (tolower(lab(r)) ~ tolower(allow) || tolower(CMD[r]) ~ tolower(allow))) ? 0 : 1
    printf "R\t%s\t%.1f\t%.1f\t%d\t%.1f\t%d\t%d\t%s\t%s\n",
           r, SUBA[r], SUBN[r], NPROC[r], SA[r], flag, crit, lab(r), CMD[r]
    if (NPROC[r] < 2) continue

    printf "K\t%s\t%s\n", r, subpids(r)

    # How each re-grafted node in this tree was attributed, so a surprising edge can be
    # questioned instead of taken on faith. Emitted per tree, after K, and safely
    # ignorable: a consumer that does not know the record type simply skips it.
    for (p in SRC) if (p in ALIVE && rootof(p) == r)
      printf "A\t%s\t%s\t%s\t%s\n", p, SRC[p], PP[p], ATSID[p]

    HSN = 0; hotspots(r, r)
    sortdesc(HS, HSN, "self")
    for (j = 1; j <= HSN && j <= 3; j++)
      printf "H\t%s\t%.1f\t%s\t%s\n", HS[j], SA[HS[j]], lab(HS[j]), chainof(r, HS[j])
    for (j in HS) delete HS[j]

    # Row budget: raise the visibility threshold until the tree fits. Beats truncating,
    # which would silently drop branches and leave dangling children.
    THR = tree_min
    for (j = 0; j < 12 && vcount(r, THR) > max_rows; j++) THR *= 2
    walk(r, r, "", "", 1, "")
  }

  # Causal database links are emitted after the forest so they cannot affect the
  # current R/K/H/T grouping. A live client and a live Docker root are both required;
  # stale lsof rows or a Docker restart therefore disappear harmlessly.
  if (DOCK != "") {
    for (i = 1; i <= DBN; i++) {
      p = DBPID[i]
      if (!(p in ALIVE) || p == DOCK || CMD[p] ~ /Docker\.app\/Contents\/MacOS\//) continue
      printf "D\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%s\t%s\n",
             p, DOCK, DBCID[i], DBCNAME[i], DBKIND[i], DBPORT[i],
             DBSOCK[i], DBCOUNT[i], lab(p), fullchain(p)
    }
  }
}
