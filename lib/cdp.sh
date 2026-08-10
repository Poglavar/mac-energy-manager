# lib/cdp.sh — what an automation browser is actually rendering.
#
#   em_cdp_pages <procs.tsv> <out>     profile \t title \t url
#
# The Chrome section lists your tabs over AppleScript, which needs Automation permission
# and — deliberately — cannot see automation-driven browsers at all. Those were therefore
# a dead end in the menu: "N automation-driven Chrome not listed here", with no way to
# tell which of them was burning a core, or on what.
#
# Every Chrome started with --remote-debugging-port writes the port it actually got into
# <user-data-dir>/DevToolsActivePort, so the debug endpoint can be found without knowing
# how it was launched — and `--remote-debugging-port=0` (what agent-browser and Playwright
# use) is exactly the case where the port is otherwise unguessable. `/json/list` then
# names every open page. No permission, no AppleScript, no prompt.
#
# Localhost only, one second of patience, and failures are silent: a browser that is busy,
# starting up, or not listening simply contributes no rows.

em_cdp_pages() {
  local procs="$1" out="$2" dir port
  : > "$out"
  command -v curl >/dev/null 2>&1 || return 0
  # Same discriminator as browser-reap and lib/label.awk: a temp --user-data-dir is what
  # makes a browser automation. These three must never disagree about that.
  awk -F'\t' '
    $5 ~ /--user-data-dir=/ && $5 ~ /[Cc]hrom|headless_shell/ {
      d = $5; sub(/^.*--user-data-dir=/, "", d); sub(/ .*$/, "", d); sub(/\/+$/, "", d)
      if (d ~ /^(\/private)?\/(tmp|var\/folders)\//) print d
    }' "$procs" 2>/dev/null | sort -u | while read -r dir; do
    [ -n "$dir" ] || continue
    port=$(head -1 "$dir/DevToolsActivePort" 2>/dev/null | tr -d ' \r')
    # The port comes from a file inside a world-writable temp directory, so it is
    # untrusted input that decides where we send a request: a bad value would make this
    # a small SSRF gadget against other services listening on loopback. Bound it to a
    # legal non-privileged port, keep the request on 127.0.0.1, and cap the response so
    # a hostile or merely enormous body cannot be read into the render.
    case "$port" in ''|*[!0-9]*) continue ;; esac
    [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || continue
    curl -sS --max-time 1 --max-filesize 262144 --noproxy '*' \
         "http://127.0.0.1:$port/json/list" 2>/dev/null \
      | head -c 262144 | em_cdp_parse "$dir" >> "$out"
  done
  return 0
}

# Chrome pretty-prints /json/list, one field per line, so the pages can be picked out
# without a JSON parser and without paying for a python start on every render. Each
# object ends at its closing brace; only type "page" is a tab a human would recognise.
em_cdp_parse() {
  awk -v dir="$1" '
    function flush(  t) {
      if (type == "page" && title != "") {
        t = title
        gsub(/\\"/, "\"", t); gsub(/\\\\/, "\\", t)
        # A page title is the most attacker-controlled string in the whole tool: any
        # website sets document.title freely. A bare "|" here would become SwiftBar
        # menu parameters — see msafe() in lib/label.awk.
        gsub(/[\t\n\r]/, " ", t);  gsub(/\|/, "¦", t)
        gsub(/[\t\n\r]/, " ", url); gsub(/\|/, "¦", url)
        printf "%s\t%s\t%s\n", dir, t, url
      }
      title = ""; url = ""; type = ""
    }
    /^[[:space:]]*"title":/ { title = value(); next }
    /^[[:space:]]*"type":/  { type  = value(); next }
    /^[[:space:]]*"url":/   { url   = value(); next }
    /^[[:space:]]*[}]/      { flush() }
    END { flush() }
    function value(  s) {
      s = $0
      sub(/^[^:]*:[[:space:]]*/, "", s)
      sub(/,[[:space:]]*$/, "", s)
      gsub(/^"|"$/, "", s)
      return s
    }'
}
