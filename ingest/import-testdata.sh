#!/usr/bin/env bash
# Run the REAL inbox-import.sh against the local test harness.
#
# The two-pass cascade in inbox-import.sh is the part most worth testing and
# the easiest to get subtly wrong, so the harness drives that script directly
# rather than reimplementing it here. A local copy of the pass ordering would
# drift from production silently, which is the failure this whole harness
# exists to prevent.
#
# Config layering works the same way as beet-test.sh: BEETSDIR makes the
# production config the base, and BEETS_CONFIG is the test overlay laid on top.
#
# Usage:  ./lathe/ingest/reset-testdata.sh && ./lathe/ingest/import-testdata.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export BEETSDIR="$ROOT/lathe/ingest/beets"

export INBOX="$ROOT/testdata/staging"
export QUARANTINE="$ROOT/testdata/quarantine"
export BEETS_CONFIG="$ROOT/testdata/beets/config-test.yaml"
export LOG="$ROOT/testdata/logs/inbox-import.log"
# The harness is never mid-copy; don't sit through the settle loop.
export SETTLE_SECONDS=0
# Split CD images with the repo copy, not a deployed one.
export CUESPLIT="$ROOT/lathe/ingest/cuesplit.py"

for f in "$BEETSDIR/config.yaml" "$BEETS_CONFIG"; do
  [ -f "$f" ] || { echo "error: missing $f" >&2; exit 1; }
done
mkdir -p "$QUARANTINE" "$(dirname "$LOG")"

# Same guards as beet-test.sh. If the overlay stopped winning, `directory`
# would still be /srv/music and this would import into a real music library.
merged="$(beet -c "$BEETS_CONFIG" config 2>/dev/null)"
if ! grep -q 'strong_rec_thresh' <<<"$merged"; then
  echo "error: production config is not being layered in." >&2
  echo "       'strong_rec_thresh' absent from merged config — check BEETSDIR." >&2
  exit 1
fi
if ! grep -q "$ROOT/testdata/library" <<<"$merged"; then
  echo "error: test overlay is not winning — 'directory' is not the test library." >&2
  echo "       Refusing to run: this could write into a real music directory." >&2
  exit 1
fi
# The cascade is a no-op without this, and fails silently when it is missing.
if ! grep -qE 'incremental_skip_later:\s*(yes|true)' <<<"$merged"; then
  echo "error: incremental_skip_later is not enabled." >&2
  echo "       Pass 1 would record its skips and pass 2 would import nothing." >&2
  exit 1
fi

exec "$ROOT/lathe/ingest/inbox-import.sh"
