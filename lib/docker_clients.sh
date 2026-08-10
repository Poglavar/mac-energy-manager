# lib/docker_clients.sh — live readers for Docker database-client attribution.
# Sourced by the SwiftBar plugin and the fullscreen graph; never executed directly.

# em_docker_db_clients <out>
#
# Docker and lsof both get hard two-second ceilings. Docker Desktop being stopped,
# wedged, or unavailable must not delay (or erase) the menu-bar render.
em_docker_db_clients() {
  local out="$1" docker_rows="$1.docker.$$" lsof_rows="$1.lsof.$$"
  : > "$out"
  command -v docker >/dev/null 2>&1 || return
  command -v lsof >/dev/null 2>&1 || return

  perl -e 'alarm 2; exec @ARGV' docker ps \
    --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}' > "$docker_rows" 2>/dev/null || {
      rm -f "$docker_rows" "$lsof_rows"
      return
    }
  if [ -s "$docker_rows" ]; then
    # One lsof pass covers every published Postgres port. The awk parser matches only
    # remote endpoints that Docker reported, so unrelated TCP connections never leak
    # into the causal-link file.
    perl -e 'alarm 2; exec @ARGV' lsof -nP -iTCP -sTCP:ESTABLISHED -Fpcn \
      > "$lsof_rows" 2>/dev/null || true
    awk -f "$REPO/lib/docker_clients.awk" "$docker_rows" "$lsof_rows" > "$out"
  fi
  rm -f "$docker_rows" "$lsof_rows"
}
