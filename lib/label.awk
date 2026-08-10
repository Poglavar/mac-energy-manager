# lib/label.awk — turns a raw command line into a short, human-readable process name.
#
# Functions only, no main rules: load it alongside another program, e.g.
#   awk -f lib/label.awk -f lib/tree.awk ...
# Shared so the call tree and the agents list can never disagree about a name.

# SECURITY BOUNDARY. Every label produced here is pasted into a SwiftBar menu line,
# whose format is "text | key=value ...". SwiftBar takes everything after the FIRST "|"
# as parameters — including bash=/param1=, which make a row execute a command on click.
# Process names and window titles are attacker-controlled (a web page fully controls
# document.title, and anything can exec with a chosen argv[0]), so a raw "|" reaching a
# menu line is arbitrary code execution one click away. Verified exploitable before this
# existed. `ps` already escapes newlines and tabs to \012/\011, but it does NOT touch "|".
#
# Sanitising here rather than at each call site is deliberate: labels flow to the menu,
# the graph and the JSON API, and a boundary with one door cannot be forgotten at the
# eleventh one.
function msafe(s) {
  gsub(/\|/, "¦", s)                 # U+00A6 broken bar: reads the same, parses as text
  gsub(/[\n\r\t]/, " ", s)
  return s
}

function bname(s,   n, a) { n = split(s, a, "/"); return a[n] }

# argv[0] of a command line. Wrong for paths with spaces, so appname() gets first crack.
function argv0(cmd) { sub(/ .*/, "", cmd); return cmd }

# "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" -> "Google Chrome".
# Bundle paths are the only reliable way to name an app whose binary has a space in it.
function appname(cmd,   s) {
  if (match(cmd, /\/[^\/]+\.app\/Contents\/MacOS\//)) {
    s = substr(cmd, RSTART + 1, RLENGTH - 1)
    sub(/\.app\/Contents\/MacOS\/$/, "", s)
    return s
  }
  return ""
}

# First non-flag argument, so "ssh -t valhalla ..." reads as "ssh valhalla".
function arg1(cmd,   n, a, i) {
  n = split(cmd, a, " ")
  for (i = 2; i <= n; i++) if (a[i] !~ /^-/ && a[i] != "") return a[i]
  return ""
}

# The throwaway profile of an automation browser, or "" for the user's real browser.
# A browser started by an agent is told to use its own --user-data-dir under a temp
# path; the real browser has no such flag. That is the only thing telling them apart —
# same binary, same bundle, same name — so without this a leaked agent browser reads
# as "Chrome is busy again" and gets ignored. Same test browser-reap uses to decide
# what it may kill, deliberately: the two must never disagree about what is automation.
function udd(cmd,   s) {
  if (!match(cmd, /--user-data-dir=[^ ]+/)) return ""
  s = substr(cmd, RSTART + 16, RLENGTH - 16)
  if (s !~ /^(\/private)?\/(tmp|var\/folders)\//) return ""   # a real profile lives in ~/Library
  sub(/\/+$/, "", s)
  return s
}

function autoprofile(cmd,   s) {
  s = bname(udd(cmd))
  return (length(s) > 24) ? substr(s, 1, 24) : s
}

# Short session id, enough to tell one agent tab from another.
function shortid(cmd,   s) {
  if (match(cmd, /session[-_]id[= ][0-9a-fA-F]{8}/)) {
    s = substr(cmd, RSTART, RLENGTH); sub(/.*[= ]/, "", s); return s
  }
  if (match(cmd, /[ \/][0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-/)) return substr(cmd, RSTART + 1, 8)
  return ""
}

# mklabel, then the human name for an agent session if one is known. Reads a global
# TAB[] that each caller fills from lib/cmux_tabs.py output — kept here rather than in
# tree.awk so the call tree and the agents list can never disagree about a name, which
# is the same reason mklabel itself lives in this file.
#
# "claude · 7ba7d89b" is what the machine calls the session; "claude · Enhance parking
# spot" is what you call it, and only one of them answers which work is eating a core.
function mklabel_tab(cmd,   t, s) {
  t = mklabel(cmd)
  s = shortid(cmd)
  # The tab title comes from another program's state file, so it is external input
  # like everything else and gets the same treatment. It is substituted AFTER
  # mklabel has already sanitised, so it needs its own pass.
  if (s != "" && (s in TAB) && TAB[s] != "") sub(/ · .*$/, " · " msafe(TAB[s]), t)
  return msafe(t)
}

function mklabel(cmd) { return msafe(mklabel_raw(cmd)) }

function mklabel_raw(cmd,   b, t, s, n, a) {
  b = bname(argv0(cmd)); sub(/^-/, "", b)          # login shells are argv[0]="-zsh"
  if (b ~ /^agent-browser(-darwin-[A-Za-z0-9_-]+)?$/) return "agent-browser"
  if (b ~ /^com\.apple\.Virtualization/) return "Docker VM"
  # Docker runs a fleet of reverse-DNS binaries, several of them com.docker.backend
  # with only a subcommand to tell them apart — without it a Docker tree is five rows
  # all called "Docker". Keep the subcommand when there is a plain one.
  if (b ~ /^com\.docker\./) {
    sub(/^com\.docker\./, "", b)
    n = split(cmd, a, " ")
    t = (n >= 2 && a[2] ~ /^[a-z][a-z-]*$/ && length(a[2]) <= 12) ? " " a[2] : ""
    return (b == "backend") ? "Docker" t : "Docker " b t
  }
  # Browser/Electron helpers carry their role in --type=; that is what identifies them.
  if (match(cmd, /--type=[a-z-]+/)) {
    t = substr(cmd, RSTART + 7, RLENGTH - 7)
    if (t == "renderer") t = "tab"
    else if (t == "gpu-process") t = "GPU"
    if (cmd ~ /Google Chrome/) return "Chrome " t
    if (cmd ~ /Brave/)         return "Brave " t
    if (cmd ~ /Code Helper/)   return "VS Code " t
    return b " " t
  }
  # Checked before appname() so an automation browser never renders as the real one.
  s = autoprofile(cmd)
  if (s != "") { t = appname(cmd); if (t != "") { sub(/^Google /, "", t); return t " auto · " s } }
  s = appname(cmd); if (s != "") return s
  s = shortid(cmd); if (s != "") return b " · " s
  # A shell spawned for a project directory: the project is the useful name, not "zsh".
  if (b ~ /^(zsh|bash|sh|fish)$/ && match(cmd, /\/Users\/[^ ']*/)) {
    s = substr(cmd, RSTART, RLENGTH); sub(/\/$/, "", s)
    if (bname(s) != "") return b " · " bname(s)
  }
  if (b ~ /^(node|deno|bun|ruby|perl)$/ || b ~ /^python[0-9.]*$/) {
    t = arg1(cmd); if (t != "") return b " " bname(t)
  }
  if (b ~ /^(ssh|docker|git|kubectl|make)$/) { t = arg1(cmd); if (t != "") return b " " t }
  return b
}
