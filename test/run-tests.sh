#!/bin/bash
# Headless tests for lib/tree.awk — the process-forest/energy-aggregation logic.
# No SwiftBar, no ps, no browser: everything runs off the TSV fixtures in fixtures/.
# Run:  test/run-tests.sh        (regenerate fixtures first with fixtures/gen.sh)

cd "$(dirname "$0")/.." || exit 1
export LC_ALL=C LANG=C
PASS=0; FAIL=0
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

# Every stop the suite performs would otherwise fire a real macOS banner. Routing them to
# a file keeps the run silent AND makes the feedback assertable.
export EM_NOTIFY_LOG="$TMPD/notify.log"; : > "$EM_NOTIFY_LOG"
notices() { cat "$EM_NOTIFY_LOG" 2>/dev/null; }
notices_reset() { : > "$EM_NOTIFY_LOG"; }

# tree <fixture-prefix> [extra awk -v args...]
tree() {
  local f=$1; shift
  local db="test/fixtures/$f.dbclients.tsv"
  [ -f "$db" ] || db=/dev/null
  local own="test/fixtures/$f.owners.tsv"
  [ -f "$own" ] || own=/dev/null
  local tabs="test/fixtures/$f.tabs.tsv"
  [ -f "$tabs" ] || tabs=/dev/null
  local att="test/fixtures/$f.attrib.tsv"
  [ -f "$att" ] || att=/dev/null
  awk "$@" -f lib/label.awk -f lib/tree.awk \
    "test/fixtures/$f.energy.tsv" "test/fixtures/$f.parents.tsv" \
    "test/fixtures/$f.procs.tsv" "$db" "$own" "$tabs" "$att"
}

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; }

# assert <name> <expected> <actual>
is() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

# assert the output contains a line matching a regex
has() { printf '%s\n' "$3" | grep -qE "$2" && ok "$1" || bad "$1" "match /$2/" "$(printf '%s' "$3" | head -3)"; }
hasnt() { printf '%s\n' "$3" | grep -qE "$2" && bad "$1" "no match /$2/" "$(printf '%s\n' "$3" | grep -E "$2" | head -2)" || ok "$1"; }

echo "== aggregation and ranking =="
OUT=$(tree basic -v me=alice -v allow='cmux|Chrome')
ROOTS=$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="R"{print $2"="$3}' | tr '\n' ' ')
# cmux 1.0 self + 20.0 claude + 0.1 caffeinate = 21.1, beating WindowServer 9.0 and Chrome 8.5.
# Ranking by the SUBTREE total is the whole point: cmux's own process is nearly idle.
is "roots ranked by subtree total" "100=21.1 300=9.0 200=8.5 " "$ROOTS"
is "subtree process count" "6" "$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="R"&&$2==100{print $5}')"
is "kill list is leaves-first" "105,104,103,102,101,100" "$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="K"&&$2==100{print $3}')"
is "tree rows carry subtree avg and now alongside own avg and now" "21.1 18.5 1.0 0.5" \
   "$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="T"&&$2==100{print $6, $7, $4, $5}')"

echo "== call chain =="
has "hotspot names the hog and its full chain" \
    '^H\t104\t20\.0\tclaude · e4cb37ec\tcmux › login › zsh › zsh · webapp$' "$OUT"
has "idle shell wrappers collapse into a via crumb" \
    '^T\t104\t.*\tclaude · e4cb37ec\tlogin › zsh › zsh · webapp\t' "$OUT"
hasnt "collapsed wrappers get no rows of their own" '^T\t(101|102|103)\t' "$OUT"
has "tree draws guides for real siblings" '^T\t201\t.*\t├─ \tChrome tab' "$OUT"
has "last sibling closes the branch" '^T\t202\t.*\t└─ \tChrome GPU' "$OUT"

echo "== plumbing=1 shows the raw chain =="
RAW=$(tree basic -v plumbing=1)
has "login is shown when plumbing is on" '^T\t101\t.*\tlogin\t' "$RAW"
has "chain indents one level per hop"    '^T\t104\t.*\t│  │  └─ |^T\t104\t.*   .*└─ ' "$RAW"

echo "== hog marking =="
is "the 20% claude under a 21% tree is a hog" "1" "$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="T"&&$2==104{print $8}')"
is "the 2% gpu helper is not"                  "0" "$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="T"&&$2==202{print $8}')"

echo "== mode flagging =="
FL=$(tree basic -v me=alice -v allow='Preview|Books')   # reading mode: no cmux, no Chrome
is "heavy own app not expected in this mode is flagged" "1" "$(printf '%s\n' "$FL" | awk -F'\t' '$1=="R"&&$2==100{print $7}')"
is "root-owned system process is never flagged"         "0" "$(printf '%s\n' "$FL" | awk -F'\t' '$1=="R"&&$2==300{print $7}')"
is "WindowServer marked SIP-critical"                   "1" "$(printf '%s\n' "$FL" | awk -F'\t' '$1=="R"&&$2==300{print $8}')"
is "allow-listed app is not flagged" "0" "$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="R"&&$2==100{print $7}')"

echo "== reparented orphans =="
ORP=$(tree orphan)
is "orphan re-grafted onto its remembered parent" "400=12.0" \
   "$(printf '%s\n' "$ORP" | awk -F'\t' '$1=="R"&&$2==400{print $2"="$3}')"
STALE=$(awk -f lib/label.awk -f lib/tree.awk test/fixtures/orphan.energy.tsv \
        test/fixtures/orphan-stale.parents.tsv test/fixtures/orphan.procs.tsv)
is "a recycled parent pid is refused (start time mismatch)" "402=12.0" \
   "$(printf '%s\n' "$STALE" | awk -F'\t' '$1=="R"&&$2==402{print $2"="$3}')"

echo "== automation browser ownership =="
# A hand-launched agent browser detaches to launchd faster than the sampler can see,
# so bin/browser-stamp records the owner at launch and tree.awk joins on the profile
# path. 700 is that browser (60.0 of subtree); 800 is the user's real Chrome.
BO=$(tree browserowner)
is "stamped browser is billed to the agent that launched it" "100=64.0" \
   "$(printf '%s\n' "$BO" | awk -F'\t' '$1=="R"&&$2==100{print $2"="$3}')"
is "the stamped browser is no longer a root of its own" "" \
   "$(printf '%s\n' "$BO" | awk -F'\t' '$1=="R"&&$2==700{print $2}')"
is "the user's real Chrome stays an independent root" "800=5.5" \
   "$(printf '%s\n' "$BO" | awk -F'\t' '$1=="R"&&$2==800{print $2"="$3}')"
has "an automation browser is named by its throwaway profile" \
    '^T\t700\t.*\tChrome auto · frames\t' "$BO"
has "the real browser keeps its ordinary name" '^R\t800\t.*\tGoogle Chrome\t' "$BO"
# Same profile path, owner pid recycled into a different process: the browser tree must
# stay put rather than being grafted onto a stranger that inherited the number.
BOS=$(awk -f lib/label.awk -f lib/tree.awk test/fixtures/browserowner.energy.tsv \
      test/fixtures/browserowner.parents.tsv test/fixtures/browserowner.procs.tsv \
      /dev/null test/fixtures/browserowner-stale.owners.tsv)
is "a recycled owner pid is refused (start time mismatch)" "700=60.0" \
   "$(printf '%s\n' "$BOS" | awk -F'\t' '$1=="R"&&$2==700{print $2"="$3}')"
# The whole point: with no stamp at all this is exactly what the menu showed — an
# anonymous browser outranking everything, indistinguishable from the real one.
BON=$(awk -f lib/label.awk -f lib/tree.awk test/fixtures/browserowner.energy.tsv \
      test/fixtures/browserowner.parents.tsv test/fixtures/browserowner.procs.tsv)
is "without a stamp the browser is an unattributed top-level root" "700=60.0" \
   "$(printf '%s\n' "$BON" | awk -F'\t' '$1=="R"&&$2==700{print $2"="$3}')"

# The agent-browser daemon detaches too, but its Chrome IS correctly parented to it —
# so one stamped row on the daemon carries the whole browser subtree to the session.
DO=$(tree daemonowner)
is "stamped agent-browser daemon is billed to its session" "100=37.0" \
   "$(printf '%s\n' "$DO" | awk -F'\t' '$1=="R"&&$2==100{print $2"="$3}')"
is "the daemon is no longer a root of its own" "" \
   "$(printf '%s\n' "$DO" | awk -F'\t' '$1=="R"&&$2==900{print $2}')"
has "the daemon's Chrome rides along under the same session" '^T\t910\t900\t' "$DO"
DOS=$(awk -f lib/label.awk -f lib/tree.awk test/fixtures/daemonowner.energy.tsv \
      test/fixtures/daemonowner.parents.tsv test/fixtures/daemonowner.procs.tsv \
      /dev/null test/fixtures/daemonowner-stale.owners.tsv)
# A refused stamp must not become a wrong answer: it degrades to the cmux fallback
# (drawn under 100) instead of the session it claimed (104).
is "a stamped session is used when the daemon start matches" "104" \
   "$(printf '%s\n' "$DO" | awk -F'\t' '$1=="T"&&$2==900{print $3}')"
is "a recycled daemon pid degrades to cmux, never to the claimed session" "100" \
   "$(printf '%s\n' "$DOS" | awk -F'\t' '$1=="T"&&$2==900{print $3}')"
# Unstamped, the daemon still reaches cmux — coarser, but never nothing.
DON=$(awk -f lib/label.awk -f lib/tree.awk test/fixtures/daemonowner.energy.tsv \
      test/fixtures/daemonowner.parents.tsv test/fixtures/daemonowner.procs.tsv)
is "unstamped, the daemon still falls back to cmux" "" \
   "$(printf '%s\n' "$DON" | awk -F'\t' '$1=="R"&&$2==900{print $2}')"

echo "== cmux tab names =="
# A session id is what the machine calls a session; the cmux tab title is what the human
# calls it, and only one of them says which work is eating a core. Fixture also uses a
# DEV BUNDLE name ("cmux Feature Branch.app") because matching "cmux.app"
# literally is a bug that silently emptied the whole agents section.
CT=$(tree cmuxtab)
has "an agent session is shown by its cmux tab title" '^T\t104\t.*\tclaude · Fix the tile cache warm-up\t' "$CT"
has "an agent cmux does not know keeps its session id" '^T\t106\t.*\tclaude · deadbeef\t' "$CT"
is "a dev-build cmux bundle still roots the tree" "100=30.0" \
   "$(printf '%s\n' "$CT" | awk -F'\t' '$1=="R"&&$2==100{print $2"="$3}')"
# Same names in the agents list, which labels through the shared helper rather than
# its own copy — the two must never disagree about what a session is called.
AG=$(awk -v agent_re='claude|codex' -f lib/label.awk -f lib/agents.awk \
     test/fixtures/cmuxtab.energy.tsv test/fixtures/cmuxtab.procs.tsv test/fixtures/cmuxtab.tabs.tsv)
has "agents list finds agents under a dev-build cmux bundle" '^104\t20\.0\t' "$AG"
has "agents list uses the same tab title" 'claude · Fix the tile cache warm-up' "$AG"
# Without the tabs file, everything must still work and simply fall back to ids.
CTN=$(awk -f lib/label.awk -f lib/tree.awk test/fixtures/cmuxtab.energy.tsv \
      test/fixtures/cmuxtab.parents.tsv test/fixtures/cmuxtab.procs.tsv)
has "no tabs file: labels fall back to session ids" '^T\t104\t.*\tclaude · 7ba7d89b\t' "$CTN"

echo "== parent memory (lib/parents.awk) =="
# Last cycle: cmux(400) -> shell(401) -> worker(402). Now 401 is gone and 402 has been
# handed to launchd. The memory must climb the dead link and re-anchor 402 onto 400.
PT=$(mktemp -d)
printf '401\tS2\t400\tS1\n402\tS3\t401\tS2\n' > "$PT/old.tsv"
printf '1\t0\troot\tS0\t/sbin/launchd\n400\t1\talice\tS1\t/Applications/cmux.app/Contents/MacOS/cmux\n402\t1\talice\tS3\tnode worker.js\n' > "$PT/now.tsv"
is "memory climbs past the dead parent to a living ancestor" $'402\tS3\t400\tS1' \
   "$(awk -f lib/parents.awk "$PT/old.tsv" "$PT/now.tsv" | grep '^402')"
# Same, but 400's pid has since been recycled by an unrelated process (different start).
printf '1\t0\troot\tS0\t/sbin/launchd\n400\t1\talice\tSX\t/usr/sbin/somethingelse\n402\t1\talice\tS3\tnode worker.js\n' > "$PT/recycled.tsv"
is "a recycled ancestor is not adopted" "" \
   "$(awk -f lib/parents.awk "$PT/old.tsv" "$PT/recycled.tsv" | grep '^402')"
is "a live parent is recorded directly" $'402\tS3\t400\tS1' \
   "$(printf '1\t0\troot\tS0\t/sbin/launchd\n400\t1\talice\tS1\tcmux\n402\t400\talice\tS3\tnode worker.js\n' > "$PT/direct.tsv"; awk -f lib/parents.awk /dev/null "$PT/direct.tsv" | grep '^402')"
rm -rf "$PT"

echo "== docker VM adoption =="
DOC=$(tree docker)
is "launchd-parented Docker VM folds into Docker" "600=14.5" \
   "$(printf '%s\n' "$DOC" | awk -F'\t' '$1=="R"{print $2"="$3}')"
is "DB socket emits a causal client-to-Docker link with the full caller chain" \
   "102 600 Postgres webapp-db-1 cmux › codex · 019fab0a › node api.js" \
   "$(printf '%s\n' "$DOC" | awk -F'\t' '$1=="D"{print $2, $3, $6, $5, $11}')"
DOC_FORCE=$(tree docker -v db_force=1)
is "graph mode keeps the otherwise-quiet DB client path visible" "600=14.5 100=0.0 " \
   "$(printf '%s\n' "$DOC_FORCE" | awk -F'\t' '$1=="R"{print $2"="$3}' | tr '\n' ' ')"
is "quiet Codex remains a semantic graph level instead of plumbing" "100 101 102" \
   "$(printf '%s\n' "$DOC_FORCE" | awk -F'\t' '$1=="T"&&($2==100||$2==101||$2==102){print $2}' | tr '\n' ' ' | sed 's/ $//')"
is "causal layout evidence does not add Docker CPU to the client tree" "0.0" \
   "$(printf '%s\n' "$DOC_FORCE" | awk -F'\t' '$1=="T"&&$2==100{print $6}')"
is "causal Docker is never added to the client tree kill list" "102,101,100" \
   "$(printf '%s\n' "$DOC_FORCE" | awk -F'\t' '$1=="K"&&$2==100{print $3}')"

echo "== Docker database client discovery =="
DBPARSED=$(awk -f lib/docker_clients.awk \
  test/fixtures/docker-ports.tsv test/fixtures/docker-lsof.fields \
  | sort -t"$(printf '\t')" -k1,1n)
is "published Postgres clients are mapped by host port and counted as ambiguous" \
   $'102\t50db7928634e\twebapp-db-1\tPostgres\t5432\t1\t2\n103\t50db7928634e\twebapp-db-1\tPostgres\t5432\t1\t2' \
   "$DBPARSED"
hasnt "Docker proxy and unrelated sockets are excluded" '^(600|700)\t' "$DBPARSED"

echo "== chrome instances =="
CHR=$(awk -f lib/chrome.awk test/fixtures/chrome.energy.tsv test/fixtures/chrome.procs.tsv)
is "only the browser you launched is listed as your tabs" "701 702" \
   "$(printf '%s\n' "$CHR" | awk -F'\t' '$1=="H"{print $2}' | sort -n | tr '\n' ' ' | sed 's/ $//')"
is "the automation instance is counted, not listed" "1" \
   "$(printf '%s\n' "$CHR" | awk -F'\t' '$1=="A"{print $2}')"
# the automation Chrome's 41.5% must land on the harness that launched it, under cmux,
# and must NOT inflate the Chrome you are browsing with
CTREE=$(tree chrome)
is "your Chrome carries only its own helpers" "700=6.5" \
   "$(printf '%s\n' "$CTREE" | awk -F'\t' '$1=="R"&&$2==700{print $2"="$3}')"
is "the automation Chrome is billed to its caller's tree" "800=42.5" \
   "$(printf '%s\n' "$CTREE" | awk -F'\t' '$1=="R"&&$2==800{print $2"="$3}')"
# the drill-down must read cmux -> node -> the automation Chrome -> its renderers
is "the call chain down to it is intact" "800 900 902 903 904" \
   "$(printf '%s\n' "$CTREE" | awk -F'\t' '$1=="T"{print $2}' | head -5 | tr '\n' ' ' | sed 's/ $//')"
is "the hotspot names it and its full chain" "cmux › node scrape.js › Google Chrome" \
   "$(printf '%s\n' "$CTREE" | awk -F'\t' '$1=="H"&&$2==903{print $5}')"

echo "== detached browser daemon ownership =="
DBTREE=$(tree daemon-browser)
is "detached agent-browser is billed to cmux while normal Chrome stays a root" "800=43.0 700=6.5 " \
   "$(printf '%s\n' "$DBTREE" | awk -F'\t' '$1=="R"{print $2"="$3}' | tr '\n' ' ')"
is "agent-browser is a direct child of cmux, not an invented CLI session" "800" \
   "$(printf '%s\n' "$DBTREE" | awk -F'\t' '$1=="T"&&$2==900{print $3}')"
is "automation Chrome remains under agent-browser" "900" \
   "$(printf '%s\n' "$DBTREE" | awk -F'\t' '$1=="T"&&$2==902{print $3}')"

echo "== graph json =="
is "fullscreen graph starts low enough to reveal meaningful deeper chains" "0.1" \
   "$(sed -n 's/.*id="min"[^>]*value="\([0-9.]*\)".*/\1/p' web/graph.html)"
GJ=$(awk -v top_n=99 -v max_rows=999 -v tree_min=0.3 -v root_min=0.3 \
      -f lib/label.awk -f lib/tree.awk \
      test/fixtures/chrome.energy.tsv test/fixtures/chrome.parents.tsv test/fixtures/chrome.procs.tsv \
     | python3 lib/graph_json.py)
is "every visible process becomes a node" "8" "$(printf '%s' "$GJ" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["nodes"]))')"
is "edges point at the drawn parent, not the raw ppid" "900" \
   "$(printf '%s' "$GJ" | python3 -c 'import json,sys; print([n["parent"] for n in json.load(sys.stdin)["nodes"] if n["pid"]=="902"][0])')"
is "roots carry an empty parent" "2" \
   "$(printf '%s' "$GJ" | python3 -c 'import json,sys; print(sum(1 for n in json.load(sys.stdin)["nodes"] if n["parent"]==""))')"
is "peak is the heaviest single process, not a subtree total" "30.0" \
   "$(printf '%s' "$GJ" | python3 -c 'import json,sys; print(json.load(sys.stdin)["peak"])')"
is "graph json carries the instantaneous subtree total" "42.5" \
   "$(printf '%s' "$GJ" | python3 -c 'import json,sys; print([n["sub_now"] for n in json.load(sys.stdin)["nodes"] if n["pid"]=="800"][0])')"
DGJ=$(printf '%s\n' "$DOC_FORCE" | python3 lib/graph_json.py)
is "graph json keeps causal DB links separate from process parent fields" "102 600 database-client" \
   "$(printf '%s' "$DGJ" | python3 -c 'import json,sys; x=json.load(sys.stdin)["links"][0]; print(x["source"],x["target"],x["kind"])')"
is "Docker remains a real root in JSON before the UI applies causal layout" "" \
   "$(printf '%s' "$DGJ" | python3 -c 'import json,sys; print([n["parent"] for n in json.load(sys.stdin)["nodes"] if n["pid"]=="600"][0])')"
# a command line full of quotes and braces must survive into valid JSON
is "hostile command lines survive JSON encoding" "ok" \
   "$(printf '1\t0\troot\tS0\t/sbin/launchd\n900\t1\talice\tS1\tnode --eval {\"a\":\"b\\\\c\"} \xc3\xa9\n' > /tmp/em-hostile.tsv
      printf '900\t9.0\t9.0\n' > /tmp/em-hostile-e.tsv; : > /tmp/em-hostile-p.tsv
      awk -f lib/label.awk -f lib/tree.awk /tmp/em-hostile-e.tsv /tmp/em-hostile-p.tsv /tmp/em-hostile.tsv \
        | python3 lib/graph_json.py | python3 -c 'import json,sys; json.load(sys.stdin); print("ok")'
      rm -f /tmp/em-hostile*.tsv)"

echo "== row budget =="
# 60 heavy siblings under one root must not emit 60 rows; the threshold self-raises.
BIG=$(mktemp -d)
{ printf '1\t0\troot\tS0\t/sbin/launchd\n'; printf '700\t1\talice\tS1\t/Applications/Big.app/Contents/MacOS/Big\n'
  for i in $(seq 1 60); do printf '%s\t700\talice\tS%s\tworker %s\n' "$((800+i))" "$i" "$i"; done; } > "$BIG/big.procs.tsv"
{ for i in $(seq 1 60); do printf '%s\t%s.0\t1.0\n' "$((800+i))" "$i"; done; } > "$BIG/big.energy.tsv"
: > "$BIG/big.parents.tsv"
NROWS=$(awk -v max_rows=24 -f lib/label.awk -f lib/tree.awk "$BIG/big.energy.tsv" "$BIG/big.parents.tsv" "$BIG/big.procs.tsv" | grep -c '^T')
[ "$NROWS" -le 24 ] && [ "$NROWS" -gt 1 ] && ok "60 siblings pruned to $NROWS rows (<= 24)" \
  || bad "row budget respected" "2..24 rows" "$NROWS"
rm -rf "$BIG"

echo "== labelling =="
# label <command line>
label() { printf '%s\n' "$1" | awk -f lib/label.awk -f <(echo '{ print mklabel($0) }'); }
is "app bundle beats argv[0] when the binary name has a space" "Google Chrome" \
   "$(label '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')"
is "browser helper named by its role" "Chrome tab" \
   "$(label '/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper --type=renderer')"
is "agent named by its session"  "claude · e4cb37ec" "$(label '/Users/alice/.local/bin/claude --session-id e4cb37ec-72b5-4fe2-85b1-784c6ded7fc9')"
is "project shell named by project" "zsh · webapp" "$(label "/bin/zsh -lic cd -- '/Users/alice/Code/webapp' 2>/dev/null")"
is "node named by its script"    "node worker.js" "$(label 'node /Users/alice/Code/thing/worker.js')"
is "ssh named by its host"       "ssh valhalla"   "$(label 'ssh -t valhalla tmux new -A -s codex')"
is "docker VM recognised"        "Docker VM"      "$(label '/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine')"
is "docker helpers keep their subcommand" "Docker services" \
   "$(label '/Applications/Docker.app/Contents/MacOS/com.docker.backend services')"
is "bare docker backend is just Docker" "Docker" \
   "$(label '/Applications/Docker.app/Contents/MacOS/com.docker.backend')"
is "other com.docker binaries keep their name" "Docker virtualization" \
   "$(label '/Applications/Docker.app/Contents/MacOS/com.docker.virtualization --kernel /Applications/Docker.app/Contents/Resources/linuxkit/kernel')"
is "agent-browser architecture suffix is hidden" "agent-browser" \
   "$(label '/Users/alice/.nvm/bin/agent-browser-darwin-arm64')"
is "plain daemon keeps its basename" "WindowServer" \
   "$(label '/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer -daemon')"

echo "== owners the OS still knows (lib/attribution.py) =="
# Playwright never calls browser-stamp, so there is no launch record at all — the only
# evidence is the environment the browser inherited, which survives reparenting.
EA=$(tree envattrib)
is "an unstamped browser is billed by its inherited environment" "100=46.0" \
   "$(printf '%s\n' "$EA" | awk -F'\t' '$1=="R"&&$2==100{print $2"="$3}')"
is "it is no longer a root of its own" "" \
   "$(printf '%s\n' "$EA" | awk -F'\t' '$1=="R"&&$2==600{print $2}')"
has "the attribution path is recorded, not silently assumed" '^A\t600\tenv\t104\t' "$EA"
# Same guard as every other adoption: a claimed owner whose start time no longer matches
# has been recycled into a different process, and inheriting a browser tree onto a
# stranger is worse than leaving it unattributed.
EAS=$(awk -f lib/label.awk -f lib/tree.awk test/fixtures/envattrib.energy.tsv \
      test/fixtures/envattrib.parents.tsv test/fixtures/envattrib.procs.tsv \
      /dev/null /dev/null /dev/null test/fixtures/envattrib-stale.attrib.tsv)
is "a recycled owner pid is refused (start time mismatch)" "600=43.0" \
   "$(printf '%s\n' "$EAS" | awk -F'\t' '$1=="R"&&$2==600{print $2"="$3}')"
# Ordering matters: a witnessed parent edge outranks an inherited environment variable,
# which outranks the coarse cmux fallback.
ORD=$(printf '%s\n' "$(tree browserowner)" | awk -F'\t' '$1=="A"&&$2==700{print $3}')
is "a launch stamp outranks everything below it" "stamp" "$ORD"

echo "== coding agents =="
# Rooting the search at cmux alone left this section empty for everyone not using it,
# while the README claimed the tool was general. Any terminal emulator is a root now.
TA=$(awk -v agent_re='claude|codex' -f lib/label.awk -f lib/agents.awk \
     test/fixtures/termagent.energy.tsv test/fixtures/termagent.procs.tsv /dev/null | sort)
is "an agent under a plain terminal is found, not only under cmux" \
   "202 claude · aaaaaaaa
301 codex" \
   "$(printf '%s\n' "$TA" | awk -F'\t' '{print $1, $3}')"
AG=$(awk -v agent_re='claude|codex' -f lib/label.awk -f lib/agents.awk \
     test/fixtures/basic.energy.tsv test/fixtures/basic.procs.tsv)
is "an agent is found by walking the tree, not by matching its name" "104	claude · e4cb37ec" \
   "$(printf '%s\n' "$AG" | awk -F'\t' '{print $1"\t"$3}')"

echo "== one definition of "automation browser" =="
# The same predicate is implemented three times, in three languages: lib/label.awk (to
# name it "Chrome auto"), lib/cdp.sh (to read its pages) and bin/browser-reap (to decide
# it may be KILLED). Their comments say they must never disagree; nothing enforced that.
# A drift where the reaper is broader than the labeller means killing something the menu
# called an ordinary browser — so the agreement is the safety property, not the regex.
CH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
while IFS='|' read -r want cmd; do
  [ -z "$want" ] && continue
  a=$(printf 'BEGIN{ print (udd("%s") != "") ? "yes" : "no" }\n' "$cmd" > "$TMPD/u.awk"
      awk -f lib/label.awk -f "$TMPD/u.awk" </dev/null)
  r=$(printf '1\t1\talice\tS1\t%s\n' "$cmd" > "$TMPD/p.tsv"
      . lib/cdp.sh
      awk -F'\t' '
        $5 ~ /--user-data-dir=/ && $5 ~ /[Cc]hrom|headless_shell/ {
          d = $5; sub(/^.*--user-data-dir=/, "", d); sub(/ .*$/, "", d); sub(/\/+$/, "", d)
          if (d ~ /^(\/private)?\/(tmp|var\/folders)\//) { print "yes"; f=1 }
        } END { if (!f) print "no" }' "$TMPD/p.tsv")
  b=$(printf '%s' "$cmd" | grep -- '--user-data-dir=' | grep -Ei 'chrom|headless_shell' \
      | sed 's/^.*--user-data-dir=//; s/ .*$//' \
      | awk '{ print ($0 ~ /^(\/private)?\/(tmp|var\/folders)\//) ? "yes" : "no" }')
  [ -z "$b" ] && b=no
  is "labeller/cdp/reaper agree: $(printf '%.34s' "${cmd#/Applications/}")" "$want $want $want" "$a $r $b"
done <<LIST
yes|$CH --user-data-dir=/tmp/agent-chrome/1-x
yes|$CH --user-data-dir=/var/folders/9r/T/pw-profile
yes|/opt/homebrew/bin/chrome-headless-shell --user-data-dir=/private/tmp/x
no|$CH
no|$CH --user-data-dir=/Users/alice/Library/Application Support/Google/Chrome
no|/Applications/Firefox.app/Contents/MacOS/firefox -profile /tmp/ff
LIST

echo "== menu injection =="
# A SwiftBar line is "text | key=value", and parameters start at the FIRST "|" — so a
# bare "|" in a process name or window title becomes bash=/param1=, i.e. a menu row that
# runs a command when clicked. Both are attacker-controlled (any web page sets
# document.title; anything can exec with a chosen argv[0]). This was verified exploitable
# end-to-end before msafe() existed, so these guard a real hole, not a theoretical one.
HOS=$(tree hostile)
hasnt "a pipe in a process name never reaches a label" '\|' \
      "$(printf '%s\n' "$HOS" | awk -F'\t' '$1=="R"{print $9}')"
hasnt "a pipe in a cmux tab title never reaches a label" '\|' \
      "$(printf '%s\n' "$HOS" | awk -F'\t' '$1=="T"{print $10}')"
has "the payload is defanged into inert text, not silently dropped" 'my tab ¦ bash=' \
    "$(printf '%s\n' "$HOS" | awk -F'\t' '$1=="T"&&$2==104{print $10}')"

SHFUNCS='eval "$(sed -n "/^msafe()/,/^}$/p;/^trunc()/,/^)$/p" plugins/energy.10s.sh)"'
is "the shell boundary defangs a pipe" "a ¦ b" "$(bash -c "$SHFUNCS"'; msafe "a | b"')"
is "trunc sanitises before truncating" "x ¦ bash=y" "$(bash -c "$SHFUNCS"'; trunc "x | bash=y" 40')"

CDPEVIL=$(. lib/cdp.sh; printf '[ {\n "title": "Evil | bash=/tmp/x",\n "type": "page",\n "url": "http://a/"\n} ]\n' | em_cdp_parse /tmp/p)
hasnt "a page title cannot inject menu parameters" '\| bash=' "$CDPEVIL"


# The publish guard is the last line of defence: even if a future edit forgets to
# sanitise, a payload carrying an action we did not write must not reach SwiftBar.
GUARD='awk -F"\\|" -v repo="/repo/" '"'"'
   NF > 1 { p = $NF
     while (match(p, /(^|[ \t])(bash|shell|href)=/)) {
       p = substr(p, RSTART + RLENGTH); v = p; sub(/[ \t].*$/, "", v); gsub(/^"|"$/, "", v)
       if (v != "/usr/bin/open" && index(v, repo) != 1) exit 1
     } }'"'"''
printf 'row | bash="/repo/plugins/energy.10s.sh" param1=stop\nopen | bash=/usr/bin/open\n' > "$TMPD/clean.menu"
printf 'row | color=gray\nevil | bash="/usr/bin/touch" param1=/tmp/pwned\n'               > "$TMPD/poison.menu"
eval "$GUARD" "$TMPD/clean.menu"  && ok "the publish guard passes a payload we wrote" \
                                  || bad "the publish guard passes a payload we wrote" "exit 0" "exit 1"
eval "$GUARD" "$TMPD/poison.menu" && bad "the publish guard blocks a foreign action" "exit 1" "exit 0" \
                                  || ok "the publish guard blocks a foreign action"

echo "== automation browser pages (CDP) =="
# Chrome pretty-prints /json/list, so the pages can be read without a JSON parser and
# without paying for a python start on every render.
CDPJSON='[ {
   "description": "",
   "title": "Build dashboard",
   "type": "page",
   "url": "http://localhost:8080/station.html"
}, {
   "title": "service worker",
   "type": "service_worker",
   "url": "http://localhost:8080/sw.js"
} ]'
CDPOUT=$(. lib/cdp.sh; printf '%s\n' "$CDPJSON" | em_cdp_parse /tmp/prof-1)
is "a page is reported with its profile, title and url" \
   "/tmp/prof-1	Build dashboard	http://localhost:8080/station.html" "$CDPOUT"
hasnt "non-page targets are not listed as tabs" 'service worker' "$CDPOUT"

echo "== stopping… (a signalled process must not look untouched) =="
# A stop notifies immediately and closes the menu, but the process can take seconds to go.
# Reopening the menu then shows a row identical to one never signalled, and it gets
# stopped again. These guard the state that stops that happening — with a real process,
# because the whole mechanism is about liveness.
STOPFUNCS='eval "$(sed -n "/^em_pid_start()/,/^}$/p;/^em_mark_stopping()/,/^}$/p;/^em_stopping_live()/,/^}$/p" plugins/energy.10s.sh)"'
stopenv() { bash -c "STATE_DIR=$TMPD/st; STOPPING=$TMPD/st/stopping.tsv; STOPPING_TTL=\${TTL:-300}; mkdir -p \$STATE_DIR; $STOPFUNCS"'; '"$1"; }

sleep 30 & LIVEPID=$!
is "a signalled process is listed while it is still alive" "$LIVEPID" \
   "$(stopenv 'em_mark_stopping '"$LIVEPID"'; em_stopping_live')"
is "listing it twice does not duplicate the row" "$LIVEPID" \
   "$(stopenv 'em_mark_stopping '"$LIVEPID"'; em_stopping_live >/dev/null; em_stopping_live')"
kill -9 "$LIVEPID" 2>/dev/null; wait "$LIVEPID" 2>/dev/null
is "once it exits it stops being listed" "" \
   "$(stopenv 'em_stopping_live')"

# Pids are reused. Without the start-time check a recycled pid inherits "stopping…" and
# the row lies about a process nobody touched.
sleep 30 & REUSED=$!
is "a pid whose start time no longer matches is not listed" "" \
   "$(stopenv 'printf "%s\t%s\t%s\n" '"$REUSED"' NOT_THE_SAME_START $(date +%s) > $STOPPING; em_stopping_live')"
is "an entry older than the TTL is forgotten" "" \
   "$(TTL=1 stopenv 'em_mark_stopping '"$REUSED"'; sed -i.bak "s/\t[0-9]*$/\t1/" $STOPPING; em_stopping_live')"
kill -9 "$REUSED" 2>/dev/null; wait "$REUSED" 2>/dev/null

# The awk half of the same test: rows and their actions both have to react.
AWKTAG='function dying(pid) { return index(stopping, "," pid ",") > 0 }
        function tag(pid) { return dying(pid) ? "  · stopping…" : "" }
        BEGIN { printf "%s|%s|%d\n", tag(101), tag(999), dying(101) }'
is "awk tags only the pids in the stopping set" "  · stopping…||1" \
   "$(awk -v stopping=",101,102," "$AWKTAG" </dev/null)"

echo "== periodic advisor =="
ADVOUT=$(python3 test/test_advisor.py 2>&1); ADVRC=$?
[ "$ADVRC" -eq 0 ] && ok "sanitization, focus metadata, triggers, dedupe and launch-agent tests" \
  || bad "advisor unit tests" "unittest success" "$ADVOUT"
ATTOUT=$(python3 test/test_attribution.py 2>&1); ATTRC=$?
[ "$ATTRC" -eq 0 ] && ok "attribution signal order, owner guards and env whitelist" \
  || bad "attribution unit tests" "unittest success" "$ATTOUT"
has "SwiftBar keeps the monitor visible across transient empty refreshes" \
    '^# <swiftbar\.alwaysVisible>true</swiftbar\.alwaysVisible>$' \
    "$(head -10 plugins/energy.10s.sh)"
has "SwiftBar receives an atomic render and retains the last good menu" \
    'ENERGY_RENDER_CHILD.*menu\.last|menu\.last.*ENERGY_RENDER_CHILD' \
    "$(tr '\n' ' ' < plugins/energy.10s.sh)"
has "SwiftBar transport is guaranteed valid UTF-8" \
    'iconv -c -f UTF-8 -t UTF-8' \
    "$(tr '\n' ' ' < plugins/energy.10s.sh)"
has "SwiftBar keeps timestamped alerts available after the banner is gone" \
    'Alerts — last.*stamp.*title' \
    "$(tr '\n' ' ' < plugins/energy.10s.sh)"
has "termination actions request a persistent SwiftBar menu" \
    'param1=stop.*keepopen=true' \
    "$(tr '\n' ' ' < plugins/energy.10s.sh)"

echo "== stopping a process =="
# SIGTERM and SIGKILL were two menu items, which made the user perform the escalation by
# hand. One action now does both in order. Tested by behaviour, not by grepping for the
# signal name: what matters is that the process is gone either way.
notices_reset
sleep 30 & POLITE=$!; disown 2>/dev/null
EM_STOP_PATIENCE=3 bash plugins/energy.10s.sh stop x "$POLITE" >/dev/null 2>&1
sleep 0.2
kill -0 "$POLITE" 2>/dev/null && bad "a well-behaved process stops on SIGTERM" "gone" "alive" \
  || ok "a well-behaved process stops on SIGTERM"

# SwiftBar closes the menu the moment a bash= row runs, so a stop that says nothing is
# indistinguishable from a stop that did nothing — the exact reading that got a working
# button reported as broken. A clean stop reports once, and names the process the way the
# row did rather than by pid.
POLITE_NOTES=$(notices)
is "a clean stop reports exactly once" "1" "$(printf '%s\n' "$POLITE_NOTES" | grep -c .)"
has "and says what it stopped, by name" '^Stopped sleep\b' "$POLITE_NOTES"

# A process that ignores SIGTERM is exactly why SIGKILL exists; the escalation must
# reach it without the user choosing anything.
STUB=$(mktemp -t emstub); printf '#!/bin/bash\ntrap "" TERM\nwhile :; do sleep 1; done\n' > "$STUB"
chmod +x "$STUB"; "$STUB" & STUBBORN=$!; disown 2>/dev/null
sleep 0.3
EM_STOP_PATIENCE=3 bash plugins/energy.10s.sh stop x "$STUBBORN" >/dev/null 2>&1
sleep 0.2
kill -0 "$STUBBORN" 2>/dev/null && bad "a process ignoring SIGTERM is escalated to SIGKILL" "gone" "alive" \
  || ok "a process ignoring SIGTERM is escalated to SIGKILL"
kill -9 "$STUBBORN" 2>/dev/null; rm -f "$STUB"

# A stop that escalates can take 2.5s. It must acknowledge the click BEFORE that, then
# report the outcome — and must not claim a clean stop when it had to force one.
STUB_NOTES=$(notices)
has  "a slow stop acknowledges the click first" '^Stopping ' "$STUB_NOTES"
has  "and reports that it had to force the kill" '^Force-stopped ' "$STUB_NOTES"
hasnt "and never calls a forced kill a clean stop" '^Stopped bash' "$STUB_NOTES"

# The whole point of the gpu/utility split: stopping a shared service is not a stop, and
# saying "Stopped" would repeat the lie the menu row used to tell.
notices_reset
GSTUB=$(mktemp -t emgpu); printf '#!/bin/bash\nwhile :; do sleep 1; done\n' > "$GSTUB"
chmod +x "$GSTUB"; "$GSTUB" --type=gpu-process & GSVC=$!; disown 2>/dev/null
sleep 0.3
EM_STOP_PATIENCE=3 bash plugins/energy.10s.sh stop x "$GSVC" >/dev/null 2>&1
GSVC_NOTES=$(notices)
has  "stopping a shared service reports a restart, not a stop" '^Restarted ' "$GSVC_NOTES"
has  "and says the load returns with the tabs" 'load comes back' "$GSVC_NOTES"
kill -9 "$GSVC" 2>/dev/null; rm -f "$GSTUB"

# A process names itself, so a name is untrusted input on its way into a URL query.
# "&body=" must not be able to rewrite the notification it appears in.
# Lifted out rather than sourced: sourcing the plugin renders a whole menu.
ENC=$(bash -c 'eval "$(sed -n "/^urlenc() (/,/^)\$/p" plugins/energy.10s.sh)"; urlenc "evil&body=x ⚡"')
is "a hostile process name cannot forge query parameters" \
   "evil%26body%3Dx%20%E2%9A%A1" "$ENC"

echo "== shared browser services never take the hotspot slot =="
# The GPU process is where every tab's work lands, so it routinely outweighs any single
# renderer (real measurement: 84.3% vs 48.9%). Naming it as the hotspot points the user at
# the one process that cannot be the cause: it is shared, and the browser respawns it
# within milliseconds of a kill. The renderer must win the slot even at less than half
# the cost, and the services must still be reported behind it.
GH=$(tree gpuhot -v me=alice -v allow='Chrome')
HOTS=$(printf '%s\n' "$GH" | awk -F'\t' '$1=="H"{print $4}' | tr '\n' ' ')
is "the renderer wins the hotspot slot over a 2.25x heavier GPU service" \
   "Chrome tab Chrome GPU Chrome utility " "$HOTS"
is "the consumer's '→' would name the tab" \
   "Chrome tab" "$(printf '%s\n' "$GH" | awk -F'\t' '$1=="H"{print $4; exit}')"
has "the GPU service is still reported, with its real cost" \
    '^H\t202\t90\.0\tChrome GPU' "$GH"

echo "== an ungranted Chrome asks for permission, not for it back =="
# The tab-name gate is a marker file, and the guards around it used a bare "return",
# which propagates the guard's OWN status. With the caller now reading that status as
# "the permission was withdrawn", a never-granted install would accuse macOS of revoking
# a grant it never had. Needs a real Chrome, so it skips rather than lies on CI.
if pgrep -x "Google Chrome" >/dev/null 2>&1; then
  # First render on an empty state dir has no prior sample and reports "collecting…",
  # so prime the history before asserting on the Chrome section.
  STATE_DIR="$TMPD/fresh" bash plugins/energy.10s.sh >/dev/null 2>&1
  FRESH=$(STATE_DIR="$TMPD/fresh" bash plugins/energy.10s.sh 2>/dev/null)
  has  "a first run offers the enable prompt"        'Enable tab names' "$FRESH"
  hasnt "a first run claims nothing was withdrawn"   'withdrew Automation' "$FRESH"

  # Automation is granted per calling app, so this suite is refused where SwiftBar is
  # allowed. A run outside SwiftBar must therefore never retract the marker — otherwise
  # running the tests, or the plugin by hand once, silently destroys the user's grant.
  mkdir -p "$TMPD/granted"; touch "$TMPD/granted/chrome-ok"
  STATE_DIR="$TMPD/granted" bash plugins/energy.10s.sh >/dev/null 2>&1
  STATE_DIR="$TMPD/granted" bash plugins/energy.10s.sh >/dev/null 2>&1
  [ -f "$TMPD/granted/chrome-ok" ] \
    && ok "a run outside SwiftBar leaves the Automation grant alone" \
    || bad "a run outside SwiftBar leaves the Automation grant alone" "marker kept" "marker deleted"
else
  echo "  skip Google Chrome is not running"
fi

echo
if [ "$FAIL" -gt 0 ]; then echo "FAILED: $FAIL failed, $PASS passed"; exit 1; fi
echo "PASSED: $PASS assertions"
