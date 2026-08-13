#!/bin/bash
# <swiftbar.alwaysVisible>true</swiftbar.alwaysVisible>
# mac-energy-manager: a SwiftBar/xbar menu-bar plugin giving a granular, always-visible
# view of what is draining battery, with one-click kill/stop for processes, cmux
# coding-agents (claude/codex/copilot/...), Chrome tabs, and macOS power subsystems.
#
# Filename suffix ".10s." tells SwiftBar to refresh every 10 seconds. Do NOT go
# lower: a render that takes longer than the interval overlaps the next one, and
# SwiftBar cancels the older operation and DISCARDS its output entirely.
# The same script also serves as its own action handler: menu items invoke it with
# a subcommand (act / chrome-close / caffkill / open) so everything lives in one file.

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH"
# Byte-oriented locale so awk never chokes on non-ASCII process names ("towc" errors).
# Our echoed UTF-8 icons still pass through as raw bytes for SwiftBar to render.
export LC_ALL=C LANG=C
# Locate the repo from this script's own path, following symlinks, so the usual
# install — a symlink to this file dropped into whatever plugin folder SwiftBar is
# already using — works without editing anything. Repointing SwiftBar's PluginDirectory
# at this repo would disable every other plugin the user has.
# Resolved by hand rather than with `readlink -f`, which is GNU-only on older macOS.
SELF="$0"
while [ -L "$SELF" ]; do
  link="$(readlink "$SELF")"
  case "$link" in
    /*) SELF="$link" ;;
     *) SELF="$(dirname "$SELF")/$link" ;;
  esac
done
SELF="$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")"
REPO="$(dirname "$(dirname "$SELF")")"
TREE_AWK="$REPO/lib/tree.awk"   # process-forest + energy aggregation (pure; see test/)

# ---- configurable knobs -----------------------------------------------------
TOP_N=12          # how many top-level processes to list in the energy section
WINDOW=600        # rolling-history window in seconds (~10 min) for the average column
                  # (also consumed by lib/snapshot.sh, sourced below)
ROOT_MIN=1        # a top-level process below this never gets a row: the tail of the list
                  # was always logd/opendirectoryd/launchd at well under 1%, which is the
                  # machine idling rather than anything you would act on. The fullscreen
                  # graph has its own slider and still starts at 0.1, so nothing is lost.
TREE_MIN=0.3      # hide subtrees costing less than this (they are noise, not spend)
                  # NOTE: separate from ROOT_MIN on purpose. This one governs rows INSIDE
                  # an open call tree, where a 0.4% child is context for its parent's
                  # number rather than a candidate for killing.
ELIDE_MAX=0.5     # a link this cheap is plumbing: collapse it into a "via" crumb
HOG_MIN=3         # self-cost that makes a node a hotspot inside its tree
MAX_TREE_ROWS=24  # per-tree row budget; the threshold self-raises to fit
AGENT_MIN=0.5     # hide agent tabs quieter than this: an open tab waiting on you costs
AGENT_MAX=8       # nothing, and a dozen 0.0% rows bury the one agent actually working
AGENT_REGEX='claude|codex|copilot|aider|cursor-agent|gemini|goose|cline|amp|opencode|ollama'
                  # known coding-agent binaries. NOT exhaustive and NOT the only
                  # detection path: any heavy descendant of cmux is shown regardless
                  # of name. Edit this list freely to label more agents nicely.

# rolling-history state (kept small: pruned to WINDOW every cycle). STATE_DIR, HIST,
# CUR, PARENTS and the em_procs/em_energy readers are shared with the graph view.
. "$REPO/lib/snapshot.sh"
. "$REPO/lib/docker_clients.sh"
. "$REPO/lib/cdp.sh"

# SwiftBar 2.1 can occasionally finish this fairly large render successfully yet
# retain an empty stdout value. That leaves the live number in the status item but
# replaces our dropdown with SwiftBar's generic menu. Isolate the real render in a
# child whose stdout goes to a regular file, then publish the completed payload in
# one pass. A failed/empty refresh reuses the last good payload, so neither a brief
# collector failure nor SwiftBar's capture path can destroy the working menu.
if [ -z "${ENERGY_RENDER_CHILD:-}" ] && [ "$#" -eq 0 ]; then
  mkdir -p "$STATE_DIR"
  MENU_LAST="$STATE_DIR/menu.last"
  MENU_NEW="$STATE_DIR/menu.render.$$"
  MENU_CLEAN="$STATE_DIR/menu.render.$$.utf8"
  WRAPPER_PARENT_PID=$(ps -o ppid= -p $$ | tr -d ' ')
  trap 'rm -f "$MENU_NEW" "$MENU_CLEAN"' EXIT

  if ENERGY_RENDER_CHILD=1 ENERGY_SWIFTBAR_PID="$WRAPPER_PARENT_PID" \
       /bin/bash "$SELF" > "$MENU_NEW" && [ -s "$MENU_NEW" ]; then
    # SwiftBar converts the whole payload with strict UTF-8 decoding. Process names
    # and browser titles are external input; one malformed byte would otherwise turn
    # the complete menu into an empty string. Drop only malformed transport bytes.
    /usr/bin/iconv -c -f UTF-8 -t UTF-8 "$MENU_NEW" > "$MENU_CLEAN"
    [ -s "$MENU_CLEAN" ] || cp "$MENU_NEW" "$MENU_CLEAN"
    # LAST LINE OF DEFENCE. Every row that can RUN something must point at this repo or
    # at /usr/bin/open — those are the only executables this menu ever invokes. Process
    # names and window titles are attacker-controlled and a SwiftBar line takes its
    # parameters from the first "|" onwards, so a single unsanitised string is a menu
    # item that runs someone else's command on click. lib/label.awk's msafe() and
    # trunc() stop that at the source; this refuses to PUBLISH a payload where it
    # happened anyway. A future edit that forgets to sanitise now breaks visibly instead
    # of quietly becoming an exploit.
    if ! awk -F'\\|' -v repo="$REPO/" '
           NF > 1 {
             p = $NF
             while (match(p, /(^|[ \t])(bash|shell|href)=/)) {
               p = substr(p, RSTART + RLENGTH)
               v = p; sub(/[ \t].*$/, "", v); gsub(/^"|"$/, "", v)
               if (v != "/usr/bin/open" && index(v, repo) != 1) { print NR; exit 1 }
             }
           }' "$MENU_CLEAN" >/dev/null; then
      echo "⚡!"
      echo "---"
      echo "render blocked: a menu row carried an action this plugin did not write | color=red"
      echo "This is the injection guard. Please report it with the process list. | size=11 color=gray"
      echo "Refresh | refresh=true"
      exit 0
    fi
    mv "$MENU_CLEAN" "$MENU_LAST"
    cat "$MENU_LAST"
  elif [ -s "$MENU_LAST" ]; then
    cat "$MENU_LAST"
  else
    echo "⚡…"
    echo "---"
    echo "menu refresh produced no output | color=orange"
    echo "Refresh | refresh=true"
  fi
  exit 0
fi

MODE_FILE="$STATE_DIR/mode"      # current activity mode (reading|coding|surfing|...)
SNAP="$STATE_DIR/cputime.prev"   # previous render's cumulative-cputime snapshot
SNAP_T="$STATE_DIR/cputime.epoch"  # when that snapshot was taken
PLUMB_FILE="$STATE_DIR/plumbing" # "1" = show every link in the chain, wrappers included
OWNERS="$STATE_DIR/browser-owners.tsv"  # automation browser -> who launched it (bin/browser-stamp)
TABS="$STATE_DIR/cmux-tabs.tsv"         # agent session id -> the name you gave that cmux tab
# Processes that have been signalled but have not exited yet. A stop notifies immediately
# and the menu closes, so the next time the menu opens a still-dying process looks exactly
# like one that was never signalled — and gets stopped again. Rows for these say so.
# pid<TAB>start<TAB>signalled_epoch; start is carried because pids are reused.
STOPPING="$STATE_DIR/stopping.tsv"
STOPPING_TTL=${EM_STOPPING_TTL:-300}    # after this, stop claiming it is on its way out
# SAMPLING DESIGN: no `top`, no background collector. `top -l 2` takes ~2.2s (SwiftBar
# times slow plugins out and never shows the icon) and HANGS without a tty, and SwiftBar
# kills plugin-spawned children, so a collector can't live anywhere reliable. Instead,
# each render diffs every process's cumulative CPU time (ps cputime, ~100ms, headless-
# safe) against the previous render: cpu% = delta-cputime / delta-wallclock. Each
# SwiftBar refresh IS the sampler. Metric is true CPU% over the interval, a good energy
# proxy (we measured it tracking top's Energy Impact within ~1% for real apps).

# ---- ACTIVITY MODES ---------------------------------------------------------
# Each mode declares which app/process basenames are EXPECTED for that activity.
# Anything the current user is running that is (a) heavy enough (avg >= FLAG_MIN) and
# (b) NOT in the mode's allow-list gets flagged as "not needed right now", with a
# one-click Stop/Kill. System/root processes are never flagged (only your own apps).
# Extend by adding a mode here and a case in mode_allow(). Matching is on the process
# basename, case-insensitive, as an extended-regex anchored to the whole name.
FLAG_MIN=3        # only flag processes whose 10-min avg energy is at least this
mode_allow() {
  case "$1" in
    reading)  echo 'Preview|Books|Kindle|Skim|PDF ?Expert|MarginNote|Zathura|Notes|iBooks' ;;
    coding)   echo 'cmux|claude|codex|copilot|node|deno|bun|Code ?H?e?l?p?e?r?|Code|Cursor|Zed|ghostty|iTerm2?|Terminal|Warp|Alacritty|kitty|Xcode|Simulator|Docker|com.docker|com.apple.Virtualization|git|zsh|bash|Safari|Google Chrome|Brave|Arc|Firefox' ;;
    surfing)  echo 'Safari|Google Chrome|Brave|Arc|Firefox|Chromium' ;;
    *)        echo '' ;;   # unknown mode -> allow nothing (flags all heavy user apps)
  esac
}

# =============================================================================
# ACTION HANDLERS  (called back by menu clicks; they do work then exit)
#
# These are the only part of this tool that takes an argument and then does something
# irreversible — signalling processes, closing tabs, writing state. Everything they are
# given is validated against a whitelist rather than trusted, even though the only
# intended caller is our own rendered menu: the menu is regenerated from process names
# and window titles, both attacker-controlled, and "the caller is us" stops being true
# the moment a rendering bug lets external text through. Least privilege for a tool that
# can kill things means every parameter is a number or a known word before it is used.
# =============================================================================
die_bad_arg() { echo "energy: refusing $1" >&2; exit 2; }
is_pid()  { case "$1" in ''|*[!0-9]*) return 1 ;; *) [ "$1" -gt 0 ] && [ "$1" -le 4194304 ] ;; esac; }
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Percent-encode one value of the swiftbar://notify query. A process chooses its own
# name, so an unencoded one could carry "&body=" and rewrite the notification, or a
# newline and truncate it. Byte-wise under LC_ALL=C, because slicing UTF-8 by character
# and taking "'$c" sign-extends anything above 0x7F into %FFFFFFFFFFFFFFC3.
urlenc() (
  export LC_ALL=C
  local s=$1 out= c n i
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    case $c in
      [a-zA-Z0-9.~_-]) out+=$c ;;
      *) printf -v n '%d' "'$c"; printf -v c '%%%02X' "$(( n & 0xFF ))"; out+=$c ;;
    esac
  done
  printf '%s' "$out"
)

# Ephemeral feedback for a click whose effect is otherwise invisible. SwiftBar closes the
# menu when a bash= row runs, and a stop can spend 2.5s escalating, so without this the
# button looks like it did nothing — which is exactly how a working Stop got reported as
# broken. Posted through SwiftBar rather than osascript: an osascript notification belongs
# to Script Editor, so clicking it launches Script Editor (see post_notification in
# lib/advisor.py). Backgrounded and never awaited — feedback must not delay the signal.
em_notify() {  # $1=title  $2=body
  [ -n "${EM_NO_NOTIFY:-}" ] && return 0
  # Test seam: a banner cannot be asserted on, and silent feedback is the failure mode
  # this whole change exists to prevent, so the tests need to read what would be posted.
  if [ -n "${EM_NOTIFY_LOG:-}" ]; then
    printf '%s\t%s\n' "$1" "$2" >> "$EM_NOTIFY_LOG"; return 0
  fi
  /usr/bin/open -g "swiftbar://notify?plugin=energy&title=$(urlenc "$1")&body=$(urlenc "$2")" \
    >/dev/null 2>&1 &
}

# A pid on its own is not an identity: pids are reused, and a recycled one must not
# inherit the previous tenant's "stopping…". Pair it with the start time, which is stable
# for the life of the process and changes the moment the number is handed to someone else.
em_pid_start() {  # $1=pid -> opaque start-time token, empty if the pid is gone
  ps -p "$1" -o lstart= 2>/dev/null | tr -s ' ' '_'
}

em_mark_stopping() {  # $@=pids just signalled
  mkdir -p "$STATE_DIR"
  local now st p
  now=$(date +%s)
  for p in "$@"; do
    st=$(em_pid_start "$p")
    [ -z "$st" ] && continue
    printf '%s\t%s\t%s\n' "$p" "$st" "$now" >> "$STOPPING"
  done
}

# Prunes as it reads, so the file can only shrink: a process that has exited, been
# replaced by a new one on the same pid, or outlived the TTL simply stops being listed.
em_stopping_live() {  # -> pids still on their way out, one per line
  [ -s "$STOPPING" ] || return 0
  local now tmp p st ts seen=" "
  now=$(date +%s); tmp="$STOPPING.$$"
  : > "$tmp"
  while IFS="$(printf '\t')" read -r p st ts; do
    [ -z "$p" ] && continue
    # Stopping the same process twice appends twice, so collapse here rather than at the
    # call sites: the file is what grows, and a duplicate row would be reported twice.
    case "$seen" in *" $p "*) continue ;; esac
    [ $((now - ${ts:-0})) -gt "$STOPPING_TTL" ] && continue
    kill -0 "$p" 2>/dev/null || continue
    [ "$(em_pid_start "$p")" = "$st" ] || continue
    seen="$seen$p "
    printf '%s\t%s\t%s\n' "$p" "$st" "$ts" >> "$tmp"
    printf '%s\n' "$p"
  done < "$STOPPING"
  mv "$tmp" "$STOPPING" 2>/dev/null || rm -f "$tmp"
}

# Name a pid the way the menu row named it, so the notification and the row agree. Note
# the second -f: "awk -f lib/label.awk '{...}'" would treat the program as an INPUT FILE
# and silently print nothing.
em_label() {  # $1=pid
  local c
  c=$(ps -p "$1" -o command= 2>/dev/null) || return 1
  [ -z "$c" ] && return 1
  awk -v c="$c" -f "$REPO/lib/label.awk" -f <(printf 'BEGIN{print mklabel(c)}') </dev/null
}

case "$1" in
  act)            # $2=signal  $3=pid  -> send a signal to one pid
    case "$2" in TERM|KILL|INT) ;; *) die_bad_arg "signal $2" ;; esac
    is_pid "$3" || die_bad_arg "pid $3"
    # Named before signalling, for the same reason as stop: afterwards there may be
    # nothing left to read. SIGINT is a cancel, not a kill, so it must not say "quit".
    act_label=$(em_label "$3") || act_label=""
    [ -z "$act_label" ] && act_label="pid $3"
    # SIGINT is a cancel — the process is meant to survive it, so it is not "stopping".
    [ "$2" = INT ] || em_mark_stopping "$3"
    kill -"$2" "$3" 2>/dev/null
    if [ "$2" = INT ]; then
      em_notify "Cancelled $act_label" "Ctrl-C sent. The session stays open."
    else
      em_notify "Quit $act_label" "The session was ended."
    fi
    exit 0 ;;
  stop)           # $3=comma-separated pids, leaves first -> TERM, then KILL if needed
    # SIGTERM and SIGKILL were two menu items, which made the user perform the
    # escalation by hand. They are not a choice, they are a sequence: TERM lets a
    # process flush buffers, release locks and save state, and SIGKILL exists for the
    # processes that ignore it. Offering both meant picking "Force kill" out of
    # impatience on a database that had a clean shutdown available.
    #
    # So: ask nicely, wait, and insist only if asked nicely did not work — the same
    # contract as `docker stop`, systemd's TimeoutStopSec, and macOS logout.
    # Leaves first, so a parent cannot respawn a child we already stopped.
    pids=$(printf '%s' "$3" | tr ',' ' ')
    for p in $pids; do is_pid "$p" || die_bad_arg "pid $p"; done
    # Describe them while they still exist — after the signal there is nothing left to
    # read. The list arrives leaves-first, so the LAST pid is the root of the tree and is
    # the one worth naming.
    n=0; last=""
    for p in $pids; do n=$((n + 1)); last=$p; done
    svc=0
    if [ "$n" = 1 ]; then
      case $(ps -p "$last" -o command= 2>/dev/null) in
        *--type=gpu-process*|*--type=utility*|*--type=zygote*) svc=1 ;;
      esac
    fi
    label=$(em_label "$last") || label=""
    [ -z "$label" ] && label="pid $last"
    [ "$n" -gt 1 ] && label="$label (+$((n - 1)))"
    # Marked before the signal, not after: the escalation below can take 2.5s, and a menu
    # opened during it must already know these are on their way out.
    em_mark_stopping $pids
    for p in $pids; do kill -TERM "$p" 2>/dev/null; done
    # ~2.5s of patience in 100ms steps. Almost everything is gone within one step, so
    # the common case stays instant and only a stubborn process costs the full wait.
    acked=0
    for i in $(seq 1 "${EM_STOP_PATIENCE:-25}"); do
      alive=0
      for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
      if [ "$alive" = 0 ]; then
        if [ "$svc" = 1 ]; then
          em_notify "Restarted $label" "Shared service — the browser replaces it immediately. The load comes back with the tabs causing it."
        elif [ "$n" -gt 1 ]; then
          em_notify "Stopped $label" "$n processes, leaves first."
        else
          em_notify "Stopped $label" "pid $last stopped cleanly."
        fi
        exit 0
      fi
      # A stop that is going to take a while must still say it heard the click.
      if [ "$acked" = 0 ] && [ "$i" -ge 3 ]; then
        acked=1
        em_notify "Stopping $label…" "Ignoring SIGTERM — waiting, then forcing."
      fi
      sleep 0.1
    done
    for p in $pids; do kill -KILL "$p" 2>/dev/null; done
    sleep 0.1
    alive=0
    for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
    if [ "$alive" = 0 ]; then
      em_notify "Force-stopped $label" "It ignored SIGTERM, so it was killed. Unsaved state was lost."
    else
      em_notify "Could not stop $label" "Still running after SIGKILL — it is probably not yours to signal."
    fi
    exit 0 ;;
  plumbing)       # toggle showing the idle wrapper processes inside call trees
    mkdir -p "$STATE_DIR"
    [ "$(cat "$PLUMB_FILE" 2>/dev/null)" = 1 ] && printf '0' > "$PLUMB_FILE" || printf '1' > "$PLUMB_FILE"
    exit 0 ;;
  chrome-close)   # $2=window index  $3=tab index
    # These are pasted into an AppleScript source string, so a non-numeric value would be
    # AppleScript injection — and they are derived from parsing a list whose titles a web
    # page controls. Integers only, checked here and again where the row is rendered.
    is_uint "$2" || die_bad_arg "window index $2"
    is_uint "$3" || die_bad_arg "tab index $3"
    if osascript -e "tell application \"Google Chrome\" to close tab $3 of window $2" 2>/dev/null; then
      em_notify "Closed tab $3" "Window $2."
    else
      em_notify "Could not close tab $3" "Chrome refused, or the tab had already moved."
    fi
    exit 0 ;;
  caffkill)       # kill every caffeinate keep-awake assertion
    caff_n=$(pgrep -x caffeinate 2>/dev/null | grep -c .)
    pkill -x caffeinate 2>/dev/null
    if [ "${caff_n:-0}" -gt 0 ]; then
      em_notify "Released $caff_n keep-awake assertion(s)" "The Mac can idle-sleep again."
    else
      em_notify "No keep-awake assertions" "Nothing was holding the Mac awake."
    fi
    exit 0 ;;
  open)           # $2=a System Settings pane
    # The menu only ever emits x-apple.systempreferences: URLs. Anything else — a file://
    # path, an http URL, a custom scheme registered by some installed app — would make
    # this a general-purpose "open anything" gadget, which is not a capability a menu-bar
    # monitor needs.
    case "$2" in x-apple.systempreferences:*) ;; *) die_bad_arg "url $2" ;; esac
    open "$2" 2>/dev/null
    exit 0 ;;
  mode)           # $2=mode name -> persist the current activity mode
    # Written to a state file that is later read back and rendered into the menu, so it
    # is held to the set of modes that actually exist.
    case "$2" in reading|coding|surfing) ;; *) die_bad_arg "mode $2" ;; esac
    mkdir -p "$STATE_DIR"; printf '%s' "$2" > "$MODE_FILE"
    exit 0 ;;
  chrome-enable)  # probe Automation permission for Chrome; on success drop a marker
    # that lets renders list tabs. Triggers the macOS consent prompt on first use.
    if perl -e 'alarm 5; exec @ARGV' osascript -e 'tell application "Google Chrome" to count windows' >/dev/null 2>&1; then
      mkdir -p "$STATE_DIR"; touch "$STATE_DIR/chrome-ok"
    fi
    exit 0 ;;
esac

# =============================================================================
# DATA COLLECTION
# =============================================================================

# Coding agents running under any terminal, ranked by this window's energy. The tree
# walk and the labels live in lib/ (see agents.awk) so they are shared with the
# call-tree view and testable headlessly; here we only feed it the snapshot and sort.
collect_cmux_agents() {
  awk -v agent_re="$AGENT_REGEX" -f "$REPO/lib/label.awk" -f "$REPO/lib/agents.awk" \
      "$ENERGY" "$PROCS" "$TABS" | sort -t"$(printf '\t')" -k2 -rn
}

# Heavy Chrome subprocesses (renderers/gpu/utility), ranked by cpu. We can kill a
# renderer pid directly: Chrome shows "Aw, Snap" and silently reloads that tab with
# its state when you revisit it — same trick as Activity Monitor, no manual hunting.
# Helpers of the browser YOU launched, plus a count of separate automation-driven
# Chrome instances — see lib/chrome.awk for why the two must not be mixed.
collect_chrome() { awk -f "$REPO/lib/chrome.awk" "$ENERGY" "$PROCS"; }

# Chrome tabs by title (AppleScript). Lets us close a *named* tab cleanly.
# GATED behind $STATE_DIR/chrome-ok (written by the chrome-enable action): when
# SwiftBar lacks Automation permission for Chrome, merely ATTEMPTING osascript from
# a render poisons the whole run — SwiftBar receives empty content and hides the
# menu bar item (verified empirically 2026-07-02). So renders never call osascript
# unless the permission has been proven good, and even then a 3s alarm caps it.
collect_chrome_tabs() {
  # Explicit 0: a bare "return" propagates the guard's own failure, and the caller now
  # reads the status as "the permission is gone" and retracts the marker.
  pgrep -x "Google Chrome" >/dev/null 2>&1 || return 0
  [ -f "$STATE_DIR/chrome-ok" ] || return 0
  {
    perl -e 'alarm 3; exec @ARGV' osascript <<'AS'
tell application "Google Chrome"
  set out to ""
  set wi to 0
  repeat with w in windows
    set wi to wi + 1
    set ti to 0
    repeat with t in tabs of w
      set ti to ti + 1
      set out to out & wi & "|" & ti & "|" & (title of t) & linefeed
    end repeat
  end repeat
  return out
end tell
AS
  } 2>/dev/null
}

# SECURITY BOUNDARY, shell side. See msafe() in lib/label.awk for the full reasoning:
# a SwiftBar line is "text | key=value", parameters start at the FIRST "|", and bash=/
# param1= turn a row into a command that runs on click. Window titles and process names
# are attacker-controlled, so every externally-derived string must lose its "|" before
# it is pasted into a line. Pure parameter expansion — this runs a few hundred times per
# render and a subprocess per call would cost more than the whole sample.
msafe() {
  local s=${1//|/¦}
  s=${s//$'\n'/ }; s=${s//$'\r'/ }; s=${s//$'\t'/ }
  printf '%s' "$s"
}

# Truncate in a UTF-8 subshell even though the collectors intentionally use LC_ALL=C.
# Byte-oriented slicing can split an en dash or emoji and make SwiftBar reject the
# entire menu as malformed UTF-8. Sanitising happens first, so truncation can never
# cut a payload in a way that leaves a bare "|" at the boundary.
trunc() (
  export LC_ALL=C.UTF-8 LANG=C.UTF-8
  local s n
  s=$(msafe "$1"); n="${2:-34}"
  [ ${#s} -gt "$n" ] && echo "${s:0:$n}…" || echo "$s"
)

# =============================================================================
# RENDER MENU  (each render also takes this cycle's CPU sample — see SAMPLING DESIGN)
# =============================================================================

mkdir -p "$STATE_DIR"
touch "$HIST" "$CUR" "$PARENTS" 2>/dev/null   # avoid awk "can't open file" on first run
now=$(date +%s)
cutoff=$((now - WINDOW))

# Temp files are suffixed with $$ so overlapping renders (SwiftBar can fire
# concurrently, e.g. wake-from-sleep + timer) never mv each other's files away.
# mv is atomic on APFS: last writer wins, earlier writers just get overwritten.
SNAP_NEW="$SNAP.new.$$"
PROCS="$STATE_DIR/procs.$$.tsv"    # this render's process table, fed to lib/*.awk
ENERGY="$STATE_DIR/energy.$$.tsv"  # this render's per-pid energy, fed to lib/*.awk
DB_CLIENTS="$STATE_DIR/dbclients.$$.tsv" # host PIDs connected to Docker-published Postgres
ATTRIB="$STATE_DIR/attrib.$$.tsv"        # owners the OS still knows (lib/attribution.py)
CDP="$STATE_DIR/cdp.$$.tsv"              # what each automation browser has open
trap 'rm -f "$PROCS" "$ENERGY" "$DB_CLIENTS" "$ATTRIB" "$CDP"' EXIT
# sweep temp files orphaned by renders that were killed mid-write
find "$STATE_DIR" \( -name "cputime.prev.new.*" -o -name "history.tsv.tmp.*" \
     -o -name "procs.*.tsv" -o -name "energy.*.tsv" -o -name "dbclients.*.tsv*" -o -name "attrib.*.tsv" -o -name "cdp.*.tsv" \
     -o -name "parents.tsv.tmp.*" -o -name "menu.render.*" \) \
     -mmin +1 -delete 2>/dev/null

# ---- take this cycle's sample: diff cumulative cputime vs previous render ----
# ps cputime formats: MM:SS.ss, HH:MM:SS, D-HH:MM:SS — normalize to seconds.
ps -axo pid=,cputime= | awk '{
  t=$2; d=0
  if (split(t,dd,"-")==2) { d=dd[1]; t=dd[2] }
  n=split(t,a,":"); s=d*86400
  if (n==3) s+=a[1]*3600+a[2]*60+a[3]; else s+=a[1]*60+a[2]
  printf "%s\t%.2f\n", $1, s
}' > "$SNAP_NEW"
prev_t=$(cat "$SNAP_T" 2>/dev/null || echo 0)
dt=$((now - prev_t))
if [ -s "$SNAP" ] && [ "$dt" -ge 2 ] && [ "$dt" -le $((WINDOW / 2)) ]; then
  # cpu% per pid over the interval; drop ~zero rows to keep files small. A pid whose
  # cputime went DOWN is a recycled pid — skipped (no valid prev to diff against).
  awk -F'\t' -v dt="$dt" '
    FNR==NR { prev[$1]=$2; next }
    ($1 in prev) && $2>=prev[$1] { v=($2-prev[$1])/dt*100; if (v>=0.1) printf "%s\t%.1f\n",$1,v }
  ' "$SNAP" "$SNAP_NEW" > "$CUR"
  awk -F'\t' -v t="$now" '{print t"\t"$0}' "$CUR" >> "$HIST"                                   # epoch<TAB>pid<TAB>cpu
  awk -F'\t' -v c="$cutoff" '$1>=c' "$HIST" > "$HIST.tmp.$$" 2>/dev/null && mv "$HIST.tmp.$$" "$HIST" # prune
  mv "$SNAP_NEW" "$SNAP"; printf '%s' "$now" > "$SNAP_T"
elif [ ! -s "$SNAP" ] || [ "$dt" -gt $((WINDOW / 2)) ]; then
  # first run, or snapshot too stale to be meaningful (Mac slept / SwiftBar was off):
  # rotate the baseline and wait for the next render to produce a valid diff.
  mv "$SNAP_NEW" "$SNAP"; printf '%s' "$now" > "$SNAP_T"
  FASTPAINT=1
else
  rm -f "$SNAP_NEW"   # renders <2s apart (manual refresh spam): keep previous baseline
fi

# Detect the first render under a freshly launched SwiftBar process (parent PID
# changed since our previous render).
SB_PID="${ENERGY_SWIFTBAR_PID:-$(ps -o ppid= -p $$ | tr -d ' ')}"
SB_COMM=$(ps -o comm= -p "$SB_PID" 2>/dev/null)
case "$SB_COMM" in *SwiftBar*)
  [ "$SB_PID" != "$(cat "$STATE_DIR/swiftbar.pid" 2>/dev/null)" ] && FASTPAINT=1
  printf '%s' "$SB_PID" > "$STATE_DIR/swiftbar.pid"
;; esac

# CRITICAL: on a first render (fresh SwiftBar, first run ever, or stale snapshot)
# paint a minimal menu in <200ms, skipping the expensive sections (Chrome
# AppleScript, agent scan). If SwiftBar's first render takes seconds, the item
# briefly has empty content, SwiftBar hides it, and macOS permanently persists
# "NSStatusItem VisibleCC <id>" = 0 — the menu bar item then NEVER appears again
# (AppKit autosave poisoning). Full data resumes on the next 5s cycle.
if [ "${FASTPAINT:-0}" = 1 ]; then
  echo "⚡…"
  echo "---"
  echo "collecting… | color=gray size=11"
  echo "Refresh | refresh=true"
  exit 0
fi

# The render is nothing without lib/. Say so out loud rather than emitting an empty
# menu: SwiftBar hides an item whose content is empty, and macOS then persists that
# hidden state — the ⚡ never comes back (see the FASTPAINT note above).
if [ ! -f "$TREE_AWK" ]; then
  echo "⚡!"
  echo "---"
  echo "missing $TREE_AWK | color=red"
  echo "The plugin needs the lib/ folder from the mac-energy-manager repo. | size=11 color=gray"
  echo "Open repo | bash=/usr/bin/open param1=\"$REPO\" terminal=false"
  echo "Refresh | refresh=true"
  exit 0
fi

# ---- this render's process table (the only ps the render needs) -------------
em_procs "$PROCS"

# ---- remember who spawned whom (see lib/parents.awk) ------------------------
# Updated before the tree is built, from this same snapshot, so both agree on which
# processes are alive. Cheap to keep: one line per process that has a real parent.
awk -f "$REPO/lib/parents.awk" "$PARENTS" "$PROCS" > "$PARENTS.tmp.$$" 2>/dev/null \
  && mv "$PARENTS.tmp.$$" "$PARENTS"

em_energy "$PROCS" "$ENERGY"
em_docker_db_clients "$DB_CLIENTS"
em_attrib "$PROCS" "$ATTRIB"

# ---- build the call tree ----------------------------------------------------
# Everything below renders lib/tree.awk's output; the folding, ranking, chain
# reconstruction and labelling all live there (and are covered by test/run-tests.sh).
touch "$OWNERS"                  # written only by bin/browser-stamp; awk needs it to exist

# Tab names change rarely and a python3 start is ~50ms — far too much to spend on every
# 10s render. Rebuild only when cmux has actually rewritten its session file since we
# last looked, which is the only thing that can change the answer.
CMUX_SESSION=$(ls -t "$HOME/Library/Application Support/cmux/"session-*.json 2>/dev/null \
               | grep -v -- '-previous\.json$' | head -1)
EM_PY=$(em_python)
if [ -n "$EM_PY" ] && [ -n "$CMUX_SESSION" ] && { [ ! -f "$TABS" ] || [ "$TABS" -ot "$CMUX_SESSION" ]; }; then
    "$EM_PY" "$REPO/lib/cmux_tabs.py" > "$TABS.tmp.$$" 2>/dev/null \
        && mv "$TABS.tmp.$$" "$TABS" || rm -f "$TABS.tmp.$$"
fi
touch -c "$TABS" 2>/dev/null || : > "$TABS"
MODE=$(cat "$MODE_FILE" 2>/dev/null); [ -z "$MODE" ] && MODE=coding
ALLOW="$(mode_allow "$MODE")|SwiftBar"
PLUMBING=$(cat "$PLUMB_FILE" 2>/dev/null); [ "$PLUMBING" = 1 ] || PLUMBING=0
TREE="$(awk -v top_n="$TOP_N" -v tree_min="$TREE_MIN" -v root_min="$ROOT_MIN" -v elide_max="$ELIDE_MAX" \
            -v hog_min="$HOG_MIN" -v max_rows="$MAX_TREE_ROWS" -v plumbing="$PLUMBING" \
            -v flag_min="$FLAG_MIN" -v me="$(id -un)" -v allow="$ALLOW" \
            -f "$REPO/lib/label.awk" -f "$REPO/lib/tree.awk" \
            "$ENERGY" "$PARENTS" "$PROCS" "$DB_CLIENTS" "$OWNERS" "$TABS" "$ATTRIB")"

FLAGGED="$(printf '%s\n' "$TREE" | awk -F'\t' '$1=="R" && $7==1')"

# menu-bar title = the heaviest tree's 10-min average (sustained, doesn't flicker),
# plus a ⚠ when something incompatible with the current mode is running.
TOPVAL=$(printf '%s\n' "$TREE" | awk -F'\t' '$1=="R"{print $3; exit}')
[ -n "$FLAGGED" ] && WARN=" ⚠" || WARN=""
if [ -s "$CUR" ]; then echo "⚡${TOPVAL:-0}${WARN}"; else echo "⚡…"; fi
echo "---"
[ -s "$CUR" ] || echo "collecting first sample… | color=gray size=11"

# Read once per render, not per row: this prunes the file as a side effect, so calling it
# repeatedly would have each caller racing the others to rewrite it.
STOPPING_CSV=",$(em_stopping_live | sort -un | tr '\n' ',' )"
# Rows are rendered by both shell and awk, so both need the same test.
em_stopping() {  # $1=pid -> true when it has been signalled and is still here
  case "$STOPPING_CSV" in *",$1,"*) return 0 ;; *) return 1 ;; esac
}
em_stop_tag() {  # $1=pid -> the suffix a row carries while it is dying
  em_stopping "$1" && printf '  · stopping…'
}

# ---- Activity mode + incompatibility warnings -------------------------------
echo "Mode: $MODE | size=11 color=black,white"
for m in reading coding surfing; do
  mk="   "; [ "$m" = "$MODE" ] && mk="✓  "
  echo "-- ${mk}${m} | bash=\"$SELF\" param1=mode param2=$m terminal=false refresh=true"
done
if [ -n "$FLAGGED" ]; then
  nflag=$(printf '%s\n' "$FLAGGED" | grep -c .)
  echo "⚠ Running but not needed for ‘$MODE’ ($nflag) | color=orange"
  printf '%s\n' "$FLAGGED" | while IFS=$'\t' read -r _ pid avg now nproc _ _ _ label _; do
    [ -z "$pid" ] && continue
    sub=""; [ "${nproc:-1}" -gt 1 ] && sub=" ($nproc)"
    echo "$avg · $now  $(trunc "$label")$sub$(em_stop_tag "$pid") | color=orange font=Menlo size=12"
    if em_stopping "$pid"; then
      echo "-- Already stopping — force it now | bash=\"$SELF\" param1=act param2=KILL param3=$pid terminal=false keepopen=true refresh=true color=red"
    else
      echo "-- Stop | bash=\"$SELF\" param1=stop param3=$pid terminal=false keepopen=true refresh=true"
    fi
  done
else
  echo "✓ Nothing heavy conflicts with ‘$MODE’ | color=green size=11"
fi

# ---- Top consumers, aggregated over each process's whole subtree ------------
# One row per top-level process, carrying what it and everything it spawned cost
# together; open a row to get the call tree that adds up to that number.
echo "Top consumers, %cpu  (avg 10m · now) | size=11 color=gray"
printf '%s\n' "$TREE" | awk -F'\t' -v self="$SELF" -v stopping="$STOPPING_CSV" '
  # SwiftBar rows that only carry a submenu lose their action on an incremental menu
  # update unless they set a colour of their own, so every parent row below has one.
  function row(txt, params) { print txt " | " params }
  # Signalled but still here. The row says so, and its action escalates instead of
  # repeating a SIGTERM the process has already ignored.
  function dying(pid) { return index(stopping, "," pid ",") > 0 }
  function tag(pid) { return dying(pid) ? "  · stopping…" : "" }
  function widen(v, w) { w=length(sprintf("%.1f", v)); if (w > NUMW) NUMW=w }
  $1=="R" {
    n++; ID[n]=$2; AVG[n]=$3; NOW[n]=$4; NP[n]=$5
    FLAG[n]=$7; CRIT[n]=$8; LAB[n]=$9; cur=n
    widen($3); widen($4)
    next
  }
  $1=="K" { KILL[cur]=$3; next }
  $1=="H" { if (HOT[cur]=="") HOT[cur]=$4; next }              # heaviest single process inside
  $1=="T" {
    # Keep raw fields until END, when the widest live number is known. A fixed width
    # shifts every tree guide as soon as CPU rises into one more digit.
    t++; TTREE[t]=cur; TAVG[t]=$6; TNOW[t]=$7; TPFX[t]=$9; TLAB[t]=$10
    TSELFAVG[t]=$4; TSELFNOW[t]=$5; TVIA[t]=$11; TPID[t]=$2; THOG[t]=$8
    TCOUNT[cur]++
    widen($6); widen($7)
    next
  }
  $1=="D" {
    d++; DSOURCE[d]=$2; DTARGET[d]=$3; DCID[d]=$4; DCNAME[d]=$5
    DKIND[d]=$6; DPORT[d]=$7; DSOCK[d]=$8; DCAND[d]=$9
    DSRCLAB[d]=$10; DCHAIN[d]=$11
    next
  }
  END {
    if (NUMW < 3) NUMW=3
    for (i = 1; i <= n; i++) {
      mark = FLAG[i] ? "⚠ " : ""
      grp  = (NP[i] > 1) ? sprintf(" (%d)", NP[i]) : ""
      dbn = 0; dbfirst = 0
      for (q = 1; q <= d; q++) if (DTARGET[q] == ID[i]) {
        dbn++
        if (!dbfirst) dbfirst = q
      }
      # Name the biggest single process inside the tree right on the row, so the
      # common question — "what in there is actually burning this?" — is already
      # answered before you open anything.
      hot  = (HOT[i] != "" && HOT[i] != LAB[i]) ? "  → " HOT[i] : ""
      dbhot = ""
      if (dbn == 1 && DCAND[dbfirst] == 1) dbhot = "  ⇠ DB: " DSRCLAB[dbfirst]
      else if (dbn > 0) dbhot = sprintf("  ⇠ DB: %d possible clients", dbn)
      row(sprintf("%s%-*.1f · %*.1f  %s%s%s%s%s", mark, NUMW, AVG[i], NUMW, NOW[i], LAB[i], grp, hot, dbhot, tag(ID[i])),
          "font=Menlo size=12 length=52 color=" (FLAG[i] ? "orange" : "black,white"))
      if (CRIT[i]) {
        row("-- system process — not killable (shared by all apps)", "color=gray")
        if (LAB[i] == "WindowServer") {
          row("-- ▸ high = lots of screen redraws. Lower it by closing fast-updating windows", "color=gray size=11")
          row("-- (e.g. idle cmux tabs, video) or enabling Reduce Motion/Transparency.", "color=gray size=11")
        }
      } else {
        if (dying(ID[i]))
          row("-- Already stopping — force it now",
              "bash=\"" self "\" param1=act param2=KILL param3=" ID[i] " terminal=false keepopen=true refresh=true color=red")
        else
          row("-- Stop", "bash=\"" self "\" param1=stop param3=" ID[i] " terminal=false keepopen=true refresh=true")
        if (KILL[i] != "") {
          row(sprintf("-- Stop whole tree (%d processes)", NP[i]),
              "bash=\"" self "\" param1=stop param3=" KILL[i] " terminal=false keepopen=true refresh=true color=red")
        }
      }
      if (dbn > 0) {
        row("-- Database clients — causal socket evidence; CPU totals stay separate", "size=10 color=gray")
        for (q = 1; q <= d; q++) {
          if (DTARGET[q] != ID[i]) continue
          chain = DCHAIN[q]
          if (length(chain) > 62) chain = substr(chain, 1, 61) "…"
          maybe = (DCAND[q] > 1) ? sprintf("possible (%d clients)", DCAND[q]) : "client"
          row(sprintf("-- ⇠ %s · %s :%s — %s: %s", DKIND[q], DCNAME[q], DPORT[q], maybe, chain),
              "font=Menlo size=11 length=76 color=orange")
        }
      }
      if (TCOUNT[i] == 0) continue
      row("-- Call tree — each row is that branch in total; “own” = process alone", "size=11 color=gray")
      row("-- Totals include low-cost processes hidden by the row limit", "size=10 color=gray")
      for (j = 1; j <= t; j++) {
        if (TTREE[j] != i) continue
        txt = sprintf("%-*.1f · %*.1f  %s%s%s%s%s", NUMW, TAVG[j], NUMW, TNOW[j], TPFX[j], TLAB[j],
                      (TAVG[j] > TSELFAVG[j] + 0.05 ? sprintf("   own %.1f · %.1f", TSELFAVG[j], TSELFNOW[j]) : ""),
                      (TVIA[j] == "" ? "" : "   ← " TVIA[j]), tag(TPID[j]))
        row("-- " txt, "font=Menlo size=12 length=64 color=" (THOG[j] == "1" ? "orange" : "black,white"))
        if (dying(TPID[j]))
          row("---- Already stopping — force it now",
              "bash=\"" self "\" param1=act param2=KILL param3=" TPID[j] " terminal=false keepopen=true refresh=true color=red")
        else
          row("---- Stop", "bash=\"" self "\" param1=stop param3=" TPID[j] " terminal=false keepopen=true refresh=true")
        for (q = 1; q <= d; q++) if (DSOURCE[q] == TPID[j]) {
          maybe = (DCAND[q] > 1) ? sprintf("possible client, %d connected", DCAND[q]) : "DB client"
          row(sprintf("---- ⇢ Docker · %s · %s :%s  (%s)", DKIND[q], DCNAME[q], DPORT[q], maybe),
              "size=10 color=orange")
        }
      }
    }
  }'
printf '%s\n' "$TREE" | grep -q '^R\t' \
  || echo "nothing above ${ROOT_MIN}% — the machine is idle | color=gray size=11"
plumb_label="off"; [ "$PLUMBING" = 1 ] && plumb_label="on"
echo "Wrapper processes in call trees: $plumb_label | size=11 color=gray bash=\"$SELF\" param1=plumbing terminal=false refresh=true"

# ---- Coding agents ----------------------------------------------------------
echo "---"
echo "Coding agents | size=11 color=gray"
AGENTS="$(collect_cmux_agents)"
if [ -z "$AGENTS" ]; then
  echo "no agents running in a terminal | color=gray size=11"
else
  # Only agents that are actually spending anything. A dozen open tabs are normal and
  # all but one of them are waiting on you, so listing every one buries the busy agent
  # in a wall of 0.0% rows — the exact problem this section exists to solve.
  # avg over the window, not ps's lifetime-average pcpu: a long-lived agent that has
  # been idle for the last ten minutes should read as idle, and pcpu never does.
  BUSY="$(printf '%s\n' "$AGENTS" | awk -F'\t' -v m="$AGENT_MIN" '$2+0 >= m')"
  nidle=$(printf '%s\n' "$AGENTS" | awk -F'\t' -v m="$AGENT_MIN" '$2+0 < m' | grep -c . || true)
  if [ -z "$BUSY" ]; then
    echo "all $nidle agent(s) idle | color=gray size=11"
  else
    printf '%s\n' "$BUSY" | head -"$AGENT_MAX" | while IFS=$'\t' read -r pid cpu label cmd; do
      [ -z "$pid" ] && continue
      echo "${cpu}%  $label$(em_stop_tag "$pid") | font=Menlo size=12 color=black,white"
      echo "-- Cancel current turn (Ctrl-C) | bash=\"$SELF\" param1=act param2=INT param3=$pid terminal=false keepopen=true refresh=true"
      if em_stopping "$pid"; then
        echo "-- Already quitting — force it now | bash=\"$SELF\" param1=act param2=KILL param3=$pid terminal=false keepopen=true refresh=true color=red"
      else
        echo "-- Quit agent | bash=\"$SELF\" param1=stop param3=$pid terminal=false keepopen=true refresh=true color=red"
      fi
      echo "-- $(trunc "$cmd" 80) | font=Menlo size=10 color=gray"
    done
    nbusy=$(printf '%s\n' "$BUSY" | grep -c . || true)
    hidden=$(( nbusy > AGENT_MAX ? nbusy - AGENT_MAX + nidle : nidle ))
    # Say only what is true: some hidden rows are under the floor, others merely lost
    # the row budget, and claiming they are all idle would be a lie about live agents.
    [ "$hidden" -gt 0 ] && echo "… $hidden quieter agent(s) not shown | color=gray size=11"
  fi
fi

# ---- Chrome -----------------------------------------------------------------
echo "---"
if pgrep -x "Google Chrome" >/dev/null 2>&1; then
  # NOTE: parent rows (rows that only carry a submenu) need an explicit color:
  # SwiftBar 2.1's incremental menu patcher drops the row's action unless it has
  # its own action or a color param, which greys the row after the first update.
  # "black,white" = light,dark theme pair (reads as default text in both).
  echo "Chrome | color=black,white"
  CHROME="$(collect_chrome)"
  echo "-- Heavy processes, avg 10m | size=11 color=gray"
  printf '%s\n' "$CHROME" | awk -F'\t' '$1=="H"{print $2"\t"$3"\t"$4}' \
    | sort -t"$(printf '\t')" -k2 -rn | head -8 | while IFS=$'\t' read -r pid cpu type; do
    [ -z "$pid" ] && continue
    echo "-- ${cpu}  $type  pid $pid | font=Menlo color=black,white"
    # A renderer is a tab and stays dead until you revisit it, so stopping one both ends
    # the drain and shows you WHICH tab it was. gpu/utility are shared services under the
    # browser process, which replaces them within milliseconds — the click is not useless
    # (it is the standard way to clear a wedged GPU process) but it does not reduce load,
    # because the demand lives in the renderers. Labelling both "Stop process" made a
    # working button look broken.
    case "$type" in
      tab)
        echo "---- Stop this tab | bash=\"$SELF\" param1=stop param3=$pid terminal=false keepopen=true refresh=true color=red"
        echo "---- the tab breaks — that is how you spot it — and reloads when revisited | size=10 color=gray"
        ;;
      *)
        echo "---- Restart this service | bash=\"$SELF\" param1=stop param3=$pid terminal=false keepopen=true refresh=true color=red"
        echo "---- shared — Chrome respawns it at once; the load is the tabs' | size=10 color=gray"
        ;;
    esac
  done
  nauto=$(printf '%s\n' "$CHROME" | awk -F'\t' '$1=="A"{print $2}')
  if [ "${nauto:-0}" -gt 0 ]; then
    echo "-- ⚙ $nauto automation-driven Chrome — see the section below | size=10 color=gray"
  fi
  # The marker is proof the grant worked ONCE, not that it still holds. Revoking Automation
  # in System Settings (or reinstalling Chrome) leaves it behind, and osascript then fails
  # with -1743 on every render. Trusting it blindly is not hypothetical: on this machine a
  # Jul-23 marker outlived its permission and the menu showed an empty "Tabs" heading for
  # eighteen days, with the re-enable prompt unreachable because the marker was still there.
  # So capture the status — a pipe would discard it — and let a failure retract the marker.
  # ...but only SwiftBar's own verdict counts. Automation is granted per CALLING app, so
  # the same osascript that SwiftBar is allowed to run is refused (-1743) from a terminal,
  # a test, or an ssh session. Retracting on any failure would let one manual run destroy a
  # perfectly good grant. Under SwiftBar a failure is authoritative; elsewhere it says
  # nothing about the permission, so the marker is left exactly as it is.
  CHROME_TABS=""; CHROME_TABS_RC=0
  if [ -f "$STATE_DIR/chrome-ok" ]; then
    CHROME_TABS=$(collect_chrome_tabs); CHROME_TABS_RC=$?
    if [ "$CHROME_TABS_RC" -ne 0 ] && [ -n "${SWIFTBAR:-}" ]; then
      rm -f "$STATE_DIR/chrome-ok"
    fi
  fi
  if [ -f "$STATE_DIR/chrome-ok" ] && [ "$CHROME_TABS_RC" -ne 0 ]; then
    # Marker intact, call refused: a hand-run outside SwiftBar. Say so, rather than print
    # an empty "Tabs" heading and let it read as "you have no tabs".
    echo "-- Tabs — unavailable outside SwiftBar (Automation is granted per app) | size=11 color=gray"
  elif [ -f "$STATE_DIR/chrome-ok" ]; then
    # Deliberately NOT presented as ranked. Chrome's AppleScript dictionary exposes a tab's
    # title, URL and loading flag — no pid, no cost — and nothing outside the browser closes
    # that gap: a renderer's argv carries only an internal --renderer-client-id, and its open
    # files are fonts and ICU data (both checked). So this names tabs, it cannot rank them;
    # implying otherwise would be a guess dressed as a diagnosis.
    echo "-- Tabs — all of them; cost above is per-pid and cannot be matched to a title | size=11 color=gray"
    printf '%s\n' "$CHROME_TABS" | while IFS='|' read -r wi ti title; do
      [ -z "$wi" ] && continue
      # A page title may contain a newline, which turns into an extra line here and would
      # otherwise put attacker text where a window index belongs. Drop such rows.
      is_uint "$wi" && is_uint "$ti" || continue
      echo "-- $(trunc "$title" 38) | length=40 color=black,white"
      echo "---- Close tab | bash=\"$SELF\" param1=chrome-close param2=$wi param3=$ti terminal=false refresh=true color=red"
    done
  elif [ "$CHROME_TABS_RC" -ne 0 ]; then
    echo "-- ▸ Re-enable tab names… | bash=\"$SELF\" param1=chrome-enable terminal=false keepopen=true refresh=true"
    echo "-- macOS withdrew Automation permission for Chrome | size=10 color=gray"
  else
    echo "-- ▸ Enable tab names… | bash=\"$SELF\" param1=chrome-enable terminal=false keepopen=true refresh=true"
    echo "-- approve the Automation prompt, then click again | size=10 color=gray"
    echo "-- until then the rows above can only be pids | size=10 color=gray"
  fi
else
  echo "Chrome — not running | color=gray"
fi

# ---- Automation browsers ----------------------------------------------------
# These are excluded from the Chrome section on purpose — they are not your tabs, the
# AppleScript tab list cannot see them, and killing one breaks an automation run. But
# "N not listed here" was a dead end: no way to tell which was burning a core, or on
# what. CDP answers that with no permission at all (lib/cdp.sh), and the launch stamp
# says whose it is, so the section can be about the two things you actually want.
em_cdp_pages "$PROCS" "$CDP"
AUTOB="$(awk -F'\t' '
  FILENAME==ARGV[1] { own[$1] = $4; next }                       # owners.tsv: key -> label
  FILENAME==ARGV[2] { pages[$1] = pages[$1] "\v" $2; next }       # cdp.tsv: profile -> titles
  {                                                              # procs.tsv
    if ($5 !~ /--user-data-dir=/ || $5 !~ /[Cc]hrom|headless_shell/) next
    d = $5; sub(/^.*--user-data-dir=/, "", d); sub(/ .*$/, "", d); sub(/\/+$/, "", d)
    if (d !~ /^(\/private)?\/(tmp|var\/folders)\//) next
    n[d]++; pids[d] = (d in pids) ? pids[d] "," $1 : $1
  }
  END {
    for (d in n) {
      b = d; sub(/^.*\//, "", b)
      printf "%s\t%d\t%s\t%s\t%s\n", b, n[d], pids[d], (d in own ? own[d] : ""), pages[d]
    }
  }' "$OWNERS" "$CDP" "$PROCS" | sort -t"$(printf '\t')" -k2 -rn)"
if [ -n "$AUTOB" ]; then
  echo "---"
  echo "Automation browsers | size=11 color=gray"
  printf '%s\n' "$AUTOB" | while IFS=$'\t' read -r prof nproc pids owner titles; do
    [ -z "$prof" ] && continue
    who=""; [ -n "$owner" ] && who="  ← $(msafe "$owner")"
    echo "$(trunc "$prof" 30)  ($nproc)$who | font=Menlo size=12 color=black,white"
    if [ -n "$titles" ]; then
      printf '%s' "$titles" | tr '\v' '\n' | while read -r t; do
        [ -n "$t" ] && echo "-- $(trunc "$t" 44) | size=11 color=gray"
      done
    else
      echo "-- (no debug port — pages unknown) | size=10 color=gray"
    fi
    echo "-- Stop this browser | bash=\"$SELF\" param1=stop param3=$pids terminal=false keepopen=true refresh=true color=red"
  done
fi

# ---- Keep-awake (caffeinate) -----------------------------------------------
echo "---"
CAFF=$(pgrep -x caffeinate | tr '\n' ' ')
if [ -n "$CAFF" ]; then
  cnt=$(printf '%s' "$CAFF" | wc -w | tr -d ' ')
  echo "Keep-awake: $cnt caffeinate timer(s) active | color=orange"
  echo "--These are spawned by running agents; they auto-expire. | color=gray size=11"
  echo "Force-release all (let Mac nap) | bash=\"$SELF\" param1=caffkill terminal=false refresh=true"
else
  echo "Keep-awake: none — Mac can idle-sleep | color=gray"
fi

# ---- System power subsystems (status + quick links) ------------------------
echo "---"
echo "Power subsystems | size=11 color=gray"
BT=$(system_profiler SPBluetoothDataType 2>/dev/null | awk -F': ' '/State:/{print $2; exit}')
HANDOFF=$(defaults read ~/Library/Preferences/com.apple.coreservices.useractivityd ActivityAdvertisingAllowed 2>/dev/null)
[ "$HANDOFF" = "0" ] && HANDOFF="Off" || HANDOFF="On"
echo "Bluetooth: ${BT:-?} | font=Menlo color=black,white"
echo "--Open Bluetooth settings | bash=\"$SELF\" param1=open param2=\"x-apple.systempreferences:com.apple.BluetoothSettings\" terminal=false"
echo "Handoff/Continuity: $HANDOFF | font=Menlo color=black,white"
echo "--Open AirDrop & Handoff settings | bash=\"$SELF\" param1=open param2=\"x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension\" terminal=false"
echo "Keyboard brightness | font=Menlo color=black,white"
echo "--Open Keyboard settings (brightness slider) | bash=\"$SELF\" param1=open param2=\"x-apple.systempreferences:com.apple.Keyboard-Settings.extension\" terminal=false"

# ---- Alert history ----------------------------------------------------------
# macOS banners are transient, so the last five posted alerts stay reachable here,
# backed by the bounded notifications.jsonl archive. Kept near the BOTTOM on purpose:
# it is a log, and a log does not belong above the live numbers you opened the menu
# for. Alerts are rare by design — when one fires you get a banner, not a menu row.
echo "---"
ALERTS="$("$REPO/bin/energy-advisor" messages --tsv 5 2>/dev/null)"
if [ -z "$ALERTS" ]; then
  echo "Alerts — none yet | color=gray size=11"
else
  echo "Alerts — last $(printf '%s\n' "$ALERTS" | grep -c .) | color=gray size=11"
  printf '%s\n' "$ALERTS" \
    | while IFS=$'\t' read -r stamp severity title body reason; do
        [ -z "$stamp" ] && continue
        case "$severity" in
          critical) colour=red ;;
          *)        colour=orange ;;
        esac
        echo "-- $(msafe "$stamp") · $(msafe "$title") | color=$colour size=11"
        [ -n "$body" ] && echo "---- $(msafe "$body") | color=black,white size=11 length=76"
        [ -n "$reason" ] && echo "---- Why: $(msafe "$reason") | color=gray size=10 length=76"
        echo "---- Severity: $severity | color=gray size=10"
      done
fi

echo "---"
# The full forest, with no 12-row ceiling and no submenu to walk. Starts its own
# viewer (127.0.0.1 only) on first click and reuses it afterwards; it reads the same
# history this plugin samples, so the two can never show different numbers.
echo "Open call graph (fullscreen)… | bash=\"$REPO/bin/energy-graph\" param1=open terminal=false"
echo "Refresh | refresh=true"
echo "Open repo | bash=/usr/bin/open param1=\"$REPO\" terminal=false"
