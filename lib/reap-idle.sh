# Pure helpers for browser-reap's idle clock: which activity marker may be trusted, and which
# markers are litter. Sourced by bin/browser-reap and by test/run-tests.sh; no side effects on load.
#
# The marker `browser-activity/pid-<ppid>` is keyed by a PID, and PIDs are recycled. A marker the
# wrapper wrote for an earlier process with the same PID therefore looks like "this browser was
# last used days ago", and a brand-new Playwright or hand-launched browser whose launcher happens
# to reuse that PID was killed as idle about a minute after it opened (2026-09-23, with 1,622 stale
# markers on disk). A marker older than the browser it is being read for cannot describe that
# browser, so it is ignored and the caller falls back to age, the honest degradation.

# Seconds of slack for clock granularity: the wrapper touches the marker right after the command
# that launched the browser, so a genuine first marker is never meaningfully older than the browser.
REAP_MARKER_SLACK_SEC=${REAP_MARKER_SLACK_SEC:-5}

# marker_idle <marker_mtime> <now> <browser_age_seconds>
# Prints seconds since the browser was last driven, or "" when the marker predates the browser.
marker_idle() {
    local mtime="$1" now="$2" age="$3"
    case "$mtime$now$age" in *[!0-9]*|'') printf ''; return ;; esac
    if [ "$mtime" -lt $(( now - age - REAP_MARKER_SLACK_SEC )) ]; then printf ''; return; fi
    printf '%s' $(( now - mtime ))
}

# prune_activity_markers <dir> [live_pids]
# Deletes pid markers whose process no longer exists, so a recycled PID meets no stale file.
# live_pids is a whitespace-separated PID list (injectable for tests); by default it is read once
# from ps, which also counts processes kill -0 could not signal. Prints the number removed.
prune_activity_markers() {
    local dir="$1" live="${2-}" f pid n=0
    [ -d "$dir" ] || { printf '0'; return; }
    [ $# -ge 2 ] || live=$(ps -axo pid= 2>/dev/null) || { printf '0'; return; }
    [ -n "$live" ] || { printf '0'; return; }   # an empty process list is a failed read, not a dead world
    live=" $(printf '%s' "$live" | tr -s ' \n\t' '   ') "
    for f in "$dir"/pid-*; do
        [ -e "$f" ] || continue
        pid="${f##*/pid-}"
        case "$pid" in *[!0-9]*|'') continue ;; esac
        case "$live" in *" $pid "*) ;; *) rm -f "$f" && n=$((n + 1)) ;; esac
    done
    printf '%s' "$n"
}
