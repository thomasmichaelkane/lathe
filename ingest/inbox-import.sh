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

# Overridable so the local test harness runs this exact script rather than a
# reimplementation of it — the cascade ordering below is the thing most worth
# testing, and a copy in the harness would drift from it.
INBOX="${INBOX:-/srv/inbox}"
QUARANTINE="${QUARANTINE:-/srv/quarantine}"
BEETS_CONFIG="${BEETS_CONFIG:-/srv/config/beets/config.yaml}"
LOG="${LOG:-/srv/logs/inbox-import.log}"

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
PASS_OUT="$(mktemp)"
trap 'rm -f "$REF" "$PASS_OUT"' EXIT

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

# Import twice, one metadata source per pass, MusicBrainz first.
#
# Not a preference — running both sources in one pass is actively broken. beets
# penalises any candidate whose data_source differs from the file's existing
# tag, but only once more than one metadata source plugin is loaded
# (autotag/distance.py, add_data_source). Fresh downloads have no such tag, so
# every candidate from every source takes the penalty, per album AND per track:
# a byte-perfect 13-track Bandcamp release scored 0.1125 instead of 0.0000 and
# quarantined. With one source loaded the guard is false and the penalty never
# applies at all.
#
# So the split is what makes matching correct, and it buys two more things:
# MusicBrainz wins whenever it has the release, by construction rather than by
# a tuned tie-break — which matters because beetcamp writes Bandcamp URLs into
# MUSICBRAINZ_ALBUMID/TRACKID — and Bandcamp is only queried for the remainder.
#
# `import.move: yes` means pass 1 physically removes what it matched, so pass 2
# sees only leftovers. This depends on `incremental_skip_later: yes` in
# config.yaml; without it pass 1 records its skips and pass 2 does nothing.
#
# quiet_fallback: skip means neither pass blocks on a prompt or guesses. Don't
# let a single bad album abort the run — check the exit code instead.
import_pass() {
  local label="$1" disable="$2"
  log "inbox-import: pass — $label"
  if beet -c "$BEETS_CONFIG" -P "$disable" import "$INBOX" >"$PASS_OUT" 2>&1; then
    log "inbox-import: $label finished cleanly"
  else
    log "inbox-import: $label exited non-zero — see $LOG"
  fi
  cat "$PASS_OUT" >>"$LOG"
}

import_pass "MusicBrainz" bandcamp

# A failed MusicBrainz lookup is NOT a failed import as far as beets is
# concerned: a network error is logged and the album is skipped, and `beet
# import` still exits 0. That is harmless in a single-pass setup — the album
# quarantines and you retry it later — but it quietly corrupts the cascade,
# because pass 2 would then happily match everything from Bandcamp and file it
# with bandcamp.com URLs in MUSICBRAINZ_ALBUMID/TRACKID. The album lands in the
# library looking fine, `incremental` records it as done, and the real MBIDs
# are gone from the archive masters for good.
#
# So: if pass 1 could not reach MusicBrainz, stop. Skip pass 2 AND the
# quarantine sweep, and leave everything in the inbox exactly as it is.
# `incremental_skip_later: yes` means nothing was recorded, so the next run
# retries the whole batch cleanly.
if grep -qiE 'musicbrainz: Error|Max retries exceeded|Read timed out' "$PASS_OUT"; then
  log "inbox-import: MusicBrainz was unreachable during pass 1."
  log "inbox-import: ABORTING before the Bandcamp pass — importing now would"
  log "inbox-import: file MusicBrainz-catalogued releases as Bandcamp ones."
  log "inbox-import: inbox left untouched; re-run when MusicBrainz is back."
  exit 1
fi

import_pass "Bandcamp" musicbrainz

# Whatever beets declined to match is still sitting here. Move it aside so the
# next trigger doesn't retry it indefinitely, and so it shows up for review.
# Loose FILES count, not just directories. Bandcamp hands you a bare .flac for
# a single-track release — no folder, and no ALBUM tag either, so it is exactly
# the kind of thing that never matches. Sweeping only directories left those
# sitting in the inbox to be retried on every trigger forever, which
# `incremental_skip_later: yes` now guarantees rather than merely risks.
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
done < <(find "$INBOX" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) -print0)

# Anything left is an empty directory beets emptied as it moved files out.
find "$INBOX" -mindepth 1 -type d -empty -delete 2>/dev/null || true

log "inbox-import: done — $moved unmatched moved to quarantine"
