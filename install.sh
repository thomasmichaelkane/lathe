#!/usr/bin/env bash
# Deploy this repo onto the system paths.
#
# This is the ONLY way anything in this repo should reach a system path. The
# copy table is §11 of docs/plan.md, and it is reproduced below as the code that
# runs rather than as prose, so the table and the deploy can never disagree.
#
#   sudo ./install.sh              deploy
#   sudo ./install.sh --dry-run    show what would change, touch nothing
#   sudo ./install.sh --force      deploy even while an ingest unit is running
#   sudo ./install.sh --uninstall  remove everything this script deployed
#
# --uninstall takes --dry-run too, and reading that first is the habit. It
# removes only files this script put there, disables the triggers it enabled,
# and deliberately leaves /srv and /etc/default/lathe alone: the library, the
# beets database, and your ntfy and Navidrome credentials all outlive it.
#
# Why this exists at all: copying these by hand is fine exactly once, and a
# trap every time after. A hotfix applied straight to /etc/abcde.conf works,
# which is the problem — the repo silently stops describing the running system
# and the next deploy reverts the fix without saying anything (§12).
#
# It creates the §4 directory tree under /srv and sets its ownership and
# setgid bits, because the scripts it deploys cannot run without those
# directories — installing autorip.sh without /srv/staging/rips is half a
# deploy. It creates them; it never writes anything into them.
#
# What this script never touches the CONTENTS of:
#
#   /srv/music  /srv/inbox  /srv/quarantine  /srv/staging  /srv/logs
#   /srv/config/beets/library.db  /srv/config/beets/state.pickle
#   /srv/config/navidrome/
#   /etc/default/lathe    (created if absent, never overwritten — it holds the
#                          ntfy topic and the Navidrome password, neither of
#                          which is in the repo)
#
# Code is replaced. Data is not. Albums sitting in quarantine have no bearing
# on a deploy.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
FORCE=0
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=1 ;;
    -f|--force)   FORCE=1 ;;
    -u|--uninstall) UNINSTALL=1 ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

MUSIC_USER="${MUSIC_USER:-music}"
SRV="${SRV:-/srv}"
BEETS_DIR="${BEETS_DIR:-$SRV/config/beets}"

CHANGED=()
CHANGED_UNITS=()
ACTIVATABLE=()
SYSTEMD_CHANGED=0
UDEV_CHANGED=0
TMPFILES=()

# Any temp file still around on exit is a deploy that died partway. Clean them
# up so a half-written file can never be mistaken for a deployed one — the
# rename below is what publishes a file, so nothing swept here was ever live.
cleanup() {
  local t
  for t in "${TMPFILES[@]:-}"; do
    [ -n "$t" ] && [ -e "$t" ] && rm -f "$t"
  done
  # Explicit: an EXIT trap that ends on a non-zero status overrides the script's
  # own exit code, so a no-op cleanup would make every clean run look failed.
  return 0
}
trap cleanup EXIT

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preconditions

[ "$DRY_RUN" -eq 1 ] || [ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo ./install.sh)"

# An uninstall needs none of what follows: no music user (it may already be
# gone), no mounted /srv (paths simply report absent), and no pluginpath
# agreement (nothing is being installed). Requiring them would mean a broken
# system could not be cleaned up, which is backwards.
if [ "$UNINSTALL" -eq 0 ]; then

id -u "$MUSIC_USER" >/dev/null 2>&1 \
  || die "user '$MUSIC_USER' does not exist — run Phase 0 first (§11)"

[ -d "$SRV" ] || die "$SRV does not exist — run Phase 0 first (§11)"

# `-d` is not enough, and the difference is the whole ballgame. /srv exists on
# stock Debian whether or not the library drive is mounted on it, and `nofail`
# in fstab (§4) makes "booted fine, drive absent" an ordinary state rather than
# an obvious emergency. Deploy in that state and the beets config lands on the
# BOOT MEDIA underneath the mountpoint; the drive then mounts over the top and
# the config vanishes, with every later import reading a file that is not
# there. Same silent failure as building the tree before mounting it.
#
# ALLOW_UNMOUNTED_SRV exists for install-test.sh, which points SRV at a
# temporary directory. Never set it on a real machine.
if [ "${ALLOW_UNMOUNTED_SRV:-0}" != "1" ] && ! mountpoint -q "$SRV"; then
  if [ "$DRY_RUN" -eq 1 ]; then
    warn "$SRV is not a mount point. A real run would refuse."
  else
    die "$SRV is not a mount point — the library drive is not mounted.
       Deploying now would write the beets config onto the boot media,
       underneath the mountpoint, where the drive will hide it the moment
       it comes back. Mount it first (§4), then re-run."
  fi
fi

# The atomic hand-off from staging into the inbox is only atomic while both are
# on one filesystem. Mount them separately and `mv` silently becomes
# copy-then-delete: the path unit fires partway through and beets imports a
# half-written album (§12). Nothing else checks this, and the failure is silent,
# so check it here on every deploy — it costs one stat and catches a remount.
if [ -d "$SRV/inbox" ] && [ -d "$SRV/staging" ]; then
  if [ "$(stat -c %d "$SRV/inbox")" != "$(stat -c %d "$SRV/staging")" ]; then
    warn "$SRV/inbox and $SRV/staging are on DIFFERENT filesystems."
    warn "The hand-off into the inbox is no longer atomic — albums can be"
    warn "imported half-written. Fix the mounts before ingesting anything."
  fi
fi

# The pluginpath in the beets config is absolute (beets resolves it against the
# CWD, not the config directory), so it is a literal string that has to agree
# with where this script actually puts the plugins.
if ! grep -qF "$BEETS_DIR/plugins" "$REPO/ingest/beets/config.yaml"; then
  die "ingest/beets/config.yaml pluginpath does not point at $BEETS_DIR/plugins"
fi

# Replacing a script that is currently executing is the one genuine hazard in a
# deploy. bash reads a script incrementally as it runs, so truncating one in
# place (which is what cp does — same inode) makes a running shell resume at its
# old byte offset in different content and execute garbage. install_file()
# renames into place instead, so a running process keeps the inode it started
# with and finishes on the old version. That makes --force safe; the check is
# still the default because finishing an import on the old code and only then
# deploying is what you actually want.
if [ "$FORCE" -eq 0 ]; then
  busy=""
  systemctl is-active --quiet inbox-import.service 2>/dev/null && busy="inbox-import.service"
  if [ -z "$busy" ]; then
    active_rips="$(systemctl list-units 'autorip@*.service' --state=active --no-legend 2>/dev/null | awk '{print $1}')"
    [ -n "$active_rips" ] && busy="$active_rips"
  fi
  [ -z "$busy" ] && pgrep -f '/usr/local/bin/inbox-import\.sh' >/dev/null 2>&1 && busy="inbox-import.sh (not under systemd)"
  if [ -n "$busy" ]; then
    die "ingest is running ($busy). A bulk import can legitimately take hours.
       Wait for it, or re-run with --force — deployment renames files into
       place, so the running job finishes on the version it started with."
  fi
fi

fi  # end deploy-only preconditions

# Every path this script deploys to, derived from the repo rather than listed
# by hand, so adding a unit or a plugin cannot leave uninstall behind. The test
# suite asserts this covers everything a deploy would write.
deployed_targets() {
  printf '%s\n' /usr/local/bin/autorip.sh
  printf '%s\n' /usr/local/bin/inbox-import.sh
  printf '%s\n' /etc/abcde.conf
  printf '%s\n' "$BEETS_DIR/config.yaml"

  local f
  for f in "$REPO"/ingest/beets/plugins/*.py; do
    [ -e "$f" ] && printf '%s\n' "$BEETS_DIR/plugins/$(basename "$f")"
  done
  for f in "$REPO"/systemd/*.service "$REPO"/systemd/*.path "$REPO"/systemd/*.timer; do
    [ -e "$f" ] && printf '%s\n' "/etc/systemd/system/$(basename "$f")"
  done

  printf '%s\n' /etc/udev/rules.d/99-autorip.rules
}

# ----------------------------------------------------------------- uninstalling

if [ "$UNINSTALL" -eq 1 ]; then
  say "lathe uninstall — removing what $REPO deployed"
  [ "$DRY_RUN" -eq 1 ] && say "(dry run — nothing will be removed)"
  say ""

  # Disable before deleting. Removing a unit file while it is still enabled
  # leaves a dangling symlink in multi-user.target.wants, which systemd then
  # complains about on every boot.
  say "triggers:"
  disabled=0
  for f in "$REPO"/systemd/*.path "$REPO"/systemd/*.timer; do
    [ -e "$f" ] || continue
    unit_name="$(basename "$f")"
    if systemctl is-enabled --quiet "$unit_name" 2>/dev/null; then
      if [ "$DRY_RUN" -eq 1 ]; then
        say "  WOULD DISABLE  $unit_name"
      else
        systemctl disable --now "$unit_name" >/dev/null 2>&1 || true
        say "  disabled   $unit_name"
      fi
      disabled=$((disabled + 1))
    fi
  done
  [ "$disabled" -eq 0 ] && say "  none enabled"

  say "files:"
  removed=0
  abcde_removed=0
  while IFS= read -r target; do
    [ -e "$target" ] || { say "  absent     $target"; continue; }
    if [ "$DRY_RUN" -eq 1 ]; then
      say "  WOULD REMOVE  $target"
    else
      rm -f "$target"
      say "  removed    $target"
      [ "$target" = /etc/abcde.conf ] && abcde_removed=1
    fi
    removed=$((removed + 1))
  done < <(deployed_targets)

  if [ "$DRY_RUN" -eq 0 ]; then
    systemctl daemon-reload 2>/dev/null || true
    udevadm control --reload 2>/dev/null || true
    say ""
    say "reloaded systemd and udev"
  fi

  say ""
  say "LEFT ALONE, deliberately:"
  say "  $SRV — the library, the tree, beets' library.db and state.pickle"
  say "  /etc/default/lathe — your ntfy topic and Navidrome credentials"
  say "  the '$MUSIC_USER' user and group"

  # /etc/abcde.conf is the one deployed path this script did not invent: the
  # abcde package ships its own. Removing it leaves the package with no config
  # at all, which is worse than the state before lathe was installed.
  if [ "$abcde_removed" -eq 1 ]; then
    say ""
    warn "/etc/abcde.conf belonged to the 'abcde' package before lathe overwrote it."
    warn "To restore the package's own version:  sudo apt install --reinstall abcde"
  fi

  say ""
  if [ "$DRY_RUN" -eq 1 ]; then
    say "dry run complete — $removed file(s) would be removed."
  else
    say "removed $removed file(s). Re-running install.sh puts them all back."
  fi
  exit 0
fi

# ------------------------------------------------------------------- deploying

# Copy src to dest atomically, with mode and owner, and report whether it
# changed anything. The temp file is created in the destination directory so
# that the rename is a rename and not a cross-filesystem copy — the whole point.
install_file() {
  local src="$1" dest="$2" mode="$3" owner="$4"
  local destdir; destdir="$(dirname "$dest")"

  [ -f "$src" ] || die "missing source file: $src"

  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    say "  unchanged  $dest"
    return 1
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -e "$dest" ]; then say "  WOULD UPDATE  $dest"; else say "  WOULD CREATE  $dest"; fi
    CHANGED+=("$dest")
    return 0
  fi

  [ -d "$destdir" ] || { mkdir -p "$destdir"; say "  created dir  $destdir"; }

  local tmp; tmp="$(mktemp "$destdir/.lathe-install.XXXXXX")"
  TMPFILES+=("$tmp")
  cat "$src" >"$tmp"
  chmod "$mode" "$tmp"
  chown "$owner" "$tmp"
  mv -f "$tmp" "$dest"

  say "  deployed   $dest"
  CHANGED+=("$dest")
  return 0
}

say "lathe install — from $REPO"
[ "$DRY_RUN" -eq 1 ] && say "(dry run — nothing will be written)"
say ""

# The §4 tree. Created here rather than typed by hand in Phase 0 because the
# scripts deployed below depend on it — autorip.sh writes to staging/rips and
# logs/rips, inbox-import.sh reads inbox/ and writes quarantine/ — and because
# a hand-typed `staging/incomming` looks right in a terminal and silently
# breaks push-music.sh a week later. mkdir -p and chmod are idempotent, so a
# tree that already exists costs nothing.
say "$SRV tree:"
tree_made=0
for d in \
  "$SRV/music" \
  "$SRV/inbox" \
  "$SRV/quarantine" \
  "$SRV/staging/rips" \
  "$SRV/staging/fetched" \
  "$SRV/staging/incoming" \
  "$SRV/config/navidrome" \
  "$SRV/config/beets" \
  "$SRV/config/librariand" \
  "$SRV/logs/rips"
do
  if [ -d "$d" ]; then
    continue
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  WOULD CREATE  $d"
  else
    mkdir -p "$d"
    say "  created    $d"
  fi
  tree_made=$((tree_made + 1))
done
[ "$tree_made" -eq 0 ] && say "  unchanged  all §4 directories already present"

if [ "$DRY_RUN" -eq 0 ]; then
  # Non-recursive on purpose. A recursive chown would walk the entire library,
  # which is slow on a few hundred thousand files and pointless — beets already
  # owns what it writes.
  chown "$MUSIC_USER:$MUSIC_USER" "$SRV" "$SRV"/* "$SRV"/staging/* "$SRV"/config/* "$SRV"/logs/* 2>/dev/null || true
  chmod 0755 "$SRV"

  # setgid, so that a file arriving from a human upload is group-owned by
  # `music` and therefore movable and deletable by beets. Without it every
  # upload fails at IMPORT time rather than at copy time, which is a confusing
  # place to find out (§11 Phase 0). These are the two directories a human
  # writes into directly.
  chmod 2775 "$SRV/inbox" "$SRV/staging/incoming"
  say "  setgid     $SRV/inbox, $SRV/staging/incoming"
fi

say "scripts:"
install_file "$REPO/ingest/autorip.sh"      /usr/local/bin/autorip.sh      0755 root:root || true
install_file "$REPO/ingest/inbox-import.sh" /usr/local/bin/inbox-import.sh 0755 root:root || true

say "ripper config:"
install_file "$REPO/ingest/abcde.conf" /etc/abcde.conf 0644 root:root || true

# These two land on the library drive, in a directory that also holds beets'
# own library.db and state.pickle. Named files only — never sync or clear this
# directory. Losing state.pickle makes the next import re-walk everything;
# losing library.db is worse.
say "beets config ($BEETS_DIR):"
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$BEETS_DIR/plugins"
  chown "$MUSIC_USER:$MUSIC_USER" "$BEETS_DIR" "$BEETS_DIR/plugins"
  chmod 0755 "$BEETS_DIR" "$BEETS_DIR/plugins"
fi
install_file "$REPO/ingest/beets/config.yaml" "$BEETS_DIR/config.yaml" 0644 "$MUSIC_USER:$MUSIC_USER" || true
for plugin in "$REPO"/ingest/beets/plugins/*.py; do
  [ -e "$plugin" ] || continue
  install_file "$plugin" "$BEETS_DIR/plugins/$(basename "$plugin")" 0644 "$MUSIC_USER:$MUSIC_USER" || true
done

# .timer is globbed alongside .service and .path even though no timer exists
# yet, because lint (§6.6) and restic (§8) are both specced to ship one. A unit
# type missing from this glob is not an error anywhere — the file simply never
# reaches /etc/systemd/system, and a timer that was never deployed looks exactly
# like a timer that never fired.
say "systemd units:"
for unit in "$REPO"/systemd/*.service "$REPO"/systemd/*.path "$REPO"/systemd/*.timer; do
  [ -e "$unit" ] || continue
  unit_name="$(basename "$unit")"

  # .path and .timer units are triggers: they do nothing at all until enabled,
  # so the deploy enables them below. .service units are not enabled here —
  # autorip@.service is templated and started by udev, and inbox-import.service
  # is started by its path unit. Enabling either would be wrong.
  case "$unit_name" in
    *.path|*.timer) ACTIVATABLE+=("$unit_name") ;;
  esac

  if install_file "$unit" "/etc/systemd/system/$unit_name" 0644 root:root; then
    SYSTEMD_CHANGED=1
    CHANGED_UNITS+=("$unit_name")
  fi
done

say "udev rule:"
if install_file "$REPO/systemd/99-autorip.rules" /etc/udev/rules.d/99-autorip.rules 0644 root:root; then
  UDEV_CHANGED=1
fi

# Shared by autorip@.service and inbox-import.service. Holds a live ntfy topic
# and a Navidrome password, neither of which belongs in the repo. Created once
# with everything unset — both scripts treat empty as "skip that step quietly"
# and log to the journal instead — and never touched again.
say "notification config:"
if [ -e /etc/default/lathe ]; then
  say "  preserved  /etc/default/lathe (never overwritten)"
elif [ "$DRY_RUN" -eq 1 ]; then
  say "  WOULD CREATE  /etc/default/lathe (all settings unset)"
else
  mkdir -p /etc/default
  tmp="$(mktemp /etc/default/.lathe-install.XXXXXX)"
  TMPFILES+=("$tmp")
  cat >"$tmp" <<'EOF'
# Environment for autorip@.service and inbox-import.service.
#
# NOT in the lathe repo, and 0600, because both values below are live
# credentials. Everything here is optional: unset means the corresponding step
# is skipped and logged, never that an import or a rip fails.

# An ntfy topic URL is a capability — anyone holding it can push to your phone,
# so make it long and random. autorip.sh pushes rip FAILURES here;
# inbox-import.sh pushes the import summary (§6.4).
#
#   NTFY_URL=https://ntfy.sh/some-long-random-string
NTFY_URL=

# Poking Navidrome after an import drops the delay before a new album appears
# from up to ND_SCANSCHEDULE (6h) to seconds. Without it nothing breaks; the
# scheduled scan and the filesystem watcher still find everything.
#
# A Navidrome login. Subsonic token auth means the password is not sent over
# the wire, but it is stored here in plain text — which is what the 0600 and
# root ownership on this file are for.
#
#   NAVIDROME_URL=http://localhost:4533
#   NAVIDROME_USER=tom
#   NAVIDROME_PASS=
NAVIDROME_URL=
NAVIDROME_USER=
NAVIDROME_PASS=
EOF
  chmod 0600 "$tmp"
  chown root:root "$tmp"
  mv -f "$tmp" /etc/default/lathe
  say "  created    /etc/default/lathe (all unset — edit to enable pushes and rescans)"
fi

# -------------------------------------------------------------------- reloads

say ""
if [ "$DRY_RUN" -eq 1 ]; then
  say "dry run complete — ${#CHANGED[@]} file(s) would change."
  exit 0
fi

if [ "$SYSTEMD_CHANGED" -eq 1 ]; then
  say "reloading systemd"
  systemctl daemon-reload
fi

# Every trigger this repo ships gets enabled, and a changed one gets restarted
# so the new version takes effect now rather than at the next boot. Restarting
# a path unit only re-arms the watch — it does not start an import, and
# anything already sitting in the inbox still triggers on the next change.
for unit_name in "${ACTIVATABLE[@]:-}"; do
  [ -n "$unit_name" ] || continue
  if ! systemctl is-enabled --quiet "$unit_name" 2>/dev/null; then
    say "enabling $unit_name"
    systemctl enable --now "$unit_name"
  elif printf '%s\n' "${CHANGED_UNITS[@]:-}" | grep -qxF "$unit_name"; then
    systemctl restart "$unit_name"
    say "restarted $unit_name (its unit file changed)"
  fi
done

if [ "$UDEV_CHANGED" -eq 1 ]; then
  say "reloading udev"
  udevadm control --reload
  udevadm trigger --subsystem-match=block
fi

say ""
if [ "${#CHANGED[@]}" -eq 0 ]; then
  say "nothing changed — system already matches the repo."
else
  say "deployed ${#CHANGED[@]} file(s)."
fi
