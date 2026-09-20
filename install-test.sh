#!/usr/bin/env bash
# Exercise install.sh's preconditions and its deploy plan, without root.
#
# install.sh writes to /usr/local/bin, /etc and /srv, so the actual write path
# cannot run unprivileged and is not tested here — it is verified by the first
# real deploy. What IS testable without root is everything that decides whether
# a deploy should happen at all, and that is where the dangerous bugs live:
#
#   - refusing to deploy onto an unmounted /srv, which would write the beets
#     config onto the boot media underneath the mountpoint
#   - the §4 tree it plans to create
#   - the preconditions it refuses on
#
# The repo is copied to a temporary tree and the beets pluginpath rewritten to
# match, so the pluginpath consistency check inside install.sh sees a coherent
# pair rather than being special-cased for the test.
#
# Usage:  ./lathe/install-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
has()  { if grep -qF "$2" "$3"; then ok "$1"; else bad "$1 (not found: $2)"; fi; }
hasnt(){ if grep -qF "$2" "$3"; then bad "$1 (unexpectedly found: $2)"; else ok "$1"; fi; }

# A copy of the repo whose beets pluginpath points inside the sandbox.
REPO="$TMP/repo"
SRV="$TMP/srv"
mkdir -p "$REPO" "$SRV"
tar -C "$SCRIPT_DIR" --exclude=.git --exclude=.claude -cf - . | tar -C "$REPO" -xf -
sed -i "s|/srv/config/beets/plugins|$SRV/config/beets/plugins|" "$REPO/ingest/beets/config.yaml"

OUT="$TMP/out.txt"

run() {
  set +e
  env "$@" bash "$REPO/install.sh" --dry-run >"$OUT" 2>&1
  LAST=$?
  set -e
}

echo
echo "the unmounted-/srv guard"

# The case this exists for: /srv is a directory on the boot media because the
# library drive did not mount, which nofail makes an ordinary boot state.
run SRV="$SRV" MUSIC_USER="$(id -un)"
check "dry run still completes"        "$LAST" "0"
has   "and warns /srv is not a mount"  "is not a mount point"        "$OUT"
has   "saying a real run would refuse" "A real run would refuse"     "$OUT"

run SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1
check "the test-harness override is honoured" "$LAST" "0"
hasnt "and silences the warning"       "is not a mount point"        "$OUT"

echo
echo "the §4 tree it plans to create"

run SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1
for d in music inbox quarantine staging/rips staging/fetched staging/incoming \
         config/navidrome config/beets config/librariand logs/rips; do
  has "plans $d" "WOULD CREATE  $SRV/$d" "$OUT"
done

# A dry run that creates directories would defeat the point of a dry run.
check "and creates nothing on disk" "$(find "$SRV" -mindepth 1 | wc -l | tr -d ' ')" "0"

echo
echo "it is idempotent"

mkdir -p "$SRV"/{music,inbox,quarantine} \
         "$SRV"/staging/{rips,fetched,incoming} \
         "$SRV"/config/{navidrome,beets,librariand} \
         "$SRV"/logs/rips
run SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1
has   "an existing tree is left alone" "all §4 directories already present" "$OUT"
hasnt "with nothing re-created"        "WOULD CREATE  $SRV/music"           "$OUT"

echo
echo "preconditions it refuses on"

run SRV="$SRV" MUSIC_USER=definitely-no-such-user ALLOW_UNMOUNTED_SRV=1
check "a missing music user is fatal" "$LAST" "1"
has   "and says which user"           "definitely-no-such-user' does not exist" "$OUT"

run SRV="$TMP/nonexistent" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1
check "a missing /srv is fatal"       "$LAST" "1"
has   "and says so"                   "does not exist — run Phase 0 first"     "$OUT"

# The pluginpath in the beets config is a literal absolute string. If it and the
# deploy target ever disagree, beets loads no local plugins and says nothing.
cp "$REPO/ingest/beets/config.yaml" "$TMP/config.bak"
sed -i "s|$SRV/config/beets/plugins|/somewhere/else/plugins|" "$REPO/ingest/beets/config.yaml"
run SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1
check "a pluginpath mismatch is fatal" "$LAST" "1"
has   "and names the expected path"    "pluginpath does not point at"  "$OUT"
cp "$TMP/config.bak" "$REPO/ingest/beets/config.yaml"

echo
echo "the rest of the deploy plan"

run SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1
has "deploys both scripts"      "/usr/local/bin/inbox-import.sh"          "$OUT"
has "deploys abcde.conf"        "/etc/abcde.conf"                         "$OUT"
has "deploys the beets config"  "$SRV/config/beets/config.yaml"           "$OUT"
has "deploys the udev rule"     "/etc/udev/rules.d/99-autorip.rules"      "$OUT"
has "deploys the path unit"     "/etc/systemd/system/inbox.path"          "$OUT"
has "creates the env file"      "/etc/default/lathe"                      "$OUT"

echo
echo "-----------------------------------------"
printf 'install-test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
