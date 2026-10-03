#!/usr/bin/env bash
# Does the import convert what it should to FLAC, and nothing else?
#
# Runs a real beets import of one album holding a track in every format that
# matters, against the PRODUCTION config's `convert:` block, and checks what
# landed in the library. No network: the import is as-is (`-A`), and the
# overlay loads only the plugins the conversion and the path templates need.
#
# Why this needs real beets and real files: `no_convert` is a regex over the
# format names mediafile reports. A typo there is not an error anywhere — the
# format just quietly stops converting — and the dangerous direction is just
# as quiet: `.m4a` holds ALAC (lossless) or AAC (lossy), and a query that
# caught AAC would file a re-encoded lossy track as FLAC (#63).
#
# APE is the one converted format with no track here: ffmpeg decodes it but
# cannot encode it, so there is no way to make the fixture.
#
#   ./lathe/ingest/convert-test.sh                 # beet from PATH
#   ./lathe/ingest/convert-test.sh BEET CONFIG     # a specific pair
#
# PLUGINPATH, if set, replaces the config's pluginpath, as in beets-check.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEET="${1:-beet}"
CONFIG="${2:-$SCRIPT_DIR/beets/config.yaml}"

[ -r "$CONFIG" ] || { echo "convert-test: cannot read $CONFIG" >&2; exit 2; }
for tool in "$BEET" ffmpeg ffprobe; do
  command -v "$tool" >/dev/null 2>&1 || { echo "convert-test: $tool not found on PATH" >&2; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# The production config is the base (BEETSDIR) and this replaces only paths —
# and the plugin list, cut to what an offline as-is import needs: `convert`
# itself, and `inline` for the path templates' $multidisc.
{
  echo "directory: $WORK/music"
  echo "library: $WORK/library.db"
  echo "statefile: $WORK/state.pickle"
  echo "plugins: convert inline"
  echo "import:"
  echo "  log: $WORK/import.log"
  echo "convert:"
  echo "  tmpdir: $WORK/convert"
  if [ -n "${PLUGINPATH:-}" ]; then
    echo "pluginpath:"
    echo "  - $PLUGINPATH"
  fi
} >"$WORK/overlay.yaml"
mkdir -p "$WORK/music" "$WORK/convert"

# One second of noise per track: unlike a sine, noise survives nothing lossy,
# so the decoded-audio comparison below cannot pass by accident.
ALBUM="$WORK/inbox/Format Zoo"
mkdir -p "$ALBUM"
n=0
track() {  # track NAME FILE [ffmpeg output options...]
  local name="$1" file="$2"; shift 2
  n=$((n + 1))
  ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "anoisesrc=d=1:c=pink:r=44100:a=0.5" \
    -ac 2 -metadata title="$name" -metadata artist="Test" -metadata album_artist="Test" \
    -metadata album="Format Zoo" -metadata track="$n" "$@" "$ALBUM/$file"
}
track alac16   "01 alac16.m4a"  -c:a alac -sample_fmt s16p
track alac24   "02 alac24.m4a"  -c:a alac -sample_fmt s32p
track aac      "03 aac.m4a"     -c:a aac -b:a 128k
track wav      "04 wav.wav"     -c:a pcm_s16le
track aiff     "05 aiff.aiff"   -c:a pcm_s16be
track wavpack  "06 wavpack.wv"  -c:a wavpack
track flac     "07 flac.flac"   -c:a flac
track mp3      "08 mp3.mp3"     -c:a libmp3lame -b:a 128k
track vorbis   "09 vorbis.ogg"  -c:a libvorbis
track opus     "10 opus.opus"   -c:a libopus -ar 48000

# What the audio decodes to, as a checksum. Equal before and after means the
# conversion lost nothing; the bit depth is checked separately. It is also how
# a converted track is FOUND afterwards: ffmpeg cannot write a WAV or AIFF tag
# that beets reads, so those two land untitled, and the audio is their name.
pcm() { ffmpeg -nostdin -hide_banner -loglevel error -i "$1" -map 0:a:0 -c:a pcm_s24le -f md5 - ; }
declare -A BEFORE
for f in "$ALBUM"/*; do
  name="$(basename "$f")"; name="${name#* }"; name="${name%.*}"
  BEFORE[$name]="$(pcm "$f")"
done

if ! out="$(BEETSDIR="$(dirname "$CONFIG")" "$BEET" -c "$WORK/overlay.yaml" import -A "$ALBUM" 2>&1)"; then
  echo "convert-test: beet import failed:" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

# The library file for a track: by its audio, or (lossy, where the checksum
# of a decode is not stable enough to lean on) by title. Empty if not there.
declare -A AFTER
while IFS= read -r -d '' f; do
  AFTER[$(pcm "$f")]="$f"
done < <(find "$WORK/music" -type f -print0)
same_audio() { printf '%s' "${AFTER[${BEFORE[$1]}]:-}"; }
landed() { find "$WORK/music" -type f -name "* $1.*" | head -1; }
codec() { ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$1"; }
bits()  { ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_raw_sample -of csv=p=0 "$1"; }

echo "lossless becomes FLAC, unchanged"
for name in alac16 alac24 wav aiff wavpack; do
  f="$(same_audio "$name")"
  if [ -z "$f" ]; then bad "$name is in the library with its audio intact"; continue; fi
  ok "$name is in the library with its audio intact"
  check "$name is filed as .flac" "${f##*.}" "flac"
  check "$name really is FLAC inside" "$(codec "$f")" "flac"
done
check "24-bit ALAC stays 24-bit" "$(bits "$(same_audio alac24)")" "24"
check "16-bit ALAC stays 16-bit" "$(bits "$(same_audio alac16)")" "16"

echo "FLAC and lossy are left exactly as they arrived"
for pair in aac:m4a:aac flac:flac:flac mp3:mp3:mp3 vorbis:ogg:vorbis opus:opus:opus; do
  IFS=: read -r name ext want <<<"$pair"
  f="$(landed "$name")"
  if [ -z "$f" ]; then bad "$name was imported"; continue; fi
  check "$name keeps its .$ext" "${f##*.}" "$ext"
  check "$name is still $want inside" "$(codec "$f")" "$want"
done

echo "nothing is left behind"
check "the originals are gone from the inbox" \
  "$(find "$WORK/inbox" -type f | wc -l | tr -d ' ')" "0"
check "and so are the temporary encodes" \
  "$(find "$WORK/convert" -type f | wc -l | tr -d ' ')" "0"

echo
echo "-----------------------------------------"
echo "convert-test: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  { echo "what landed in the library:"; find "$WORK/music" -type f | sort
    echo "beets said:"; printf '%s\n' "$out"; } >&2
  exit 1
fi
