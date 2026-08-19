#!/usr/bin/env bash
# Run beets against the local test harness using the REAL production config.
#
# beets layers config: $BEETSDIR/config.yaml is the base, and -c is overlaid on
# top of it. So pointing BEETSDIR at ingest/beets makes the production config
# the base, and the test overlay replaces only the paths. Tuning here is
# therefore tuning the thing that ships.
#
# Note there is no `include:` directive in beets — it accepts the key and
# silently ignores it. This wrapper exists so nobody has to remember that.
#
# Usage:  ./lathe/ingest/beet-test.sh import ../../testdata/staging
#         ./lathe/ingest/beet-test.sh config
#         ./lathe/ingest/beet-test.sh ls -a

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export BEETSDIR="$ROOT/lathe/ingest/beets"
OVERLAY="$ROOT/testdata/beets/config-test.yaml"

for f in "$BEETSDIR/config.yaml" "$OVERLAY"; do
  [ -f "$f" ] || { echo "error: missing $f" >&2; exit 1; }
done

# Guard against the layering silently breaking again. If the production config
# stopped being read, 'plugins' and the path templates would vanish and we'd be
# tuning an empty config while appearing to work.
merged="$(beet -c "$OVERLAY" config 2>/dev/null)"
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

exec beet -c "$OVERLAY" "$@"
