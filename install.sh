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
#
# Why this exists at all: copying these by hand is fine exactly once, and a
# trap every time after. A hotfix applied straight to /etc/abcde.conf works,
# which is the problem — the repo silently stops describing the running system
# and the next deploy reverts the fix without saying anything (§12).
#
# What this script never touches:
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
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=1 ;;
    -f|--force)   FORCE=1 ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

MUSIC_USER="${MUSIC_USER:-music}"
BEETS_DIR="${BEETS_DIR:-/srv/config/beets}"

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

id -u "$MUSIC_USER" >/dev/null 2>&1 \
  || die "user '$MUSIC_USER' does not exist — run Phase 0 first (§11)"

[ -d /srv ] || die "/srv does not exist — run Phase 0 first (§11)"

# The atomic hand-off from staging into the inbox is only atomic while both are
# on one filesystem. Mount them separately and `mv` silently becomes
# copy-then-delete: the path unit fires partway through and beets imports a
# half-written album (§12). Nothing else checks this, and the failure is silent,
# so check it here on every deploy — it costs one stat and catches a remount.
if [ -d /srv/inbox ] && [ -d /srv/staging ]; then
  if [ "$(stat -c %d /srv/inbox)" != "$(stat -c %d /srv/staging)" ]; then
    warn "/srv/inbox and /srv/staging are on DIFFERENT filesystems."
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
