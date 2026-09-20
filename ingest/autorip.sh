#!/usr/bin/env bash
# Rip an audio CD and hand the result to the ingest pipeline.
#
# Runs as the `music` user, started by autorip@.service, which is triggered by
# the udev rule in systemd/99-autorip.rules. Deployed to
# /usr/local/bin/autorip.sh
#
# Usage:  autorip.sh sr0        # kernel device name, as udev passes it (%i)
#
# THIS SCRIPT IS A PRODUCER. It rips, logs, and moves a finished album into
# /srv/inbox. It does not run beets, never touches /srv/music, and does not
# know whether the album ended up in the library or in quarantine.
#
# See §6.2 of docs/plan.md for why. inbox-import.sh already implements the
# settle wait, the quarantine sweep and the cleanup; a second copy of that
# logic living here is exactly how the rip path and the manual-drop path drift
# apart. The filesystem is the only thing that passes between them.
#
# The one thing this script does report is FAILURE. A successful rip is
# announced by inbox-import.sh once the import finishes, but a rip that never
# reaches the inbox is something the consumer will never see and therefore can
# never mention. So failures get their own ntfy push, and only failures.

set -euo pipefail

DEV_NAME="${1:-sr0}"
DEVICE="/dev/$DEV_NAME"

# Paths are overridable so autorip-test.sh can exercise the hand-off against a
# temporary tree, running this exact script rather than a reimplementation of
# it. Same convention as inbox-import.sh. Defaults are the real ones; nothing
# in production sets these.
RIPS="${RIPS:-/srv/staging/rips}"
INBOX="${INBOX:-/srv/inbox}"
RIP_LOGS="${RIP_LOGS:-/srv/logs/rips}"

# Overridable so the test can substitute a stub that fabricates abcde's output
# without a drive attached. Everything after the rip is what needs testing.
ABCDE_CMD="${ABCDE_CMD:-abcde}"

# Empty means "don't notify". Set NTFY_URL in /etc/default/lathe to a full topic
# URL, e.g. https://ntfy.sh/some-random-topic — the same file and the same topic
# inbox-import.sh uses for the success side.
NTFY_URL="${NTFY_URL:-}"

log() { printf '%s autorip[%s]: %s\n' "$(date -Is)" "$DEV_NAME" "$*"; }

notify_failure() {
  log "FAILED: $1"
  if [ -n "$NTFY_URL" ]; then
    curl -fsS --max-time 10 \
      -H "Title: Rip failed on $DEV_NAME" \
      -H "Priority: high" \
      -d "$1" "$NTFY_URL" >/dev/null 2>&1 || log "ntfy push failed (rip failure not delivered)"
  fi
}

# MusicBrainz disc ID — what §4 names rip logs by, and what makes a log
# correlate with a MusicBrainz release later.
disc_id() {
  local id=""

  if python3 -c 'import discid' >/dev/null 2>&1; then
    id="$(python3 -c 'import discid,sys; print(discid.read(sys.argv[1]).id)' "$DEVICE" 2>/dev/null)" || id=""
  fi

  # libdiscid absent or unreadable. cd-discid is an abcde dependency so it is
  # always present, but it computes the freedb ID, which is a different scheme
  # over different data. Prefix it so nothing downstream mistakes one for a
  # MusicBrainz ID and tries to look it up.
  if [ -z "$id" ] && command -v cd-discid >/dev/null 2>&1; then
    id="$(cd-discid "$DEVICE" 2>/dev/null | awk '{print $1}')" || id=""
    if [ -n "$id" ]; then
      id="freedb-$id"
    fi
  fi

  if [ -z "$id" ]; then
    id="unknown-$(date +%Y%m%d%H%M%S)"
  fi

  printf '%s' "$id"
}

# Pinned by the test so collision behaviour is deterministic. Unset in reality.
DISCID="${DISC_ID_OVERRIDE:-$(disc_id)}"

mkdir -p "$RIPS/.work" "$RIP_LOGS" "$INBOX"

WORK="$RIPS/.work/$DISCID.$$"
OUT="$WORK/out"
mkdir -p "$OUT"

RAW_LOG="$RIP_LOGS/$DISCID.log"
JSON_LOG="$RIP_LOGS/$DISCID.json"

# Write the structured log from Python rather than assembling JSON in bash.
# Album and artist names contain quotes, backslashes and non-ASCII often enough
# that hand-rolled escaping would eventually emit something librariand can't
# parse — and it would do it on the one disc you care about.
write_json_log() {
  RL_DISCID="$DISCID" \
  RL_DEVICE="$DEVICE" \
  RL_STATUS="$1" \
  RL_DETAIL="$2" \
  RL_HANDOFF="${3:-}" \
  RL_ARTIST="${4:-}" \
  RL_ALBUM="${5:-}" \
  RL_TRACKS="${6:-0}" \
  RL_ERRORS="${7:-0}" \
  RL_RAWLOG="$RAW_LOG" \
  RL_OUT="$JSON_LOG" \
  python3 - <<'PY'
import json, os, datetime

out = {
    "schema": 1,
    "disc_id": os.environ["RL_DISCID"],
    "device": os.environ["RL_DEVICE"],
    "finished_at": datetime.datetime.now(datetime.timezone.utc)
                    .isoformat().replace("+00:00", "Z"),
    "status": os.environ["RL_STATUS"],
    "detail": os.environ["RL_DETAIL"] or None,
    # Where the album was moved to. librariand correlates a rip with its import
    # outcome by checking whether this name is still sitting in
    # /srv/quarantine — the ripper hands off before beets runs, so it cannot
    # know the outcome itself. See §10 of docs/plan.md.
    "handoff_path": os.environ["RL_HANDOFF"] or None,
    "artist": os.environ["RL_ARTIST"] or None,
    "album": os.environ["RL_ALBUM"] or None,
    "track_count": int(os.environ["RL_TRACKS"] or 0),
    "read_errors": os.environ["RL_ERRORS"] == "1",
    "raw_log": os.environ["RL_RAWLOG"],
}

with open(os.environ["RL_OUT"], "w", encoding="utf-8") as fh:
    json.dump(out, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY
}

# --- Guard: the hand-off must be a rename, not a copy --------------------
#
# `mv` is only atomic within one filesystem. If /srv/staging and /srv/inbox are
# separate mounts it silently degrades to copy-then-delete, inbox.path fires
# partway through, and beets imports a half-written album. Check it now rather
# than after spending eight minutes on the rip.
work_dev="$(stat -c %d "$WORK")"
inbox_dev="$(stat -c %d "$INBOX")"
if [ "$work_dev" != "$inbox_dev" ]; then
  write_json_log "failed" "staging and inbox are on different filesystems"
  notify_failure "$RIPS and $INBOX are on different filesystems — the hand-off would not be atomic. Refusing to rip."
  exit 1
fi

# --- Rip -----------------------------------------------------------------
#
# A per-run overlay config, sourced after /etc/abcde.conf, pins the output into
# this run's work directory. Two drives ripping at once therefore cannot land
# in the same tree, and the finished album can be found by listing OUT rather
# than by reproducing abcde's naming rules here.
{
  echo "OUTPUTDIR=$OUT"
  echo "CDROM=$DEVICE"
} > "$WORK/abcde.conf"

log "ripping $DEVICE (disc $DISCID) into $OUT"

rip_status=0
"$ABCDE_CMD" -N -c "$WORK/abcde.conf" -d "$DEVICE" > "$WORK/abcde.log" 2>&1 || rip_status=$?

cp -f "$WORK/abcde.log" "$RAW_LOG" 2>/dev/null || true

# `-Z` means cdparanoia does not retry, and it is not loud about what it
# skipped — hence §12's warning that per-disc logging is not optional. These
# patterns are the visible symptoms; VERIFY THEM AGAINST A SCRATCHED DISC
# during Phase 3, because a pattern that never matches looks exactly like a
# clean rip.
read_errors=0
if grep -qiE 'unable to read|read error|scsi error|uncorrected|skipping[^a-z]|i/o error' "$WORK/abcde.log"; then
  read_errors=1
  log "WARNING: read errors reported — this disc should be re-ripped manually"
fi

if [ "$rip_status" -ne 0 ]; then
  write_json_log "failed" "abcde exited $rip_status" "" "" "" 0 "$read_errors"
  notify_failure "abcde exited $rip_status on $DEVICE. Work directory kept at $WORK; log at $RAW_LOG"
  eject "$DEVICE" 2>/dev/null || true
  exit 1
fi

# --- Locate what was produced -------------------------------------------
#
# OUTPUTFORMAT is <Artist>/<Album>/<tracks>, so exactly one directory should
# exist two levels down. Anything else means abcde did something unexpected and
# guessing would move the wrong thing into the library's front door.
album_dirs=()
while IFS= read -r -d '' d; do
  album_dirs+=("$d")
done < <(find "$OUT" -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null | sort -z)

if [ "${#album_dirs[@]}" -ne 1 ]; then
  write_json_log "failed" "expected 1 album directory, found ${#album_dirs[@]}" "" "" "" 0 "$read_errors"
  notify_failure "Rip produced ${#album_dirs[@]} album directories, expected 1. Kept at $WORK"
  eject "$DEVICE" 2>/dev/null || true
  exit 1
fi

album_dir="${album_dirs[0]}"
artist="$(basename "$(dirname "$album_dir")")"
album="$(basename "$album_dir")"

# Any audio file, not specifically FLAC. OUTPUTTYPE governs what we encode to
# and is FLAC today, but the condition worth failing on is "abcde made a
# directory and no music" — not "abcde made something other than FLAC".
track_count="$(find "$album_dir" -maxdepth 1 -type f \
  \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.ogg' -o -iname '*.opus' -o -iname '*.wav' \) | wc -l)"
if [ "$track_count" -eq 0 ]; then
  write_json_log "failed" "no audio files in $album_dir" "" "$artist" "$album" 0 "$read_errors"
  notify_failure "Rip of '$artist - $album' produced no audio files. Kept at $WORK"
  eject "$DEVICE" 2>/dev/null || true
  exit 1
fi

# --- Hand off ------------------------------------------------------------
#
# The destination name is for humans only — it is what you read in the inbox,
# or in quarantine if beets can't match it. Beets ignores it entirely and files
# by tags.
dest="$INBOX/$artist - $album"
if [ -e "$dest" ]; then
  dest="$INBOX/$artist - $album [$DISCID]"
fi
if [ -e "$dest" ]; then
  dest="$INBOX/$artist - $album [$DISCID.$(date +%s)]"
fi

# One rename(2). inbox.path fires on the first change, so the album must appear
# complete or not at all — see §6.2.
mv -- "$album_dir" "$dest"
log "handed off to $dest ($track_count tracks)"

write_json_log "ok" "" "$dest" "$artist" "$album" "$track_count" "$read_errors"

# --- Clean up and signal -------------------------------------------------
rm -rf -- "${WORK:?}"
rmdir "$RIPS/.work" 2>/dev/null || true

# The tray opening means "the drive is free, put the next disc in" — nothing
# more. The album is not in the library yet; inbox-import.sh says when it is.
eject "$DEVICE" 2>/dev/null || log "eject failed (disc left in the drive)"

log "done — import will start once $INBOX settles"
