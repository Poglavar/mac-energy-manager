# lib/chrome.awk — Chrome's own subprocesses, split by which Chrome INSTANCE owns them.
#
#   awk -f lib/chrome.awk energy.tsv procs.tsv
#   -> A \t <count of automation-driven instances>
#      H \t pid \t avg \t tab|gpu|util|proc      (helpers of the browser you launched)
#
# There is usually more than one Chrome. The one you opened is parented by launchd; a
# puppeteer / playwright / agent-browser Chrome is a separate instance parented by
# whatever launched it. Mixing them here would be wrong three times over: those
# renderers are not your tabs, the AppleScript tab list cannot see them, and killing
# one would break somebody's automation run mid-flight. They are not dropped from the
# tool — the call tree bills them to their launcher, which is where they belong.

BEGIN { FS = "\t" }

FILENAME == ARGV[1] { E[$1] = $2 + 0; next }
{
  PPID[$1] = $2; CMD[$1] = $5
  if ($5 ~ /Google Chrome\.app\/Contents\/MacOS\/Google Chrome/ && $5 !~ /--type=/) {
    # Launchd-parented and not asking for a debugging port = the browser you launched.
    if ($2 <= 1 && $5 !~ /--remote-debugging-port/) MAIN[$1] = 1; else AUTO++
  }
}

END {
  print "A\t" AUTO + 0
  for (p in CMD) {
    if (CMD[p] !~ /Google Chrome Helper|Google Chrome Framework/ || CMD[p] !~ /--type=/) continue
    if (!(PPID[p] in MAIN)) continue
    type = "proc"
    if (CMD[p] ~ /--type=renderer/) type = "tab"
    else if (CMD[p] ~ /--type=gpu-process/) type = "gpu"
    else if (CMD[p] ~ /--type=utility/) type = "util"
    else continue
    printf "H\t%s\t%.1f\t%s\n", p, E[p] + 0, type
  }
}
