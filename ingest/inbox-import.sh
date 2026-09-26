#!/usr/bin/env bash
# Import everything sitting in /srv/inbox into the library.
#
# Runs as the `music` user, triggered by inbox.path. Deployed to
# /usr/local/bin/inbox-import.sh
#
# Three things this handles that a bare `beet import` does not:
#
#   1. It waits for the inbox to stop changing. Path units fire on the first
#      change, so a long copy would otherwise be imported half-finished.
#      Uploads should stage in /srv/staging/incoming and be moved in atomically
#      (see push-music.sh), but this is the safety net for when they aren't.
#
#   2. It sweeps what beets refused into quarantine. `quiet_fallback: skip`
#      leaves unmatched albums where they are, so without this they'd sit in
#      the inbox and be retried forever on every subsequent trigger.
#
#   3. It reports the outcome, because it is the only thing that knows it
#      (§6.4). autorip.sh ejects the disc and pushes only failures, on the
#      stated understanding that "a successful rip is announced by
#      inbox-import.sh once the import finishes" — this is that half. Reporting
#      here rather than in the ripper is also what gets manual drops and
#      approved fetches the same notification, instead of only rips.

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
# How often to look again while waiting. Overridable so the test harness does
# not sit through fifteen-second sleeps.
SETTLE_POLL="${SETTLE_POLL:-15}"

# Notification settings. All optional, all empty by default, and all supplied
# by /etc/default/lathe via the unit's EnvironmentFile — never from the repo,
# because the ntfy topic and the Navidrome password are both live credentials.
#
# Empty means "skip that step quietly". A server with no topic set still
# imports; it just says nothing, which is the right failure mode for a
# notification.
NTFY_URL="${NTFY_URL:-}"
NAVIDROME_URL="${NAVIDROME_URL:-}"
NAVIDROME_USER="${NAVIDROME_USER:-}"
NAVIDROME_PASS="${NAVIDROME_PASS:-}"

# Names to list in the push before collapsing the rest into a count. A 300-album
# migration should not arrive as a 300-line notification.
NOTIFY_MAX_NAMES="${NOTIFY_MAX_NAMES:-10}"

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG"; }

# A push is a courtesy, never a reason to fail an import that already succeeded:
# every failure here is logged and swallowed. Note the `|| log` rather than a
# bare `|| true` — a silent notifier that has been broken for a month is worse
# than no notifier, because you have stopped watching the journal for it.
# Keep titles ASCII. The title crosses as an HTTP header, and headers are
# ISO-8859-1 by spec, so a UTF-8 em dash arrives on the phone as mojibake.
# Measured against a real request. The body has no such limit, being a body.
notify() {
  local title="$1" priority="$2" body="$3"
  [ -n "$NTFY_URL" ] || return 0
  curl -fsS --max-time 10 \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -d "$body" "$NTFY_URL" >/dev/null 2>&1 \
    || log "inbox-import: ntfy push failed (not delivered: $title)"
}

# Navidrome rescans on a schedule and watches the filesystem, so this only buys
# latency — seconds instead of up to six hours. It is deliberately not fatal:
# the album is already in the library either way, and the next scheduled scan
# will find it.
#
# Subsonic token auth, which is what Navidrome speaks: t=md5(password+salt) with
# the salt sent alongside, so the password itself never goes over the wire. It
# is still a real password in /etc/default/lathe — hence 0600 there.
navidrome_rescan() {
  if [ -z "$NAVIDROME_URL" ] || [ -z "$NAVIDROME_USER" ] || [ -z "$NAVIDROME_PASS" ]; then
    log "inbox-import: no Navidrome credentials set — leaving the rescan to the schedule"
    return 0
  fi

  local salt token
  salt="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  token="$(printf '%s' "${NAVIDROME_PASS}${salt}" | md5sum | cut -d' ' -f1)"

  if curl -fsS --max-time 15 --get \
      --data-urlencode "u=$NAVIDROME_USER" \
      --data-urlencode "t=$token" \
      --data-urlencode "s=$salt" \
      --data-urlencode "v=1.16.1" \
      --data-urlencode "c=lathe" \
      --data-urlencode "f=json" \
      "${NAVIDROME_URL%/}/rest/startScan" >/dev/null 2>&1; then
    log "inbox-import: Navidrome rescan triggered"
  else
    log "inbox-import: Navidrome rescan poke failed — new albums will appear on the next scheduled scan"
  fi
}

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
  sleep "$SETTLE_POLL"
  waited=$((waited + SETTLE_POLL))
done

# The same extensions quarantine.py counts as audio. Used only to tell "beets
# took the music and left the clutter" apart from "there was never any music".
has_audio() {
  [ -n "$(find "$1" -type f \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' \
      -o -iname '*.ogg' -o -iname '*.opus' -o -iname '*.wav' -o -iname '*.wv' \
      -o -iname '*.ape' \) -print -quit)" ]
}

# SNAPSHOT what this run is responsible for, and touch nothing else.
#
# This used to import "$INBOX" and then sweep whatever was left in it. Anything
# that arrived while beets was running — a rip finishing during an hours-long
# bulk import, an approved fetch — was never offered to beets at all, yet the
# sweep moved it to quarantine as though it had failed to match. And the path
# unit would not fire again for it, because PathChanged does not re-check once
# the service finishes. So: list the inbox once, import exactly that list, sweep
# exactly that list, and go round again at the end if anything new turned up.
#
# Counted with the same predicate as the sweep (directories AND loose files),
# so that `imported = before - moved` is exact — Bandcamp single-track
# downloads arrive as a bare .flac.
ITEMS=()
HAD_AUDIO=()
while IFS= read -r -d '' item; do
  ITEMS+=("$item")
  if has_audio "$item"; then HAD_AUDIO+=(1); else HAD_AUDIO+=(0); fi
done < <(find "$INBOX" -mindepth 1 -maxdepth 1 \( -type d -o -type f \) -print0 | sort -z)
before="${#ITEMS[@]}"
log "inbox-import: importing $before items"

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
  # Only the snapshot, and only what the previous pass left behind.
  local present=() item
  for item in "${ITEMS[@]}"; do
    [ -e "$item" ] && present+=("$item")
  done
  : >"$PASS_OUT"
  if [ "${#present[@]}" -eq 0 ]; then
    log "inbox-import: pass — $label: nothing left to try"
    return 0
  fi
  log "inbox-import: pass — $label"
  if beet -c "$BEETS_CONFIG" -P "$disable" import "${present[@]}" >"$PASS_OUT" 2>&1; then
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
  notify "Import aborted - MusicBrainz unreachable" high \
    "$before item(s) left in the inbox untouched. Importing now would file
MusicBrainz-catalogued releases as Bandcamp ones. Re-run when it is back."
  exit 1
fi

import_pass "Bandcamp" musicbrainz

# Sweep the snapshot. Each item is in one of three states now:
#
#   gone              beets moved everything out and pruned the folder.
#   had audio, now    beets imported the music and left the clutter — a .cue,
#   has none          an EAC .log, an .m3u, Front.jpg, the fetch.json an
#                     approved fetch carries. beets' `clutter` setting only
#                     knows Thumbs.DB and .DS_Store. This used to be swept into
#                     quarantine, which reported a perfect import as a failure
#                     and filled the review pile with folders of junk. It is
#                     deleted instead, and counts as imported, because it was.
#   still has audio   beets declined it. Quarantine, for review.
#
# An item that had no audio to begin with (a folder of .rar files, a stray
# text file) is quarantined, not deleted: nothing here imported it, and the
# quarantine page says "no audio files", which is the truth.
#
# Loose FILES count, not just directories. Bandcamp hands you a bare .flac for
# a single-track release — no folder, and no ALBUM tag either, so it is exactly
# the kind of thing that never matches.
moved=0
cleared=0
quarantined=()
for idx in "${!ITEMS[@]}"; do
  leftover="${ITEMS[$idx]}"
  [ -e "$leftover" ] || continue
  name="$(basename "$leftover")"

  if [ "${HAD_AUDIO[$idx]}" = 1 ] && ! has_audio "$leftover"; then
    log "inbox-import: $name imported; deleting what beets left behind:"
    find "$leftover" -type f -printf '  %P\n' | tee -a "$LOG"
    rm -rf -- "$leftover"
    cleared=$((cleared + 1))
    continue
  fi

  quarantined+=("$name")
  dest="$QUARANTINE/$name"
  # Never clobber an existing quarantine entry from an earlier run.
  if [ -e "$dest" ]; then
    dest="$QUARANTINE/${name}.$(date +%Y%m%d%H%M%S)"
  fi
  mv -- "$leftover" "$dest"
  moved=$((moved + 1))
done

log "inbox-import: done — $moved unmatched moved to quarantine, $cleared cleared of leftovers"

# ---------------------------------------------------------------- report (§6.4)

imported=$(( before - moved ))
[ "$imported" -lt 0 ] && imported=0

# Only worth poking if something actually landed. Everything quarantining is a
# perfectly ordinary outcome on a first bulk import, and the library did not
# change.
if [ "$imported" -gt 0 ]; then
  navidrome_rescan
fi

summary="Imported $imported of $before."
if [ "$moved" -gt 0 ]; then
  summary="$summary
$moved to quarantine:"
  shown=0
  for name in "${quarantined[@]}"; do
    if [ "$shown" -ge "$NOTIFY_MAX_NAMES" ]; then
      summary="$summary
  ... and $(( moved - shown )) more"
      break
    fi
    summary="$summary
  $name"
    shown=$(( shown + 1 ))
  done
fi

# Per import RUN, not per album — a stack of CDs ripped back to back collapses
# into one push, and a 300-album migration into one message rather than 300.
# That is the better default, but it does mean ntfy is not a reliable "*this*
# disc is done" signal. The eject is (§6.4).
notify "Library updated" default "$summary"

# Anything in the inbox now arrived after the snapshot, so this run never
# offered it to beets. Go round again rather than leave it for a trigger that
# will not come. Every snapshot item is gone by this point — imported, cleared
# or quarantined — so this cannot spin on the same thing. exec skips the EXIT
# trap, hence the explicit cleanup.
if [ -n "$(find "$INBOX" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
  log "inbox-import: more arrived during this run — starting again"
  rm -f "$REF" "$PASS_OUT"
  exec bash "$0"
fi
