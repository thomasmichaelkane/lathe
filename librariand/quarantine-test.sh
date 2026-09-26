#!/usr/bin/env bash
# Exercise quarantine.py against a fabricated quarantine tree.
#
# Runs the real script, not a reimplementation of it — same convention as
# autorip-test.sh. The command most worth testing is `merge`: it moves the only
# copy of a rip, so getting it wrong loses music rather than printing an error.
#
# Needs ffmpeg to fabricate tagged FLACs, and an interpreter that can import
# mediafile (beets ships it). Without either, the tag-derived assertions are
# skipped and everything else still runs.
#
#   ./quarantine-test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HERE/quarantine.py"

# beets is commonly installed into its own virtualenv (pipx, uv tool), so the
# system python3 may not have mediafile. Prefer whichever interpreter runs
# beets, because that is the one the Pi will have.
pick_python() {
  if [ -n "${PY:-}" ]; then echo "$PY"; return; fi
  if python3 -c 'import mediafile' >/dev/null 2>&1; then echo python3; return; fi
  if command -v beet >/dev/null 2>&1; then
    local shebang
    shebang="$(head -1 "$(command -v beet)")"
    shebang="${shebang#\#!}"
    if [ -x "$shebang" ] && "$shebang" -c 'import mediafile' >/dev/null 2>&1; then
      echo "$shebang"; return
    fi
  fi
  echo python3
}
PY="$(pick_python)"

HAVE_TAGS=0
"$PY" -c 'import mediafile' >/dev/null 2>&1 && HAVE_TAGS=1
HAVE_FFMPEG=0
command -v ffmpeg >/dev/null 2>&1 && HAVE_FFMPEG=1
[ "$HAVE_TAGS" = 1 ] || echo "note: $PY cannot import mediafile — skipping tag assertions"
[ "$HAVE_FFMPEG" = 1 ] || echo "note: no ffmpeg — skipping tag assertions"

RICH=0
[ "$HAVE_TAGS" = 1 ] && [ "$HAVE_FFMPEG" = 1 ] && RICH=1

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

export QUARANTINE="$ROOT/quarantine"
export INBOX="$ROOT/inbox"
export RIP_LOGS="$ROOT/logs/rips"
mkdir -p "$QUARANTINE" "$INBOX" "$RIP_LOGS"

pass=0
fail=0

check() {  # label, command...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$label"; pass=$((pass + 1))
  else
    printf '  FAIL  %s\n' "$label"; fail=$((fail + 1))
  fi
}

check_out() {  # label, expected substring, command...
  local label="$1" want="$2"; shift 2
  local got
  got="$("$@" 2>&1 || true)"
  if printf '%s' "$got" | grep -qF -- "$want"; then
    printf '  ok    %s\n' "$label"; pass=$((pass + 1))
  else
    printf '  FAIL  %s (wanted %q)\n' "$label" "$want"
    printf '%s\n' "$got" | sed 's/^/          /'
    fail=$((fail + 1))
  fi
}

q()     { "$PY" "$TOOL" "$@"; }
not_q() { ! "$PY" "$TOOL" "$@"; }
missing() { ! test -e "$1"; }

json_parses() { q "$@" --json | "$PY" -c 'import json,sys; json.load(sys.stdin)'; }

# The duplicate pair must be reported but never offered as a merge.
dupes_have_no_merge_command() {
  ! q groups | awk '/OVERLAPPING/{f=1} f&&/^$/{f=0} f' | grep -q 'merge:'
}

no_work_dirs() { ! ls -d "$QUARANTINE"/.merge-* >/dev/null 2>&1; }

# A set that is already complete must never be described as a half of one.
# Reading `disc` off the first file alone reported exactly that, and pointed
# the reader at a merge with nothing to merge against.
whole_set_is_not_called_a_merge() {
  ! q show "The Whole Set" | grep -q 'needs merging'
}

two_some_box_sets() { [ "$(find "$INBOX" -maxdepth 1 -name 'Some Box Set*' | wc -l)" = 2 ]; }
three_tracks_on_cd2() { [ "$(find "$INBOX/Grapefruit Regret/CD2" -type f | wc -l)" = 3 ]; }

# --- Fabricate a quarantine pile -----------------------------------------
#
# One second of silence per track: small enough that a whole box set costs
# nothing, real enough that mediafile reads the tags back off it.
track() {  # dir, filename, [ffmpeg -metadata args...]
  local dir="$1" file="$2"; shift 2
  mkdir -p "$dir"
  if [ "$HAVE_FFMPEG" = 1 ]; then
    ffmpeg -loglevel error -y -f lavfi -i anullsrc=r=44100:cl=mono -t 1 \
      "$@" "$dir/$file" </dev/null
  else
    : >"$dir/$file"
  fi
}

# 1. A real two-disc set, ripped one disc at a time. autorip.sh hands the
#    second disc off under a suffixed name because the first already took the
#    plain one — so this pair is exactly what the inbox sweep produces.
# Totals go in their own Vorbis comments. ffmpeg writes '-metadata disc=1/2'
# through as DISCNUMBER=1/2, and mediafile does not split the slash form on
# Vorbis the way it does on ID3 — so the slash form silently loses disctotal,
# which is the field this whole tool keys off. beets and abcde both write the
# separate DISCTOTAL/TRACKTOTAL fields; match that.
for n in 01 02 03; do
  track "$QUARANTINE/Karenn - Grapefruit Regret" "$n track.flac" \
    -metadata album="Grapefruit Regret" -metadata albumartist=Karenn \
    -metadata disc=1 -metadata DISCTOTAL=2 \
    -metadata track="$n" -metadata TRACKTOTAL=3
  track "$QUARANTINE/Karenn - Grapefruit Regret [xYz123]" "$n track.flac" \
    -metadata album="Grapefruit Regret" -metadata albumartist=Karenn \
    -metadata disc=2 -metadata DISCTOTAL=2 \
    -metadata track="$n" -metadata TRACKTOTAL=3
done

# 2. An untagged set whose only signal is the folder name.
track "$QUARANTINE/Some Box Set (Disc 1)" "01 a.flac"
track "$QUARANTINE/Some Box Set (Disc 2)" "01 b.flac"

# 2b. A complete two-disc set flat in ONE folder — the shape a *download*
#     arrives in, as opposed to the one-disc-at-a-time shape a rip produces.
#     Every disc is already present, so there is nothing to merge and beets
#     will collapse the folder into a single import task by itself; the repair
#     is `retry`. Measured on a 30-track White Album download, 2026-09-20.
for n in 01 02; do
  track "$QUARANTINE/The Whole Set" "$n a.flac" \
    -metadata album="The Whole Set" -metadata albumartist=Nobody \
    -metadata disc=1 -metadata DISCTOTAL=2 \
    -metadata track="$n" -metadata TRACKTOTAL=4
done
for n in 03 04; do
  track "$QUARANTINE/The Whole Set" "$n b.flac" \
    -metadata album="The Whole Set" -metadata albumartist=Nobody \
    -metadata disc=2 -metadata DISCTOTAL=2 \
    -metadata track="$n" -metadata TRACKTOTAL=4
done

# 3. The same disc ripped twice — same album, same track numbers. Must NOT be
#    offered as a merge.
for name in "Dupe Album" "Dupe Album.20260101000000"; do
  track "$QUARANTINE/$name" "01 x.flac" \
    -metadata album="Dupe Album" -metadata albumartist=Someone -metadata track=1
  track "$QUARANTINE/$name" "02 y.flac" \
    -metadata album="Dupe Album" -metadata albumartist=Someone -metadata track=2
done

# 3b. Same album, but nothing to tell a set from a duplicate: no disc numbers
#     and no track numbers. Must be reported as undecidable rather than being
#     swept into the duplicates branch, which reads as a much stronger claim
#     than the evidence supports.
for name in "Vague Sessions A" "Vague Sessions B"; do
  track "$QUARANTINE/$name" "01 z.flac" \
    -metadata album="Vague Sessions" -metadata albumartist=Nobody
done

# 4. A bare file. Bandcamp does this for single-track releases and
#    inbox-import.sh sweeps it, so `list` has to cope with a non-directory.
track "$QUARANTINE" "loose-single.flac" -metadata track="1/1"

# 5. A rip log for disc 1, reporting read errors.
cat >"$RIP_LOGS/xYz123.json" <<JSON
{
  "disc_id": "xYz123",
  "status": "ok",
  "handoff_path": "$INBOX/Karenn - Grapefruit Regret",
  "artist": "Karenn",
  "album": "Grapefruit Regret",
  "track_count": 3,
  "read_errors": 2
}
JSON

echo "quarantine-test: interpreter $PY, tree $ROOT"
echo
echo "list"
check      "list exits clean"                        q list
check_out  "list counts every entry"     "10 entries" q list
check_out  "list sees the loose file"    "loose file" q list
check_out  "list surfaces read errors"   "read errors" q list
check      "list --json parses"                      json_parses list
[ "$RICH" = 1 ] && \
check_out  "list flags a disc of a set"  "of 2 — needs merging" q list
[ "$RICH" = 1 ] && \
check_out  "list knows a complete set in one folder" \
           "complete 2-disc set in one folder" q list

echo
echo "show"
check_out  "show reports the rip log"    "disc id     xYz123" \
           q show "Karenn - Grapefruit Regret"
if [ "$RICH" = 1 ]; then
  check_out "show lists every disc present" "disc        1, 2 of 2" \
            q show "The Whole Set"
  check     "show never calls a complete set a merge" \
            whole_set_is_not_called_a_merge
fi
check_out  "show rejects an unknown entry" "no such quarantine entry" q show nope
check      "show exits non-zero on an unknown entry" not_q show nope

echo
echo "groups"
check_out  "groups pairs untagged discs by name" "Some Box Set" q groups
check      "groups --json parses"                json_parses groups
if [ "$RICH" = 1 ]; then
check_out  "groups pairs the real set by tags"   "[strong]" q groups
check_out  "groups knows the set is complete"    "2 of 2 discs, complete" q groups
check_out  "groups flags duplicates"             "OVERLAPPING" q groups
check      "duplicates get no merge command"     dupes_have_no_merge_command
check_out  "groups admits when it cannot tell"   "check the contents first" q groups
fi

echo
echo "merge"
check_out  "dry run explains the plan"  "Some Box Set/CD2" \
           q merge --dry-run "Some Box Set (Disc 1)" "Some Box Set (Disc 2)"
check      "dry run moved nothing"      test -d "$QUARANTINE/Some Box Set (Disc 1)"
check      "merge refuses one entry"    not_q merge "Dupe Album"
check      "merge refuses a loose file" not_q merge loose-single.flac "Dupe Album"
check      "merge refuses a repeated entry" not_q merge "Dupe Album" "Dupe Album"
check      "merge refuses a path outside quarantine" not_q merge ../inbox "Dupe Album"

check      "merge runs" q merge "Some Box Set (Disc 1)" "Some Box Set (Disc 2)"
check      "merged album is in the inbox" test -d "$INBOX/Some Box Set"
check      "disc 1 became CD1"            test -f "$INBOX/Some Box Set/CD1/01 a.flac"
check      "disc 2 became CD2"            test -f "$INBOX/Some Box Set/CD2/01 b.flac"
check      "sources left quarantine"      missing "$QUARANTINE/Some Box Set (Disc 1)"
check      "no work directory survives"   no_work_dirs

if [ "$RICH" = 1 ]; then
check      "merge names the folder from the album tag" \
           q merge "Karenn - Grapefruit Regret" "Karenn - Grapefruit Regret [xYz123]"
check      "the album tag won over the folder name" test -d "$INBOX/Grapefruit Regret"
check      "three tracks on CD2"                    three_tracks_on_cd2
fi

# A merge into a name the inbox already holds must never clobber it.
track "$QUARANTINE/Later Set (Disc 1)" "01 a.flac"
track "$QUARANTINE/Later Set (Disc 2)" "01 b.flac"
check      "merge into a taken name runs" \
           q merge --as "Some Box Set" "Later Set (Disc 1)" "Later Set (Disc 2)"
check      "the existing inbox album was not clobbered" \
           test -f "$INBOX/Some Box Set/CD1/01 a.flac"
check      "the second merge landed under a suffixed name" two_some_box_sets

echo
echo "retry"
check      "retry moves a loose file back" q retry loose-single.flac
check      "loose file is in the inbox"    test -f "$INBOX/loose-single.flac"
check      "loose file left quarantine"    missing "$QUARANTINE/loose-single.flac"

echo
echo "drop"
check      "drop refuses without --yes" not_q drop "Dupe Album"
check      "the entry survived the refusal" test -d "$QUARANTINE/Dupe Album"
# pathlib does not collapse "..", so QUARANTINE/".." used to pass the parent
# check while pointing at /srv — and drop would rmtree the whole library.
check      "drop refuses '..'"              not_q drop --yes ".."
check      "and the tree above survived"    test -d "$QUARANTINE"
check      "retry refuses '..'"             not_q retry ".."
check      "merge refuses '..'"             not_q merge ".." "Dupe Album"
check      "a hidden .merge-* name is not an entry" not_q drop --yes ".merge-1"
check      "drop --yes deletes"             q drop --yes "Dupe Album"
check      "the entry is gone"              missing "$QUARANTINE/Dupe Album"

echo
echo "disc marker parsing"
check_out  "markers parse the way the grouper needs" "all parsed" \
           env PYTHONPATH="$HERE" "$PY" -c '
import quarantine as qn
cases = {
    "Album (Disc 2)":    ("Album", 2, None),
    "Album CD3":         ("Album", 3, None),
    "Album - disc 1":    ("Album", 1, None),
    "Album (1 of 2)":    ("Album", 1, 2),
    "Album Disc One":    ("Album", 1, None),
    "Album":             ("Album", None, None),
    # A title that merely ends in a number is not a disc marker.
    "Blade Runner 2049": ("Blade Runner 2049", None, None),
}
bad = {k: qn.strip_disc_marker(k) for k, v in cases.items()
       if qn.strip_disc_marker(k) != v}
print("mismatches:", bad) if bad else print("all parsed")
'

echo
echo "quarantine-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
