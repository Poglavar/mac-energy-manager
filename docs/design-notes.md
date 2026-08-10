# Design notes

Why the parts that look over-engineered are the size they are. Each section below exists
because something silently produced *plausible wrong output* until it was handled — which
is the failure mode a monitoring tool must not have, since nobody double-checks a number
that looks reasonable.

## The process tree has to be rebuilt, not read

macOS does three things that break a naive `ppid` walk, and all three are common on a
developer machine.

**Reparenting.** When a parent exits, macOS hands its children to `launchd`. A heavy
worker then looks like its own top-level app with no clue where it came from — and the
build that spawned it disappears from the accounting entirely. Each cycle records who
spawned whom in `~/.cache/energy-manager/parents.tsv`, keyed on **both** processes' start
times, and the tree is rebuilt from that memory. The start times are what stop a recycled
pid from grafting a subtree onto a stranger: pids wrap, and a wrong graft is not a missing
row, it is a confident lie about which of your projects is burning a core.

**XPC services.** Docker's Linux VM is parented by `launchd`, not by Docker, so no amount
of ppid-walking reaches it. It is adopted into the Docker tree by name.

**Automation browsers.** A browser an agent launches detaches to `launchd` within
*milliseconds* — far inside the sampling interval. Unlike ordinary reparenting there is no
edge for the memory above to have witnessed, so no poller can ever recover it. The owner
has to be written down at launch. See the README's automation-browser section.

## Docker database attribution is causal, not ancestral

A process doing expensive work *through* Postgres is not Docker's ancestor in the OS tree,
so the process forest alone will never connect them. When a container publishes Postgres to
the Mac, established TCP sockets are matched back to host pids and drawn as a separate
causal link:

```
cmux › codex › node api.js  ⇢  Postgres · my-project-db-1  →  Docker
                             DB client (causal, not a ppid)
```

The evidence rules are deliberately narrow:

- An established socket proves a process **is a database client**, not that its last query
  caused all current Docker CPU. One client while Postgres is hot is strong evidence;
  several idle connection pools are inherently ambiguous and are labelled as such rather
  than guessed between.
- The link **never** changes process totals or *Stop whole tree*, so stopping a cmux tree
  cannot accidentally stop Docker.
- Both `docker` and `lsof` have two-second hard timeouts. Docker being stopped or wedged
  can never make SwiftBar miss a refresh.
- Docker Desktop rewrites TCP source ports across its VM, so `pg_stat_activity.client_port`
  cannot be joined to the macOS socket directly. That is why this uses sockets, not SQL.

## SwiftBar failure modes the render is shaped around

These are not hypothetical; each cost a debugging session.

**An empty render can hide the menu-bar item permanently.** If a plugin's first render
takes seconds, the item briefly has empty content, SwiftBar hides it, and macOS persists
`NSStatusItem VisibleCC = 0` — the ⚡ then *never* comes back, even across restarts. So the
first render under a fresh SwiftBar paints a minimal menu in under 200 ms and skips the
expensive sections; full data resumes on the next cycle. For the same reason, a missing
`lib/` prints a loud error menu rather than exiting silently.

**A successful render can still arrive as an empty string.** SwiftBar 2.1 occasionally
finishes a large render successfully yet retains empty stdout, which leaves the number in
place but replaces the dropdown with SwiftBar's generic menu. The real render therefore
runs in a child whose stdout goes to a file, and the completed payload is published in one
atomic move. A failed or empty refresh reuses the last good payload.

**One malformed byte discards the whole menu.** SwiftBar decodes the payload as strict
UTF-8, and process names and browser titles are external input. The payload is passed
through `iconv -c` so a single bad byte costs one character rather than the entire menu.
Truncation happens in a UTF-8 subshell even though the collectors run under `LC_ALL=C`,
because byte-slicing an en dash produces exactly that malformed byte.

**Attempting AppleScript without permission poisons the run.** Merely *calling* osascript
for Chrome tabs before Automation permission is granted makes SwiftBar receive empty
output and hide the item. So renders never touch AppleScript until the permission has been
proven good and recorded in `~/.cache/energy-manager/chrome-ok`, and even then a 3 s alarm
caps it. Killing Chrome processes needs no permission and always works.

**Rows carrying only a submenu lose their action on an incremental update** unless they
set a colour of their own — which is why parent rows all specify `color=black,white`.

## Editing a plist does not change a loaded job

launchd keeps serving the definition it was given at bootstrap time. Rewriting the file
changes nothing, and `launchctl list` still shows a healthy `LastExitStatus 0`, so nothing
looks wrong. `browser-reap` spent hours in exactly that state: registered, never firing,
while a 183% Chrome sat at the top of the energy monitor through its entire TTL.

Both `--install` paths therefore `bootout` and `bootstrap`, and verify from
`launchctl print` rather than from the file they just wrote.

## Why the LLM advisor was deleted

It asked a model "is anything wrong?" every five minutes with a sanitized snapshot. Across
**2,824 runs it wanted to warn 741 times (26%)**; a confidence gate and cooldown let 20
through. Every one was either a leaked automation browser or Postgres doing its job, and
none was ever acted on.

The replacement is two thresholds. The lesson generalises: a detector whose output cannot
be reproduced, tested, or deliberately made to fail is not a detector, and `confidence:
0.82` is not a substitute for a rule you can read. Both triggers are unit-tested, and each
test has been checked to go red when its rule is broken.

The old version also collected more context than any threshold needs — including, behind
an opt-in flag, the last twelve lines of the focused terminal. That is deleted rather than
left switched off, because collected data has a way of becoming used data.

## Averages, and why the ranking uses one

Ranking on instantaneous CPU makes the menu useless: it reorders every 10 seconds, and
whatever you wanted to click has moved. Ranking on `ps` `pcpu` is worse, because that is a
*lifetime* average — an agent idle for the last ten minutes still reports as busy, forever.

The rolling 10-minute window is the compromise: a spike barely moves it, a sustained hog
stays at the top, and something that just calmed down remains visible long enough to
catch. Both numbers are shown (`avg 10m · now`) because the gap between them is itself
information — `12.8 · 127.5` is something that just started.

The same reasoning is why alerts require a condition to be **sustained across consecutive
runs**: a mean hides the extreme, and a single sample is not a trend.

## Five ways to name the owner of an orphan, and why there are five

`browser-stamp` is exact but needs the launcher's cooperation, and most launchers will
never give it — Playwright, Puppeteer, a script somebody wrote last year. So the tree is
rebuilt from whichever of these answers, strongest first:

| rank | signal | evidence | resolves to |
|---|---|---|---|
| 1 | **launch stamp** | written by us, at the only moment the link exists | the exact session |
| 2 | **remembered parent** | an edge the sampler actually witnessed | the real parent |
| 3 | **environment** | copied at `fork()`, never rewritten | the exact session |
| 4 | **responsible process** | macOS maintains it for TCC | the app |
| 5 | **process group** | inherited, unless something called `setsid()` | the group leader |
| 6 | **cmux fallback** | the narrowest thing provable by name | cmux |

Ordering is by *how much the evidence proves*, not by how convenient it is. A witnessed
edge outranks an inherited variable because the variable names the session that started
the chain rather than the immediate parent; both outrank a TCC record that only ever
names an app.

**Every rung carries the same recycle guard**: the claimed owner must still be alive AND
its start time must still match. Without that, a pid recycled into some unrelated process
inherits a fifty-process browser tree, and the result is not a missing row — it is a
confident lie about which of your projects is burning a core.

Two findings shaped the implementation more than the design did:

- **Probing everything was 90% waste and produced false edges.** Apple's daemons are
  launchd-parented *by design*; being an orphan is their normal state, not a lost chain.
  Probing them cost 3.3 s per render and cheerfully traced `SafariPlatformSupport` back to
  Finder. Skipping anything under `/System`, `/usr/libexec` and friends took it to 190 ms
  and left only edges worth drawing.
- **A cache that does not remember misses is not a cache.** The first version re-probed
  every unresolvable orphan on every render: 3.0 s warm against 3.3 s cold. Caching the
  misses too took the warm path to 40 ms.

The rung that was considered and **rejected**: parsing the owner pid out of a
`browser-stamp` profile name (`6592-passagediag2`). It only yields a pid with no start
time, so it cannot be recycle-guarded like every other rung — and it only ever applies to
browsers that stamped, which by definition already have a better record. An unguardable
path covering a case that is already covered is not worth its risk.

## One Stop, not a SIGTERM/SIGKILL choice

Every kill affordance used to be two menu items. That is the wrong shape, because the two
signals are not alternatives:

- **SIGTERM** is catchable. The process runs its handler — flushes buffers, releases
  locks, saves state — and exits. It can also ignore it.
- **SIGKILL** cannot be caught, blocked or ignored. The kernel destroys the process and no
  code of its own ever runs.

So SIGKILL is not "the same thing but harder", it is "give up on cleanup". On Chrome that
is free — a killed renderer shows "Aw, Snap" and reloads the tab with its state. On
Postgres it means no clean shutdown and crash recovery on next start. On an editor it is
unsaved work.

Presenting them side by side made the user perform the escalation by hand, and the fast
path visually was the destructive one: when something is eating a core you are impatient,
and "Force kill" is right there in red. One action that tries TERM, waits ~2.5 s, and
escalates only if the process is still alive gets the safe behaviour by default and the
guaranteed behaviour anyway. `docker stop`, systemd's `TimeoutStopSec` and macOS logout
all work exactly this way.

The wait is bounded and polled every 100 ms, so the overwhelming majority of stops still
complete in about 20 ms; only a process that actually ignores SIGTERM pays the full 2.5 s.

**A silent action is an action that did nothing.** SwiftBar closes the menu the moment a
`bash=` row runs, and `keepopen=true` does not reliably prevent it, so the user is returned
to the desktop with no evidence the click registered — while the escalation can still be
running for 2.5 s. Combined with a target the browser respawns, that produced the exact
report this section exists because of: "pressing stop doesn't work".

Feedback goes through SwiftBar's own `swiftbar://notify`, not `osascript`: an osascript
notification belongs to Script Editor, so clicking it launches Script Editor. The shape is
chosen so the common case is not noisy — a clean stop is one notification, and a second one
appears only when the stop is slow enough to need acknowledging:

| outcome | notifications |
|---|---|
| stopped within 300 ms | one, `Stopped <label>` |
| still alive at 300 ms | `Stopping <label>…`, then `Force-stopped` or `Could not stop` |
| shared browser service | one, `Restarted <label>` — never "Stopped" |

The label comes from the same `mklabel()` the menu row used, so the notification and the row
cannot disagree. It is read *before* the signal, because afterwards there is nothing left to
read. And it is percent-encoded on the way into the URL: a process chooses its own name, so
an unencoded one could carry `&body=` and rewrite the notification it appears in.

**A supervised child is not a stoppable process.** A browser's GPU, network and storage
services are *shared*: their cost is the sum of every tab's demand, and the browser process
supervises them, so a kill is undone before the menu can redraw. Measured on a real Chrome:
`SIGTERM` to a gpu-process at 110% CPU, and 2 s later a new gpu-process at 106%. The button
had worked perfectly and looked completely broken, because the row said "Stop process" —
the same words as on a renderer, where a kill really does stick.

Two consequences, both in the code:

- Renderers get **Stop this tab**; services get **Restart this service** plus a line saying
  the browser respawns it at once. Killing a wedged GPU process is a real remedy, so the
  action stays — it just no longer promises to reduce load.
- `hotspots()` in `lib/tree.awk` never lets a shared service take a tree's `→` slot while a
  non-service candidate exists, even a much cheaper one. Naming the GPU process answers
  "what is burning this?" with the one process that cannot be the cause. Services are still
  reported, with their real cost, behind the culprits.

**Why the tool cannot name the tab that is burning your CPU.** It is asked constantly, and
the honest answer is that the mapping does not exist outside the browser. A renderer's argv
carries only `--renderer-client-id`, an internal counter; its open files are fonts, ICU data
and dyld; renderers own no sockets, because the network service does. Chrome's AppleScript
dictionary gives a tab's title, URL and loading flag — no pid and no cost. So the menu can
list tabs by name and it can rank processes by cost, but joining the two would require a
debug port on your real profile (which would hand every local process your logged-in
sessions) or a browser extension. Both are worse than the problem. What *does* identify a
tab is stopping its renderer: the tab visibly breaks, and reloads when you return to it.

**Automation permission is per calling app**, which makes the marker file subtle. The same
`osascript` SwiftBar is allowed to run is refused with `-1743` from a terminal, from the
test suite, or over ssh. So a failure only means the grant is gone when the failure happens
under SwiftBar; anywhere else it says nothing, and retracting the marker would let a single
hand-run destroy a working setup. The grant is also not permanent — revoking it in System
Settings leaves the marker behind, and this tool then believed tab listing worked for
eighteen days while rendering an empty "Tabs" heading, with the re-enable prompt unreachable
because the marker was still there. Trust the marker, but let SwiftBar revalidate it.

**Coding agents keep two items**, because there the pair is not an escalation but two
different intentions: SIGINT is Ctrl-C, which cancels the current turn and leaves the
agent running, while quitting ends the session. Collapsing those would silently kill an
agent when the user only meant to interrupt it.

There is no way to put an inline button or icon at the end of a SwiftBar row — a line is
text plus at most one action — and making the row itself the kill target was rejected:
those rows are what you click to open a call tree, so a misclick would stop a
hundred-process tree.

## The menu format is a serialization format, so it needs escaping

A SwiftBar line is `text | key=value key=value`, and **parameters begin at the first
`|`**. Two of those keys — `bash=` with `param1=`, and `href=` — make a row execute
something when clicked. So any `|` inside text that reaches a menu line is not a
cosmetic bug; it is a menu item that runs an attacker's command.

The text on those lines is external input, and one source of it is fully remote:

- a **web page** controls `document.title`, which reaches the menu through the Chrome
  tab list and through CDP;
- **any process** can `exec` with a chosen `argv[0]`, which reaches it as a label;
- **container names**, **cmux tab titles** and **command lines** likewise.

This was verified exploitable end to end before it was fixed: a process named
`evilproc | bash="/usr/bin/touch" param1="/tmp/em-pwned" terminal=false` rendered as a
working menu item. `ps` escapes newlines and tabs to `\012`/`\011` — which is why row
injection into the TSV is *not* possible, checked and confirmed — but it leaves `|`
alone.

Three layers now, deliberately overlapping:

1. **`msafe()` in `lib/label.awk`**, applied inside `mklabel()`, so every label is safe
   wherever it goes — menu, graph, JSON. One door rather than eleven call sites.
2. **`msafe()`/`trunc()` in the plugin** for text that is not a label: titles, page
   names, alert bodies, profile names.
3. **A publish guard.** Before the rendered payload is handed to SwiftBar, every row
   that can run something is checked to point at this repo or at `/usr/bin/open`. A
   future edit that forgets to sanitise now breaks visibly instead of quietly becoming
   an exploit.

The same reasoning covers the action handlers, which are the only code here that takes
an argument and does something irreversible. Signals are a whitelist, pids are integers
in range, Chrome window/tab indices are integers *because they are pasted into an
AppleScript source string*, `open` accepts only `x-apple.systempreferences:` URLs, and
the mode must be one that exists. The intended caller is our own menu — but "the caller
is us" stops being true the moment a rendering bug lets external text through, and that
is exactly the bug being defended against.

## Binding to 127.0.0.1 does not make a local server private

The graph server serves the process list *and full command lines*, which routinely
carry API keys and tokens. It binds loopback and echoes CORS only to anchored localhost
origins — and that was still not enough.

In a **DNS-rebinding** attack the victim loads a page from `evil.example` while that
name still resolves to the attacker, and the name is then re-resolved to `127.0.0.1`.
The browser now considers `http://evil.example:8787` *same-origin* with this server, so
no CORS check ever runs. Confirmed against the running server: a request with a forged
`Host` returned 200.

The fix is to validate the name the client used, because a rebound request necessarily
carries the attacker's hostname in `Host`. Only `localhost`, `127.0.0.1` and `[::1]` are
accepted; anything else gets 403. A CSP of `default-src 'none'` with `connect-src
'self'` is layered on top, so even a future escape from the page's textContent-only
rendering could not send the process list anywhere.

## Dependencies, and the ones that are deliberately absent

There is **no package manager anywhere in this project** — no npm, pip, gem or cargo,
no lockfile, no vendored library. Everything is the shell, `awk`, and the Python that
ships with macOS. For a tool that reads every process on the machine and can kill them,
that is the single largest security decision in the repo: there is no transitive
dependency to be compromised, and nothing to keep patched.

What it does depend on, and what happens without each:

| Dependency | Needed for | Absent |
|---|---|---|
| SwiftBar | the menu bar itself | required |
| `ps`, `awk`, `bash` | everything | required (all in the base OS) |
| `python3` | alerts, tab names, attribution, the graph | those features skip; the menu is unaffected |
| `curl` | reading automation-browser pages | pages show as unknown |
| `osascript` | Chrome tab titles | tabs are not listed; killing still works |
| `docker`, `lsof` | database attribution | no causal links |
| cmux, agent-browser | nicer names, stamped ownership | coarser attribution |

`python3` deserves its own note: `/usr/bin/python3` on a Mac without the Xcode Command
Line Tools is a **stub whose only behaviour is to pop a GUI installer prompt**, and
`command -v` reports it as present. Invoking it naively would have thrown a modal at a
new user every ten seconds. `em_python()` prefers a real interpreter elsewhere on PATH
and falls back to the system one only when the tools are genuinely installed.
