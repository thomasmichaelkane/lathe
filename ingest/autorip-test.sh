#!/usr/bin/env bash
# Exercise autorip.sh's hand-off against a temporary tree, with no drive.
#
# The rip itself (abcde, cdparanoia, /dev/sr0) cannot be tested without
# hardware and is stubbed here. Everything AFTER the rip can be, and that is
# the part worth testing: locating the album, naming the destination, handling
# collisions, the atomic move, the JSON log, and the failure paths. Those are
# where the bugs live, and none of them need a CD.
#
# What this does NOT cover, and what Phase 3 must verify on real hardware:
#   - the udev rule firing on media insertion
#   - abcde's actual output layout and MusicBrainz lookup
#   - the read-error grep patterns (needs a deliberately scratched disc)
#   - eject
#
# Usage:  ./lathe/ingest/autorip-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTORIP="$SCRIPT_DIR/autorip.sh"

[ -x "$AUTORIP" ] || { echo "error: $AUTORIP is not executable" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

jget() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2" 2>/dev/null; }
jvalid() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; }

# A stub standing in for abcde. Reads OUTPUTDIR out of the per-run overlay
# config autorip.sh writes, then fabricates what a real rip would leave behind:
# <Artist>/<Album>/<tracks>. The STUB_* variables shape each case's outcome.
cat > "$TMP/abcde-stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

conf=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-c" ]; then conf="$arg"; fi
  prev="$arg"
done
[ -n "$conf" ] || { echo "stub: no -c config passed" >&2; exit 64; }

outdir="$(sed -n 's/^OUTPUTDIR=//p' "$conf" | head -1)"
[ -n "$outdir" ] || { echo "stub: no OUTPUTDIR in $conf" >&2; exit 64; }

if [ -n "${STUB_LOG:-}" ]; then
  echo "$STUB_LOG"
fi

if [ "${STUB_EXIT:-0}" -ne 0 ]; then
  echo "stub: pretending abcde failed"
  exit "${STUB_EXIT}"
fi

album="$outdir/${STUB_ARTIST:-Test Artist}/${STUB_ALBUM:-Test Album}"
mkdir -p "$album"

n="${STUB_TRACKS:-3}"
i=1
while [ "$i" -le "$n" ]; do
  printf 'not really audio\n' > "$(printf '%s/%02d Track %d.flac' "$album" "$i" "$i")"
  i=$((i + 1))
done
echo "stub: wrote $n tracks to $album"
STUB
chmod +x "$TMP/abcde-stub"

# Fresh /srv-alike per case, so cases can't leak into each other.
new_root() {
  local root="$TMP/root$1"
  mkdir -p "$root/rips" "$root/inbox" "$root/logs"
  printf '%s' "$root"
}

# Every variable is passed explicitly through `env` rather than as assignment
# prefixes. Assignment recognition happens before expansion, so a "$@" that
# expands to VAR=value is treated as a command name, not an assignment — which
# is exactly how this harness failed the first time.
run_autorip() {
  local root="$1" discid="$2"
  env \
    RIPS="$root/rips" \
    INBOX="$root/inbox" \
    RIP_LOGS="$root/logs" \
    ABCDE_CMD="$TMP/abcde-stub" \
    NTFY_URL="" \
    DISC_ID_OVERRIDE="$discid" \
    STUB_ARTIST="${STUB_ARTIST:-}" \
    STUB_ALBUM="${STUB_ALBUM:-}" \
    STUB_TRACKS="${STUB_TRACKS:-}" \
    STUB_EXIT="${STUB_EXIT:-}" \
    STUB_LOG="${STUB_LOG:-}" \
    "$AUTORIP" sr0
}

reset_stub_vars() { unset STUB_ARTIST STUB_ALBUM STUB_TRACKS STUB_EXIT STUB_LOG; }
reset_stub_vars

# --- 1. The happy path ---------------------------------------------------
echo
echo "case 1: a clean rip lands in the inbox"
root="$(new_root 1)"
run_autorip "$root" DISC001 >/dev/null 2>&1 || true

check "album moved into the inbox" \
  "$([ -d "$root/inbox/Test Artist - Test Album" ] && echo yes || echo no)" "yes"
check "tracks came with it" \
  "$(find "$root/inbox" -name '*.flac' | wc -l | tr -d ' ')" "3"
check "nothing left in staging" \
  "$(find "$root/rips" -mindepth 1 -type d | wc -l | tr -d ' ')" "0"
check "raw log written" \
  "$([ -s "$root/logs/DISC001.log" ] && echo yes || echo no)" "yes"

if jvalid "$root/logs/DISC001.json"; then
  ok "json log parses"
  check "status is ok"       "$(jget "$root/logs/DISC001.json" status)"       "ok"
  check "handoff_path set"   "$(jget "$root/logs/DISC001.json" handoff_path)" "$root/inbox/Test Artist - Test Album"
  check "track_count set"    "$(jget "$root/logs/DISC001.json" track_count)"  "3"
  check "no read errors"     "$(jget "$root/logs/DISC001.json" read_errors)"  "False"
  check "disc_id recorded"   "$(jget "$root/logs/DISC001.json" disc_id)"      "DISC001"
else
  bad "json log parses"
fi

# --- 2. Collision with an album already in the inbox ---------------------
echo
echo "case 2: a second disc with the same artist/album gets a suffix"
root="$(new_root 2)"
run_autorip "$root" DISC00A >/dev/null 2>&1 || true
run_autorip "$root" DISC00B >/dev/null 2>&1 || true

check "first copy kept its plain name" \
  "$([ -d "$root/inbox/Test Artist - Test Album" ] && echo yes || echo no)" "yes"
check "second copy got the disc-id suffix" \
  "$([ -d "$root/inbox/Test Artist - Test Album [DISC00B]" ] && echo yes || echo no)" "yes"
check "two albums, neither clobbered" \
  "$(find "$root/inbox" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" "2"
check "first copy's tracks intact" \
  "$(find "$root/inbox/Test Artist - Test Album" -name '*.flac' | wc -l | tr -d ' ')" "3"

# --- 3. Names that would break naive quoting ------------------------------
echo
echo "case 3: quotes, ampersands and non-ASCII survive the round trip"
root="$(new_root 3)"
STUB_ARTIST="Sigur Rós"
STUB_ALBUM='Takk... & "More"'
run_autorip "$root" DISC002 >/dev/null 2>&1 || true
reset_stub_vars

check "album with awkward name moved" \
  "$([ -d "$root/inbox/Sigur Rós - Takk... & \"More\"" ] && echo yes || echo no)" "yes"
if jvalid "$root/logs/DISC002.json"; then
  ok "json log parses with awkward names"
  check "album name preserved exactly" "$(jget "$root/logs/DISC002.json" album)" 'Takk... & "More"'
  check "artist name preserved exactly" "$(jget "$root/logs/DISC002.json" artist)" 'Sigur Rós'
else
  bad "json log parses with awkward names"
fi

# --- 4. abcde fails -------------------------------------------------------
echo
echo "case 4: a failed rip puts nothing in the inbox and says so"
root="$(new_root 4)"
STUB_EXIT=3
rc=0
run_autorip "$root" DISC003 >/dev/null 2>&1 || rc=$?
reset_stub_vars

check "autorip exits non-zero" "$rc" "1"
check "inbox untouched" \
  "$(find "$root/inbox" -mindepth 1 | wc -l | tr -d ' ')" "0"
check "work directory kept for inspection" \
  "$([ -n "$(find "$root/rips/.work" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ] && echo yes || echo no)" "yes"
if jvalid "$root/logs/DISC003.json"; then
  ok "failure json log parses"
  check "status is failed" "$(jget "$root/logs/DISC003.json" status)" "failed"
  check "handoff_path is null" "$(jget "$root/logs/DISC003.json" handoff_path)" "None"
else
  bad "failure json log parses"
fi

# --- 5. Rip 'succeeds' but produces no audio ------------------------------
echo
echo "case 5: a rip that produces no audio is a failure, not a hand-off"
root="$(new_root 5)"
STUB_TRACKS=0
rc=0
run_autorip "$root" DISC004 >/dev/null 2>&1 || rc=$?
reset_stub_vars

check "autorip exits non-zero" "$rc" "1"
check "inbox untouched" \
  "$(find "$root/inbox" -mindepth 1 | wc -l | tr -d ' ')" "0"
check "status is failed" "$(jget "$root/logs/DISC004.json" status)" "failed"

# --- 6. Read errors are flagged ------------------------------------------
echo
echo "case 6: read errors are flagged on an otherwise-good rip"
root="$(new_root 6)"
STUB_LOG="cdparanoia: Unable to read block 12345"
run_autorip "$root" DISC005 >/dev/null 2>&1 || true
reset_stub_vars

check "album still handed off" \
  "$([ -d "$root/inbox/Test Artist - Test Album" ] && echo yes || echo no)" "yes"
if jvalid "$root/logs/DISC005.json"; then
  ok "json log parses"
  check "read_errors flagged true" "$(jget "$root/logs/DISC005.json" read_errors)" "True"
  check "status still ok" "$(jget "$root/logs/DISC005.json" status)" "ok"
else
  bad "json log parses"
fi

# --- 7. Staging and inbox on different filesystems -------------------------
echo
echo "case 7: a non-atomic hand-off is refused before ripping"
root="$(new_root 7)"
rc=0
env \
  RIPS="$root/rips" \
  INBOX=/dev/shm \
  RIP_LOGS="$root/logs" \
  ABCDE_CMD="$TMP/abcde-stub" \
  NTFY_URL="" \
  DISC_ID_OVERRIDE=DISC006 \
  "$AUTORIP" sr0 >/dev/null 2>&1 || rc=$?

if [ "$(stat -c %d "$root/rips")" = "$(stat -c %d /dev/shm)" ]; then
  echo "  skip  /dev/shm is on the same filesystem here — cannot test the guard"
else
  check "autorip refuses to rip" "$rc" "1"
  check "nothing was ripped" \
    "$(find "$root/rips" -name '*.flac' | wc -l | tr -d ' ')" "0"
  check "status is failed" "$(jget "$root/logs/DISC006.json" status)" "failed"
fi

# --- Summary --------------------------------------------------------------
echo
echo "-----------------------------------------"
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
