# lib/agents.awk — the coding-agent processes running inside a terminal.
#
# Name-agnostic on purpose: it walks DOWN from every terminal emulator rather than
# matching a list of binaries, so any agent (claude, codex, copilot, aider, …) and any
# unknown heavy descendant shows up. agent_re only decides whether a *quiet* process is
# still worth listing; anything busy is listed regardless of what it is called.
#
# Rooting this at cmux alone would have made the whole section empty for anyone not
# using it, while the README claimed the tool was general.
#
#   awk -f lib/label.awk -f lib/agents.awk energy.tsv procs.tsv tabs.tsv
#   -> pid \t avg \t label \t cmd     (unsorted; the caller ranks)
#
# tabs.tsv (lib/cmux_tabs.py) is optional — pass /dev/null and the labels fall back to
# session ids rather than tab names.

BEGIN { FS = "\t"; if (min_cpu == "") min_cpu = 1.0 }

FILENAME == ARGV[1] { E[$1] = $2 + 0; next }
FILENAME == ARGV[3] { TAB[$1] = $2; next }
{
  PP[$1] = $2 + 0; CMD[$1] = $5
  # Terminal emulators, as the roots to search down from. The cmux bundle name is NOT
  # fixed — dev builds ship as "cmux <Branch>.app" in Downloads — so it is matched by
  # path shape rather than literally, which is why the pattern looks like that.
  if ($5 ~ /\.app\/Contents\/MacOS\/(cmux|Terminal|iTerm2?|Ghostty|Alacritty|kitty|WezTerm|Warp|Hyper|Tabby)( |$)/ \
      || $5 ~ /(^|\/)(alacritty|kitty|wezterm-gui|foot|st|urxvt)( |$)/) { mark[$1] = 1; isroot[$1] = 1 }
}

END {
  for (it = 0; it < 25; it++) {                       # flood-fill down from the terminal roots
    ch = 0
    for (i in PP) if (!mark[i] && mark[PP[i]]) { mark[i] = 1; ch = 1 }
    if (!ch) break
  }
  for (i in PP) {
    if (!mark[i] || (i in isroot)) continue
    c = CMD[i]
    if (c ~ /cmux hooks|MacOS\/cmux|cmux\.app\/Contents\/Frameworks/) continue   # cmux's own infra
    b = bname(argv0(c)); sub(/^-/, "", b)
    if (b ~ /^(zsh|bash|sh|login|tmux|screen)$/) continue                        # wrapper shells
    if (b ~ agent_re || E[i] >= min_cpu) printf "%s\t%.1f\t%s\t%s\n", i, E[i], mklabel_tab(c), c
  }
}
