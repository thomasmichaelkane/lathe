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
has()  { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1 (not found: $2)"; fi; }
hasnt(){ if grep -qF -- "$2" "$3"; then bad "$1 (unexpectedly found: $2)"; else ok "$1"; fi; }

# A copy of the repo whose beets pluginpath points inside the sandbox.
REPO="$TMP/repo"
SRV="$TMP/srv"
mkdir -p "$REPO" "$SRV"
tar -C "$SCRIPT_DIR" --exclude=.git --exclude=.claude -cf - . | tar -C "$REPO" -xf -
sed -i "s|/srv/config/beets/plugins|$SRV/config/beets/plugins|" "$REPO/ingest/beets/config.yaml"

OUT="$TMP/out.txt"
LATHE_RELEASE_DEFAULT="/etc/lathe-release"

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
has "deploys the journald cap"  "/etc/systemd/journald.conf.d/lathe.conf" "$OUT"
has "deploys the path unit"     "/etc/systemd/system/inbox.path"          "$OUT"
has "creates the env file"      "/etc/default/lathe"                      "$OUT"

echo
echo "--uninstall"

run_uninstall() {
  set +e
  env "$@" bash "$REPO/install.sh" --uninstall --dry-run >"$OUT" 2>&1
  LAST=$?
  set -e
}

# An uninstall must work on a system that is already broken — that is when you
# reach for it. None of the deploy preconditions should apply.
run_uninstall SRV="$TMP/nonexistent" MUSIC_USER=definitely-no-such-user
check "runs without a music user or a mounted /srv" "$LAST" "0"
has   "and names what it leaves alone" "LEFT ALONE, deliberately"  "$OUT"
has   "including the env file"         "/etc/default/lathe"        "$OUT"

run_uninstall SRV="$SRV" MUSIC_USER="$(id -un)"
check "dry run removes nothing" "$(find "$SRV" -mindepth 1 -type f | wc -l | tr -d ' ')" "0"

echo
echo "install and uninstall cannot drift apart"

# The real risk in having two lists of deployed paths is that someone adds a
# unit or a plugin to one and not the other, and uninstall silently leaves
# files behind. So: every path a deploy would WRITE must be a path an uninstall
# would REMOVE — excluding the §4 tree (directories, not deployed files) and
# /etc/default/lathe, both of which uninstall leaves alone on purpose.
run SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1
cp "$OUT" "$TMP/install-plan.txt"
run_uninstall SRV="$SRV" MUSIC_USER="$(id -un)"
cp "$OUT" "$TMP/uninstall-plan.txt"

is_left_alone() {
  case "$1" in
    "$SRV/music"|"$SRV/inbox"|"$SRV/quarantine") return 0 ;;
    "$SRV/staging/rips"|"$SRV/staging/fetched"|"$SRV/staging/incoming") return 0 ;;
    "$SRV/config/navidrome"|"$SRV/config/beets"|"$SRV/config/librariand") return 0 ;;
    "$SRV/logs/rips") return 0 ;;
    /etc/default/lathe) return 0 ;;
  esac
  return 1
}

drifted=0
checked=0
while read -r path; do
  [ -n "$path" ] || continue
  is_left_alone "$path" && continue
  checked=$((checked + 1))
  # Covered either by being named outright, or by a parent directory being
  # removed whole — which is how the librariand venv goes, since it is built
  # rather than copied and so is not in deployed_targets.
  covered=0
  grep -qF -- "$path" "$TMP/uninstall-plan.txt" && covered=1
  if [ "$covered" -eq 0 ]; then
    while read -r rmdir_line; do
      case "$path" in "$rmdir_line"*) covered=1; break ;; esac
    done < <(sed -n 's#^ *\(WOULD REMOVE\|removed\|absent\) *\([^ ]*/\)\( .*\)\?$#\2#p' "$TMP/uninstall-plan.txt")
  fi
  [ "$covered" -eq 1 ] \
    || { bad "deployed but never removed: $path"; drifted=1; }
done < <(sed -n 's/^  WOULD \(CREATE\|UPDATE\)  \([^ ]*\).*/\2/p' "$TMP/install-plan.txt")

[ "$checked" -ge 8 ] || bad "only $checked deploy targets seen — the parse above is wrong"
[ "$drifted" -eq 0 ] && ok "every deployed file is covered by --uninstall ($checked targets)"

# And the other direction, which the check above cannot see. uninstall derives
# its list by globbing the repo; if the deploy side is ever a hand-written list
# again, a new file is known to uninstall but never shipped. That is not
# hypothetical: install.sh listed six librariand modules by hand, inbox.py was
# added later, and librariand would have died on `import inbox` on first start.
missing=0
seen=0
while read -r path; do
  [ -n "$path" ] || continue
  seen=$((seen + 1))
  grep -qF -- "$path" "$TMP/install-plan.txt" \
    || { bad "uninstall knows about it but install never ships it: $path"; missing=1; }
done < <(sed -n 's#^ *\(WOULD REMOVE\|removed\|absent\) *\(/[^ ]*[^/ ]\)\( .*\)\?$#\2#p' "$TMP/uninstall-plan.txt")

[ "$seen" -ge 8 ] || bad "only $seen uninstall targets seen — the parse above is wrong"
[ "$missing" -eq 0 ] && ok "every file uninstall removes is one install ships ($seen targets)"

echo
echo "versions come from release tags"

# A second copy of the repo, this time a real git repository, because version
# derivation and the dirty check only exist when there is git to ask. The
# pluginpath is rewritten BEFORE the commit so the tree starts clean.
GREPO="$TMP/gitrepo"
mkdir -p "$GREPO"
tar -C "$SCRIPT_DIR" --exclude=.git --exclude=.claude -cf - . | tar -C "$GREPO" -xf -
sed -i "s|/srv/config/beets/plugins|$SRV/config/beets/plugins|" "$GREPO/ingest/beets/config.yaml"
g() { git -C "$GREPO" -c user.name=test -c user.email=test@example.invalid "$@"; }
g init -q
g add -A
g commit -q -m "fixture"

run_g() {
  set +e
  env "$@" bash "$GREPO/install.sh" --dry-run >"$OUT" 2>&1
  LAST=$?
  set -e
}

run_g SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1
has "with no tags yet, the version is the commit" "lathe install — $(g rev-parse --short HEAD)" "$OUT"

g tag not-a-release
run_g SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1
hasnt "a tag that is not x.y.z cannot pose as a release" "lathe install — not-a-release" "$OUT"

g tag 0.1.0
run_g SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1
has "on a release tag, the version is the tag" "lathe install — 0.1.0 (" "$OUT"
has "and the release stamp is part of the plan" "$LATHE_RELEASE_DEFAULT" "$OUT"

g commit -q --allow-empty -m "after the release"
run_g SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1
has "past a tag, it says so rather than claiming the release" "lathe install — 0.1.0-1-g" "$OUT"

echo
echo "a dirty checkout is refused"

run_g SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1
hasnt "a clean checkout raises nothing" "local changes" "$OUT"

echo "# edited on the Pi" >> "$GREPO/ingest/abcde.conf"
run_g SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1
has "an edited file is caught"          "a real run would refuse" "$OUT"
has "and named"                         "ingest/abcde.conf"       "$OUT"
has "and the version admits it"         "-dirty"                  "$OUT"
g checkout -q -- ingest/abcde.conf

# The case that makes this more than tidiness: the deploy globs, so an
# untracked file in the right directory would ship as part of the release.
touch "$GREPO/systemd/made-on-the-pi.service"
run_g SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1
has "an untracked file is caught too"   "systemd/made-on-the-pi.service" "$OUT"
set +e
env SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1 \
  bash "$GREPO/install.sh" --dry-run --allow-dirty >"$OUT" 2>&1
LAST=$?
set -e
check "--allow-dirty is accepted"       "$LAST" "0"
hasnt "and silences the refusal"        "a real run would refuse" "$OUT"
rm -f "$GREPO/systemd/made-on-the-pi.service"

echo
echo "new settings reach an existing /etc/default/lathe"

ENVF="$TMP/lathe.env"
cat > "$ENVF" <<'EOF'
NTFY_URL=https://ntfy.sh/secret
NAVIDROME_URL=http://localhost:4533
NAVIDROME_USER=tom
# NAVIDROME_PASS=   deliberately commented out
EOF
before="$(sha256sum "$ENVF")"
run SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1 LATHE_ENV="$ENVF"
has   "a setting the template has and yours lacks is named" "LIBRARIAND_TOKEN" "$OUT"
hasnt "a commented-out setting counts as seen"             "    NAVIDROME_PASS" "$OUT"
hasnt "settings you have are not listed"                   "    NTFY_URL"       "$OUT"
check "and your file is not touched" "$(sha256sum "$ENVF")" "$before"

echo "LIBRARIAND_TOKEN=abc" >> "$ENVF"
run SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1 LATHE_ENV="$ENVF"
hasnt "once complete, nothing is flagged" "lacks setting" "$OUT"

echo
echo "the venv follows requirements.txt"

LBD="$TMP/lbd"
run SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1 LIBRARIAND_DIR="$LBD"
has "with no venv, one is planned" "WOULD CREATE  $LBD/venv" "$OUT"

mkdir -p "$LBD/venv/bin"
printf '#!/bin/sh\n' > "$LBD/venv/bin/python" && chmod +x "$LBD/venv/bin/python"
cp "$REPO/librariand/requirements.txt" "$LBD/venv/.installed-requirements"
run SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1 LIBRARIAND_DIR="$LBD"
has "matching requirements leave it alone" "unchanged  $LBD/venv" "$OUT"

echo "somenewdep==1.0" >> "$REPO/librariand/requirements.txt"
run SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1 LIBRARIAND_DIR="$LBD"
has "a changed requirements.txt updates it" "WOULD UPDATE  $LBD/venv (requirements.txt changed)" "$OUT"

# The failure mode this replaces: a venv that exists but never recorded a
# successful install is not "done", so the next deploy must retry it.
rm -f "$LBD/venv/.installed-requirements"
run SRV="$SRV" MUSIC_USER="$(id -un)" ALLOW_UNMOUNTED_SRV=1 LIBRARIAND_DIR="$LBD"
has "a venv with no record of success is retried" "WOULD UPDATE  $LBD/venv" "$OUT"

echo
echo "-----------------------------------------"
printf 'install-test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
