#!/usr/bin/env bash
# Push albums from this machine to the server's inbox.
#
# Runs on the LAPTOP, not the Pi. Everything else in this directory runs on
# the server; this is the one client-side tool, kept here so the upload
# convention lives next to the thing that consumes it.
#
# Usage:
#   ./push-music.sh ~/albums/                 # everything under a folder
#   ./push-music.sh ~/albums/Some\ Album      # one album
#   MUSIC_HOST=lathe.tailnet-name.ts.net ./push-music.sh ~/albums/
#
# Why two stages rather than rsync straight into /srv/inbox:
#
#   /srv/inbox is watched by a systemd path unit that fires on the FIRST
#   change, not when the copy finishes. rsync-ing 30 albums directly would
#   start the import while files were still arriving — beets would import a
#   partial album, or move files out from under rsync mid-write.
#
#   So we rsync into /srv/staging/incoming (unwatched), then move into
#   /srv/inbox. Both are on the same filesystem, so the move is atomic and
#   directories appear complete or not at all. Same principle as farfetchd
#   writing fetch.json last.

set -euo pipefail

HOST="${MUSIC_HOST:-lathe}"
INCOMING=/srv/staging/incoming
INBOX=/srv/inbox

if [ $# -lt 1 ]; then
  echo "usage: $(basename "$0") <path> [path...]" >&2
  exit 1
fi

for src in "$@"; do
  [ -e "$src" ] || { echo "error: no such path: $src" >&2; exit 1; }
done

echo "Uploading to $HOST:$INCOMING"

# --chmod forces group-writable so the `music` user can move and delete these
# during import. Without it, files arrive owned by you and beets fails.
#
# --no-group is the other half, and -a silently undoes it without this: -a
# includes -g, which sets each file's group to the one it had on the laptop.
# You are a member of your own group on the Pi too, so rsync is allowed to,
# and the setgid bit on staging/incoming — which is what makes uploads
# group-owned by `music` — is overridden on every file and folder. beets then
# cannot move files out of folders it does not own, and the quarantine sweep
# cannot rename them. With --no-group they inherit `music` from the setgid
# directory, as intended.
# --partial keeps progress on a dropped connection; the staging directory is
# unwatched, so half-transferred files there are harmless.
rsync -a \
  --no-group \
  --info=progress2 \
  --partial \
  --chmod=Dg+rwxs,Fg+rw \
  --exclude='.DS_Store' \
  --exclude='Thumbs.db' \
  --exclude='*.tmp' \
  "$@" "$HOST:$INCOMING/"

echo "Transfer complete. Moving into $INBOX (atomic)..."

# find|mv rather than a glob so this doesn't break on an empty staging dir or
# on names with spaces. -maxdepth 1 moves whole album directories intact.
ssh "$HOST" "find '$INCOMING' -mindepth 1 -maxdepth 1 -exec mv -t '$INBOX' -- {} +"

echo "Done. The import will start once $INBOX settles."
echo "Watch it with:  ssh $HOST 'journalctl -fu inbox-import.service'"
