#!/usr/bin/env bash
# Reset the local beets test harness to a known state.
#
# beets imports with `move: yes`, so every run consumes its input and rewrites
# the tree. Tuning path templates means running the same import many times, so
# this restores a clean starting point each time.
#
# originals/ is the pristine master and is NEVER written to — it is the only
# copy that matters. Everything else here is disposable.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTDATA="$ROOT/testdata"

ORIGINALS="$TESTDATA/originals"
STAGING="$TESTDATA/staging"
LIBRARY="$TESTDATA/library"
QUARANTINE="$TESTDATA/quarantine"
LOGS="$TESTDATA/logs"
BEETSDB="$TESTDATA/beets/library.db"
BEETSSTATE="$TESTDATA/beets/state.pickle"

if [ ! -d "$ORIGINALS" ] || [ -z "$(ls -A "$ORIGINALS" 2>/dev/null)" ]; then
  echo "error: $ORIGINALS is empty." >&2
  echo "Put a few albums there first — see 'Phase -1(b)' in lathe/docs/plan.md" >&2
  exit 1
fi

echo "Resetting test harness under $TESTDATA"

# Wipe everything derived. Guard each rm with the variable being non-empty so a
# path that failed to expand can never turn this into 'rm -rf /'.
for d in "$STAGING" "$LIBRARY" "$QUARANTINE" "$LOGS"; do
  [ -n "$d" ] && rm -rf "${d:?}"/* "${d:?}"/.[!.]* 2>/dev/null || true
  mkdir -p "$d"
done

# Both, always. Removing only the db leaves the incremental state behind and
# every later import skips everything as "previously-imported".
# The .bak files are schema-migration backups beets writes on each new db.
rm -f "$BEETSDB" "$BEETSSTATE" "$BEETSDB"-*.bak

# Re-copy the pristine originals into staging for beets to consume.
cp -a "$ORIGINALS"/. "$STAGING"/

albums=$(find "$STAGING" -mindepth 1 -maxdepth 1 -type d | wc -l)
tracks=$(find "$STAGING" -type f \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.ogg' \) | wc -l)

echo "  staging:  $albums top-level entries, $tracks audio files"
echo "  library:  emptied"
echo "  beets db: removed (db + incremental state)"
echo
echo "Next:"
echo "  ./lathe/ingest/beet-test.sh import $STAGING"
