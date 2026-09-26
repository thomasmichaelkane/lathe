#!/bin/sh
# Start aria2 as librariand expects it (librariand/torrents.py).
#
# The RPC secret is read from the compose secret at start, so it never sits in
# the container's environment or its `docker inspect` output.
set -eu

SECRET_FILE=/run/secrets/aria2_rpc_secret
STATE=/state

[ -s "$SECRET_FILE" ] || { echo "aria2: $SECRET_FILE is missing or empty — run install.sh" >&2; exit 1; }
touch "$STATE/session"

# --rpc-listen-all: the RPC has to answer on the container's interface for
# the port published on gluetun to reach it. It is not exposed beyond the Pi:
# the publish is bound to 127.0.0.1, gluetun's firewall drops inbound on the
# VPN tunnel, and every call needs the secret.
#
# --seed-time=0: no seeding (decided 2026-09-26). A download stops as soon
# as its data verifies.
#
# The session file keeps unfinished downloads across restarts. librariand
# matches downloads by directory, not gid, so the new gids aria2 hands out
# after a restart do not matter.
exec aria2c \
  --enable-rpc \
  --rpc-listen-all=true \
  --rpc-listen-port=6800 \
  --rpc-secret="$(cat "$SECRET_FILE")" \
  --dir=/srv/staging/torrents \
  --continue=true \
  --seed-time=0 \
  --bt-save-metadata=false \
  --input-file="$STATE/session" \
  --save-session="$STATE/session" \
  --save-session-interval=30 \
  --dht-file-path="$STATE/dht.dat" \
  --dht-file-path6="$STATE/dht6.dat" \
  --console-log-level=notice \
  --summary-interval=0
