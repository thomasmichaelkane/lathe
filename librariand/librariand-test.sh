#!/usr/bin/env bash
# Run librariand's test suite.
#
# The tests themselves are Python (librariand_test.py) because they drive a
# FastAPI app through its test client; this wrapper exists so the entry point
# matches every other suite in the repo, and so finding an interpreter with
# FastAPI in it is not your problem.
#
# Usage:  ./lathe/librariand/librariand-test.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

have_fastapi() {
  [ -x "$1" ] && "$1" -c 'import fastapi, jinja2, multipart' >/dev/null 2>&1
}

PY=""
for candidate in \
  "${LIBRARIAND_PYTHON:-}" \
  /usr/local/lib/librariand/venv/bin/python \
  "$HERE/../.venv/bin/python" \
  "$(command -v python3 || true)"
do
  [ -n "$candidate" ] || continue
  if have_fastapi "$candidate"; then PY="$candidate"; break; fi
done

if [ -z "$PY" ]; then
  cat >&2 <<'EOF'
librariand-test: no Python with FastAPI available.

On the Pi, install.sh builds one at /usr/local/lib/librariand/venv and this
script finds it automatically. Anywhere else, make one:

    python3 -m venv /tmp/lbd-venv
    /tmp/lbd-venv/bin/pip install fastapi uvicorn jinja2 python-multipart mediafile
    LIBRARIAND_PYTHON=/tmp/lbd-venv/bin/python ./lathe/librariand/librariand-test.sh
EOF
  exit 1
fi

# ffmpeg builds the fixture FLACs. Without it the tag reading would have to be
# mocked, which would test the mock.
command -v ffmpeg >/dev/null 2>&1 || {
  echo "librariand-test: ffmpeg is required to fabricate test audio" >&2
  exit 1
}

exec "$PY" "$HERE/librariand_test.py"
