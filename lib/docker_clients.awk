# lib/docker_clients.awk — connect Docker-published database ports to host processes.
#
# Inputs:
#   docker.tsv   docker ps --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}'
#   lsof.fields  lsof -nP -iTCP -sTCP:ESTABLISHED -Fpcn
#
# Output:
#   client-pid \t container-id \t container-name \t db-kind \t host-port
#              \t socket-count \t distinct-client-count
#
# Docker Desktop's VM is deliberately detached from the process that talks to a
# database inside it, so this is causal evidence rather than process ancestry.  The
# parser only uses the client-facing half of an established host TCP connection;
# Docker's own proxy sockets are excluded.

BEGIN { FS = "\t"; OFS = "\t" }

FILENAME == ARGV[1] {
  id = $1; name = $2; ports = $4
  n = split(ports, part, /, */)
  for (i = 1; i <= n; i++) {
    if (part[i] !~ /->5432\/tcp$/) continue
    host = part[i]
    sub(/->.*/, "", host)
    sub(/^.*:/, "", host)
    if (host !~ /^[0-9]+$/) continue
    key = host SUBSEP id
    if (!(key in PORT_SEEN)) {
      PORT_SEEN[key] = 1
      PORT_IDS[host] = PORT_IDS[host] " " id
      CNAME[id] = name
      KIND[id] = "Postgres"
    }
  }
  next
}

FILENAME == ARGV[2] {
  tag = substr($0, 1, 1)
  value = substr($0, 2)
  if (tag == "p") { pid = value + 0; comm = ""; next }
  if (tag == "c") { comm = value; next }
  if (tag != "n" || pid <= 1 || value !~ /->/) next
  if (tolower(comm) ~ /^(com\.docker|docker|vpnkit)/) next

  remote = value
  sub(/^.*->/, "", remote)
  sub(/^.*:/, "", remote)
  sub(/[^0-9].*$/, "", remote)
  if (!(remote in PORT_IDS)) next

  m = split(PORT_IDS[remote], ids, " ")
  for (i = 1; i <= m; i++) {
    id = ids[i]
    if (id == "") continue
    key = pid SUBSEP id SUBSEP remote
    SOCKETS[key]++
    CLIENT[id SUBSEP pid] = 1
  }
  next
}

END {
  for (key in CLIENT) {
    split(key, a, SUBSEP)
    CLIENTS[a[1]]++
  }
  for (key in SOCKETS) {
    split(key, a, SUBSEP)
    pid = a[1]; id = a[2]; host = a[3]
    print pid, id, CNAME[id], KIND[id], host, SOCKETS[key], CLIENTS[id]
  }
}
