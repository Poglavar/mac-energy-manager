#!/bin/bash
# One-command install: symlink the plugin into SwiftBar's existing plugin folder.
#
# Deliberately a SYMLINK rather than repointing SwiftBar's PluginDirectory at this
# repo. SwiftBar has exactly one plugin folder and runs every file in it, so pointing
# it here would silently disable every other plugin the user has, and would also try
# to execute README.md and .git. A symlink coexists with whatever is already there,
# and `git pull` updates the plugin in place.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$REPO/plugins/energy.10s.sh"
WITH_TIMERS=1
[ "${1:-}" = "--no-timers" ] && WITH_TIMERS=0

[ "$(uname -s)" = Darwin ] || { echo "macOS only (this reads ps, launchd and pmset)." >&2; exit 1; }

if ! [ -d /Applications/SwiftBar.app ] && ! [ -d "$HOME/Applications/SwiftBar.app" ]; then
  echo "SwiftBar is not installed. Install it first:"
  echo "    brew install --cask swiftbar"
  echo "…then run this again."
  exit 1
fi

# SwiftBar stores its plugin folder as a security-scoped bookmark; the plain string is
# only present once the folder has been chosen. If it has not been, pick the standard
# location and let SwiftBar adopt it.
# Overridable so the link path can be exercised without touching real preferences.
DIR="${SWIFTBAR_PLUGIN_DIR:-$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)}"
if [ -z "$DIR" ]; then
  DIR="$HOME/Library/Application Support/SwiftBar"
  mkdir -p "$DIR"
  defaults write com.ameba.SwiftBar PluginDirectory "$DIR"
  echo "no plugin folder was set; using $DIR"
fi
[ -d "$DIR" ] || { echo "SwiftBar's plugin folder does not exist: $DIR" >&2; exit 1; }

# If SwiftBar is already pointed AT this repo's plugins folder, the link target and its
# source are the same file — and `ln -sfn` unlinks the target first, so it would delete
# the plugin and leave a symlink pointing at itself. Detect it and do nothing.
if [ "$(cd "$DIR" && pwd -P)" = "$(cd "$(dirname "$PLUGIN")" && pwd -P)" ]; then
  echo "SwiftBar's plugin folder is already this repo's plugins/ — nothing to link."
  echo "  (that works, but it means SwiftBar can load no other plugins. To switch, point"
  echo "   it at ~/Library/Application Support/SwiftBar in SwiftBar's preferences, then"
  echo "   re-run this.)"
else
  ln -sfn "$PLUGIN" "$DIR/energy.10s.sh"
  echo "linked  $DIR/energy.10s.sh -> $PLUGIN"
fi

if [ "$WITH_TIMERS" = 1 ]; then
  "$REPO/bin/browser-reap" --ttl 30 --orphan-ttl 5 --install 300
  "$REPO/bin/energy-advisor" install 1800
fi

# Ask SwiftBar to re-read the folder rather than making the user restart it.
if pgrep -x SwiftBar >/dev/null 2>&1; then
  open -g "swiftbar://refreshallplugins" 2>/dev/null || true
  echo "SwiftBar refreshed — ⚡ appears within ~10s (the first render says 'collecting…')."
else
  open -a SwiftBar
  echo "SwiftBar started — ⚡ appears within ~10s."
fi
