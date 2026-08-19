#!/usr/bin/env bash
# Import everything sitting in /srv/inbox into the library.
#
# Runs as the `music` user, triggered by inbox.path. Deployed to
# /usr/local/bin/inbox-import.sh
#
# Two things this handles that a bare `beet import` does not:
#
#   1. It waits for the inbox to stop changing. Path units fire on the first
#      change, so a long copy would otherwise be imported half-finished.
#      Uploads should stage in /srv/staging/incoming and be moved in atomically
#      (see push-music.sh), but this is the safety net for when they aren't.
#
#   2. It sweeps what beets refused into quarantine. `quiet_fallback: skip`
#      leaves unmatched albums where they are, so without this they'd sit in
#      the inbox and be retried forever on every subsequent trigger.

set -euo pipefail

INBOX=/srv/inbox
QUARANTINE=/srv/quarantine
BEETS_CONFIG=/srv/config/beets/config.yaml
LOG=/srv/logs/inbox-import.log

# Seconds the inbox must be unmodified before we treat the copy as finished.
SETTLE_SECONDS="${SETTLE_SECONDS:-120}"
# Give up waiting eventually rather than blocking the unit forever.
SETTLE_TIMEOUT="${SETTLE_TIMEOUT:-7200}"

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

# Nothing to do. The unit can be triggered by a delete as easily as a create.
if [ -z "$(find "$INBOX" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
  exit 0
fi

log "inbox-import: waiting for $INBOX to settle (${SETTLE_SECONDS}s quiet)"

REF="$(mktemp)"
trap 'rm -f "$REF"' EXIT

waited=0
while :; do
  # Anything modified more recently than SETTLE_SECONDS ago means a copy is
  # still in flight.
  #
  # Deliberately a reference file with POSIX `-newer`, NOT `-newermt "-120
  # seconds"`: the relative-time form is a GNU findutils extension that other
  # find implementations reject. Getting that wrong fails towards "no results",
  # which reads as "settled" and imports mid-copy — the exact bug this loop
  # exists to prevent. Errors are NOT suppressed here for the same reason.
  #
  # -print -quit stops at the first hit rather than walking the whole tree,
  # which matters when the inbox holds a few hundred albums.
  touch -d "@$(( $(date +%s) - SETTLE_SECONDS ))" "$REF"

  if ! recent="$(find "$INBOX" -mindepth 1 -newer "$REF" -print -quit)"; then
    log "inbox-import: FAILED to test for recent changes — aborting rather than"
    log "inbox-import: risking an import of a half-copied album"
    exit 1
  fi
  [ -z "$recent" ] && break

  if [ "$waited" -ge "$SETTLE_TIMEOUT" ]; then
    log "inbox-import: still changing after ${SETTLE_TIMEOUT}s, importing anyway"
    break
  fi
  sleep 15
  waited=$((waited + 15))
done

before="$(find "$INBOX" -mindepth 1 -maxdepth 1 -type d | wc -l)"
log "inbox-import: importing $before directories"

# quiet_fallback: skip means this never blocks on a prompt, and never guesses.
# Don't let a single bad album abort the run — check the exit code instead.
if beet -c "$BEETS_CONFIG" import "$INBOX" >>"$LOG" 2>&1; then
  log "inbox-import: beets finished cleanly"
else
  log "inbox-import: beets exited non-zero — see $LOG"
fi

# Whatever beets declined to match is still sitting here. Move it aside so the
# next trigger doesn't retry it indefinitely, and so it shows up for review.
moved=0
while IFS= read -r -d '' leftover; do
  name="$(basename "$leftover")"
  dest="$QUARANTINE/$name"
  # Never clobber an existing quarantine entry from an earlier run.
  if [ -e "$dest" ]; then
    dest="$QUARANTINE/${name}.$(date +%Y%m%d%H%M%S)"
  fi
  mv -- "$leftover" "$dest"
  moved=$((moved + 1))
done < <(find "$INBOX" -mindepth 1 -maxdepth 1 -type d -print0)

# Tidy up files beets left loose in the inbox root, and any empty dirs.
find "$INBOX" -mindepth 1 -type d -empty -delete 2>/dev/null || true

log "inbox-import: done — $moved unmatched moved to quarantine"
