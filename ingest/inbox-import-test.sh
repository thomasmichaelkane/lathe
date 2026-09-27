#!/usr/bin/env bash
# Exercise inbox-import.sh's reporting against a temporary tree, with no beets,
# no Navidrome and no network.
#
# beets itself is stubbed. What is worth testing here is everything the script
# does around it — the quarantine sweep's counts, the import summary, and the
# two notifications — because all three fail quietly by nature. A notifier that
# has been broken for a month looks exactly like a quiet month.
#
# The stub also stands in for the one failure mode that matters most: a
# MusicBrainz outage during pass 1 must abort before the Bandcamp pass and
# before the sweep, leaving the inbox untouched (§6.5). That path is unreachable
# in a live test without taking musicbrainz.org away.
#
# What this does NOT cover, and what Phase 1 must verify for real:
#   - beets actually matching anything
#   - the settle loop against a genuinely in-flight copy
#   - a real Navidrome accepting the startScan request
#   - running as the `music` user, at real /srv paths, with setgid inboxes
#
# Usage:  ./lathe/ingest/inbox-import-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPORT="$SCRIPT_DIR/inbox-import.sh"

[ -r "$IMPORT" ] || { echo "error: $IMPORT is not readable" >&2; exit 1; }

TMP="$(mktemp -d)"
CATCHER_PID=""
cleanup() {
  [ -n "$CATCHER_PID" ] && kill "$CATCHER_PID" 2>/dev/null
  rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

pass=0
fail=0

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
has()  { if grep -qF "$2" "$3"; then ok "$1"; else bad "$1 (not found: $2)"; fi; }
hasnt() { if grep -qF "$2" "$3"; then bad "$1 (unexpectedly found: $2)"; else ok "$1"; fi; }

# A stub standing in for beets. The MusicBrainz pass is the one that disables
# bandcamp, and it is the pass that "matches": it deletes the album directories
# named in STUB_MATCH, which is what `import.move: yes` does for real. The
# Bandcamp pass matches nothing. STUB_MB_ERROR makes pass 1 emit the kind of
# line the script greps for when MusicBrainz is unreachable.
#
# STUB_STRIP imports an album the way beets really does when the folder holds
# more than music: the audio goes, and the .cue/.log/fetch.json stays behind.
# STUB_ARRIVE drops a new album into the inbox partway through pass 1, once —
# a rip finishing in the middle of a long import. Every invocation's arguments
# are appended to STUB_ARGS, so a case can see exactly what beets was offered.
cat > "$TMP/beet" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$STUB_ARGS"
is_mb_pass=0
for a in "$@"; do [ "$a" = "bandcamp" ] && is_mb_pass=1; done

if [ "$is_mb_pass" = "1" ]; then
  if [ -n "${STUB_MB_ERROR:-}" ]; then
    echo "musicbrainz: Error: Max retries exceeded"
    exit 0
  fi
  for album in ${STUB_MATCH:-}; do
    rm -rf "$INBOX/${album//_/ }"
  done
  for album in ${STUB_STRIP:-}; do
    find "$INBOX/${album//_/ }" -name '*.flac' -delete
  done
  if [ -n "${STUB_ARRIVE:-}" ] && [ ! -e "$STUB_ARGS.arrived" ]; then
    mkdir -p "$INBOX/${STUB_ARRIVE//_/ }"
    touch "$STUB_ARGS.arrived"
  fi
fi
exit 0
STUB
chmod +x "$TMP/beet"

# Stands in for both ntfy and Navidrome. POST is a push, GET is a scan poke;
# each is appended to the capture file as a flat record so the cases can grep
# it. The Navidrome half verifies the Subsonic token rather than just recording
# it — sending the password in clear would be a silent, serious regression.
cat > "$TMP/catcher.py" <<'PY'
import http.server, sys, hashlib, urllib.parse, threading

CAPTURE = sys.argv[1]
PASSWORD = sys.argv[2]

def write(lines):
    with open(CAPTURE, "a") as f:
        f.write("\n".join(lines) + "\n")

class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode()
        write(["NTFY-TITLE: %s" % self.headers.get("Title"),
               "NTFY-PRIORITY: %s" % self.headers.get("Priority"),
               "NTFY-BODY-START", body, "NTFY-BODY-END"])
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        salt = q.get("s", [""])[0]
        expected = hashlib.md5((PASSWORD + salt).encode()).hexdigest()
        write(["SCAN-PATH: %s" % u.path,
               "SCAN-USER: %s" % q.get("u", ["<missing>"])[0],
               "SCAN-CLIENT: %s" % q.get("c", ["<missing>"])[0],
               "SCAN-VERSION: %s" % q.get("v", ["<missing>"])[0],
               "SCAN-TOKEN-OK: %s" % (q.get("t", [""])[0] == expected),
               "SCAN-PASSWORD-IN-CLEAR: %s"
               % any(PASSWORD in v[0] for v in q.values())])
        self.send_response(200); self.end_headers()
        self.wfile.write(b'{"subsonic-response":{"status":"ok"}}')

    def log_message(self, *a):
        pass

srv = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[3], "w") as f:
    f.write(str(srv.server_port))
srv.serve_forever()
PY

CAPTURE="$TMP/capture.txt"
NDPASS="correct-horse"
: >"$CAPTURE"
python3 "$TMP/catcher.py" "$CAPTURE" "$NDPASS" "$TMP/port" &
CATCHER_PID=$!

for _ in $(seq 1 50); do
  [ -s "$TMP/port" ] && break
  sleep 0.1
done
[ -s "$TMP/port" ] || { echo "error: capture server never came up" >&2; exit 1; }
BASE="http://127.0.0.1:$(cat "$TMP/port")"

# Run inbox-import.sh against a fresh inbox. Everything the script reads is an
# environment override, which is the point of those overrides existing: the
# code under test is the code that ships.
run_import() {
  rm -rf "$TMP/inbox" "$TMP/quarantine"
  mkdir -p "$TMP/inbox" "$TMP/quarantine"
  : >"$CAPTURE"
  : >"$TMP/import.log"
  rm -f "$TMP/args.txt" "$TMP/args.txt.arrived"
  : >"$TMP/args.txt"
  eval "$1"   # case-specific inbox setup
  set +e
  env PATH="$TMP:$PATH" \
      INBOX="$TMP/inbox" \
      QUARANTINE="$TMP/quarantine" \
      BEETS_CONFIG="$TMP/unused.yaml" \
      LOG="$TMP/import.log" \
      SETTLE_SECONDS=1 \
      SETTLE_POLL=1 \
      CUESPLIT="$SCRIPT_DIR/cuesplit.py" \
      STUB_ARGS="$TMP/args.txt" \
      STUB_MATCH="${STUB_MATCH:-}" \
      STUB_STRIP="${STUB_STRIP:-}" \
      STUB_ARRIVE="${STUB_ARRIVE:-}" \
      STUB_MB_ERROR="${STUB_MB_ERROR:-}" \
      NTFY_URL="${CASE_NTFY:-}" \
      NAVIDROME_URL="${CASE_ND_URL:-}" \
      NAVIDROME_USER="${CASE_ND_USER:-}" \
      NAVIDROME_PASS="${CASE_ND_PASS:-}" \
      NOTIFY_MAX_NAMES="${CASE_MAX_NAMES:-10}" \
      bash "$IMPORT" >"$TMP/stdout.txt" 2>&1
  LAST_EXIT=$?
  set -e
}

count() { find "$1" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '; }

echo
echo "a mixed import — summary, counts, and the quarantine sweep"

STUB_MATCH="Matched_Album" STUB_MB_ERROR="" \
CASE_NTFY="$BASE" CASE_ND_URL="" CASE_ND_USER="" CASE_ND_PASS="" \
run_import '
  mkdir -p "$TMP/inbox/Matched Album"
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do mkdir -p "$TMP/inbox/Unmatched $i"; done
  touch "$TMP/inbox/Loose Single.flac"
'
check "import exits 0" "$LAST_EXIT" "0"
has  "push is titled Library updated" "NTFY-TITLE: Library updated" "$CAPTURE"
has  "push is normal priority"        "NTFY-PRIORITY: default"     "$CAPTURE"
has  "counts are imported-of-total"   "Imported 1 of 14."          "$CAPTURE"
has  "quarantine count is reported"   "13 to quarantine:"          "$CAPTURE"
check "everything unmatched was swept" "$(count "$TMP/quarantine")" "13"
check "the inbox is left empty"        "$(count "$TMP/inbox")"      "0"
has  "a loose file is swept too, not just directories" "Loose Single.flac" "$CAPTURE"

echo
echo "long quarantine lists collapse instead of arriving as a wall of text"
has  "names are capped"    "... and 3 more" "$CAPTURE"
# Sorted, so the loose .flac takes the first slot and the tenth name shown is
# "Unmatched 09" — not "Unmatched 10", which is the off-by-one this pins.
has  "the tenth name shown is listed"  "Unmatched 09" "$CAPTURE"
hasnt "the eleventh is not"            "Unmatched 10" "$CAPTURE"
# Sorted, so the list reads as a list rather than in whatever order the
# filesystem handed the entries over.
names="$(sed -n 's/^  \(Unmatched [0-9]*\)$/\1/p' "$CAPTURE")"
check "names are sorted" "$names" "$(printf '%s\n' "$names" | sort)"

echo
echo "the rescan poke"

STUB_MATCH="An_Album" STUB_MB_ERROR="" \
CASE_NTFY="" CASE_ND_URL="$BASE/" CASE_ND_USER="tom" CASE_ND_PASS="$NDPASS" \
run_import 'mkdir -p "$TMP/inbox/An Album"'
has  "hits Navidrome's startScan"      "SCAN-PATH: /rest/startScan" "$CAPTURE"
has  "a trailing slash on the URL does not double up" "SCAN-PATH: /rest/startScan" "$CAPTURE"
has  "sends the configured user"       "SCAN-USER: tom"             "$CAPTURE"
has  "identifies itself as lathe"      "SCAN-CLIENT: lathe"         "$CAPTURE"
has  "token is md5(password+salt)"     "SCAN-TOKEN-OK: True"        "$CAPTURE"
has  "the password never goes over the wire" "SCAN-PASSWORD-IN-CLEAR: False" "$CAPTURE"
has  "success is logged"               "Navidrome rescan triggered" "$TMP/import.log"

echo
echo "the rescan is skipped when it would be pointless or impossible"

STUB_MATCH="" STUB_MB_ERROR="" \
CASE_NTFY="" CASE_ND_URL="$BASE" CASE_ND_USER="tom" CASE_ND_PASS="$NDPASS" \
run_import 'mkdir -p "$TMP/inbox/Nothing Matches"'
hasnt "nothing imported means no poke" "SCAN-PATH" "$CAPTURE"

STUB_MATCH="An_Album" STUB_MB_ERROR="" \
CASE_NTFY="" CASE_ND_URL="" CASE_ND_USER="" CASE_ND_PASS="" \
run_import 'mkdir -p "$TMP/inbox/An Album"'
check "no credentials still exits 0" "$LAST_EXIT" "0"
has  "and says so rather than failing silently" "no Navidrome credentials set" "$TMP/import.log"

echo
echo "a broken notifier never fails an import that succeeded"

# Port 1 is reserved and nothing listens on it, so both calls fail fast.
STUB_MATCH="An_Album" STUB_MB_ERROR="" \
CASE_NTFY="http://127.0.0.1:1" CASE_ND_URL="http://127.0.0.1:1" \
CASE_ND_USER="tom" CASE_ND_PASS="$NDPASS" \
run_import 'mkdir -p "$TMP/inbox/An Album"'
check "unreachable ntfy and Navidrome still exit 0" "$LAST_EXIT" "0"
has  "the failed push is logged"   "ntfy push failed"           "$TMP/import.log"
has  "the failed poke is logged"   "Navidrome rescan poke failed" "$TMP/import.log"

echo
echo "a MusicBrainz outage in pass 1 aborts before anything is filed wrong"

STUB_MATCH="" STUB_MB_ERROR="1" \
CASE_NTFY="$BASE" CASE_ND_URL="$BASE" CASE_ND_USER="tom" CASE_ND_PASS="$NDPASS" \
run_import '
  mkdir -p "$TMP/inbox/Album One" "$TMP/inbox/Album Two"
'
check "aborts non-zero"                "$LAST_EXIT" "1"
check "the inbox is left untouched"    "$(count "$TMP/inbox")"      "2"
check "nothing is swept to quarantine" "$(count "$TMP/quarantine")" "0"
# ASCII on purpose: the title crosses as an HTTP header, which is ISO-8859-1 by
# spec, so an em dash here reaches the phone as mojibake.
has  "the abort is pushed"             "NTFY-TITLE: Import aborted - MusicBrainz unreachable" "$CAPTURE"
has  "at high priority"                "NTFY-PRIORITY: high"        "$CAPTURE"
hasnt "and Navidrome is not poked"     "SCAN-PATH"                  "$CAPTURE"

echo
echo "beets is offered the snapshot, item by item — not the inbox directory"

STUB_MATCH="" STUB_MB_ERROR="" \
CASE_NTFY="" CASE_ND_URL="" CASE_ND_USER="" CASE_ND_PASS="" \
run_import 'mkdir -p "$TMP/inbox/One Album"'
has   "the album is named explicitly"  "$TMP/inbox/One Album"  "$TMP/args.txt"
if grep -qE " $TMP/inbox\$" "$TMP/args.txt"; then
  bad "the inbox itself is never passed"
else
  ok "the inbox itself is never passed"
fi

echo
echo "an import that leaves clutter behind is an import, not a quarantine"

STUB_STRIP="With_Junk" STUB_MATCH="" STUB_MB_ERROR="" \
CASE_NTFY="$BASE" CASE_ND_URL="" CASE_ND_USER="" CASE_ND_PASS="" \
run_import '
  mkdir -p "$TMP/inbox/With Junk" "$TMP/inbox/Archives Only"
  touch "$TMP/inbox/With Junk/01 Song.flac" "$TMP/inbox/With Junk/album.cue" \
        "$TMP/inbox/With Junk/fetch.json" "$TMP/inbox/With Junk/Front.jpg"
  touch "$TMP/inbox/Archives Only/album.rar"
'
check "exits 0"                                   "$LAST_EXIT" "0"
check "the leftovers are cleared, not kept"       "$(count "$TMP/inbox")" "0"
has   "counted as imported"                       "Imported 1 of 2."      "$CAPTURE"
if [ -e "$TMP/quarantine/With Junk" ]; then
  bad "and not swept into quarantine"
else
  ok "and not swept into quarantine"
fi
has   "what was deleted is logged"                "fetch.json"            "$TMP/import.log"
check "a folder that never had audio still quarantines" \
      "$(ls "$TMP/quarantine")" "Archives Only"

echo
echo "something arriving mid-import is imported, not swept unseen"

STUB_ARRIVE="Late_Arrival" STUB_MATCH="Early_Album" STUB_MB_ERROR="" \
CASE_NTFY="" CASE_ND_URL="" CASE_ND_USER="" CASE_ND_PASS="" \
run_import 'mkdir -p "$TMP/inbox/Early Album"'
check "exits 0"                                   "$LAST_EXIT" "0"
has   "the run goes round again"                  "more arrived during this run" "$TMP/import.log"
has   "the late arrival is offered to beets"      "$TMP/inbox/Late Arrival" "$TMP/args.txt"
# Unmatched by the stub, so after beets has seen it, it quarantines — the point
# is the order: offered first, swept second.
check "and only then quarantined"                 "$(ls "$TMP/quarantine")" "Late Arrival"
check "the inbox ends empty"                      "$(count "$TMP/inbox")" "0"

echo
echo "CD images are split into tracks before beets sees them (#59)"

# A 6-second "disc" as one FLAC, and a cue for three 2-second tracks. The cue
# names a .wav (the image was re-encoded after ripping, as they usually are)
# and is cp1252, as Windows rippers write them.
mkimage() {  # dir
  ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=330:duration=6" "$1/CDImage.flac"
  python3 - "$1/CDImage.cue" <<'PY'
import sys
cue = """REM DATE 1982
PERFORMER "Richard & Linda Thompson"
TITLE "Shoot Out the Lights"
FILE "CDImage.wav" WAVE
  TRACK 01 AUDIO
    TITLE "Don't Renege on Our Love"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Walking on a Wire"
    INDEX 00 00:01:70
    INDEX 01 00:02:00
  TRACK 03 AUDIO
    TITLE "Três"
    INDEX 01 00:04:00
"""
open(sys.argv[1], "w", encoding="cp1252", newline="\r\n").write(cue)
PY
}

STUB_MATCH="" STUB_MB_ERROR="" \
CASE_NTFY="" CASE_ND_URL="" CASE_ND_USER="" CASE_ND_PASS="" \
run_import '
  mkdir -p "$TMP/inbox/Image Album" "$TMP/inbox/Per Track Rip" "$TMP/inbox/One Track Cue" "$TMP/inbox/Broken Image"
  mkimage "$TMP/inbox/Image Album"
  mkdir -p "$TMP/inbox/Two Disc Image/CD1" "$TMP/inbox/Two Disc Image/CD2"
  mkimage "$TMP/inbox/Two Disc Image/CD1"
  mkimage "$TMP/inbox/Two Disc Image/CD2"
  for t in 1 2 3; do
    ffmpeg -loglevel error -y -f lavfi -i "sine=duration=1" "$TMP/inbox/Per Track Rip/0$t Song.flac"
  done
  cp "$TMP/inbox/Image Album/CDImage.cue" "$TMP/inbox/Per Track Rip/album.cue"
  ffmpeg -loglevel error -y -f lavfi -i "sine=duration=2" "$TMP/inbox/One Track Cue/Single.flac"
  printf "FILE \"Single.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n" > "$TMP/inbox/One Track Cue/single.cue"
  printf "not audio at all" > "$TMP/inbox/Broken Image/CDImage.flac"
  cp "$TMP/inbox/Image Album/CDImage.cue" "$TMP/inbox/Broken Image/CDImage.cue"
'
Q="$TMP/quarantine"
check "the import still exits 0"               "$LAST_EXIT" "0"
check "an image becomes one file per track" \
      "$(cd "$Q/Image Album" && ls *.flac | LC_ALL=C sort | tr '\n' '|')" \
      "01 Don't Renege on Our Love.flac|02 Walking on a Wire.flac|03 Três.flac|"
if [ -e "$Q/Image Album/CDImage.flac" ]; then bad "and the image is gone"; else ok "and the image is gone"; fi
if [ -e "$Q/Image Album/CDImage.cue" ]; then ok "the cue stays, as clutter"; else bad "the cue stays, as clutter"; fi
t2="$Q/Image Album/02 Walking on a Wire.flac"
check "tracks are tagged from the cue" \
      "$(ffprobe -v error -show_entries format_tags=title,album,artist,track -of default=nw=1 "$t2" | sort | tr '\n' '|')" \
      "TAG:ALBUM=Shoot Out the Lights|TAG:ARTIST=Richard & Linda Thompson|TAG:TITLE=Walking on a Wire|TAG:track=2|"
dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$t2")"
if python3 -c "import sys; sys.exit(0 if abs(float('$dur') - 2.0) < 0.1 else 1)"; then
  ok "cut at INDEX 01, not INDEX 00 ($dur s)"
else
  bad "cut at INDEX 01, not INDEX 00 (got $dur s, want 2.0)"
fi
check "a cp1252 cue reads correctly" \
      "$(ffprobe -v error -show_entries format_tags=title -of csv=p=0 "$Q/Image Album/03 Três.flac")" "Três"
has   "beets was offered the split album"   "$TMP/inbox/Image Album" "$TMP/args.txt"
check "a per-track rip with a cue is left alone" \
      "$(cd "$Q/Per Track Rip" && ls | LC_ALL=C sort | tr '\n' '|')" "01 Song.flac|02 Song.flac|03 Song.flac|album.cue|"
check "as is a one-track cue" \
      "$(cd "$Q/One Track Cue" && ls | LC_ALL=C sort | tr '\n' '|')" "Single.flac|single.cue|"
check "a two-disc image set splits each disc in its own folder" \
      "$(cd "$Q/Two Disc Image" && find . -name '*.flac' | LC_ALL=C sort | tr '\n' '|')" \
      "./CD1/01 Don't Renege on Our Love.flac|./CD1/02 Walking on a Wire.flac|./CD1/03 Três.flac|./CD2/01 Don't Renege on Our Love.flac|./CD2/02 Walking on a Wire.flac|./CD2/03 Três.flac|"
check "a failed split leaves the image exactly as it was" \
      "$(cd "$Q/Broken Image" && ls -A | LC_ALL=C sort | tr '\n' '|')" "CDImage.cue|CDImage.flac|"
has   "and says so in the log"              "could not split"        "$TMP/import.log"

echo
echo "an empty inbox is not an event"

STUB_MATCH="" STUB_MB_ERROR="" \
CASE_NTFY="$BASE" CASE_ND_URL="$BASE" CASE_ND_USER="tom" CASE_ND_PASS="$NDPASS" \
run_import 'true'
check "exits 0"                 "$LAST_EXIT" "0"
hasnt "and pushes nothing"      "NTFY-TITLE" "$CAPTURE"

echo
echo "-----------------------------------------"
printf 'inbox-import-test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
