#!/usr/bin/env bash
# Deploy this repo onto the system paths.
#
# This is the ONLY way anything in this repo should reach a system path. The
# copy table is §11 of docs/plan.md, and it is reproduced in deploy() below
# rather than described, so the table and the deploy can never disagree.
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
#   /etc/default/autorip  (created if absent, never overwritten — it holds the
#                          ntfy topic, which is deliberately not in the repo)
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

say "systemd units:"
for unit in "$REPO"/systemd/*.service "$REPO"/systemd/*.path; do
  [ -e "$unit" ] || continue
  if install_file "$unit" "/etc/systemd/system/$(basename "$unit")" 0644 root:root; then
    SYSTEMD_CHANGED=1
  fi
done

say "udev rule:"
if install_file "$REPO/systemd/99-autorip.rules" /etc/udev/rules.d/99-autorip.rules 0644 root:root; then
  UDEV_CHANGED=1
fi

# Holds NTFY_URL, which is a live topic URL and deliberately not in the repo.
# Created once with the topic unset — autorip.sh treats empty as "don't notify"
# and logs failures to the journal instead — and never touched again.
say "notification config:"
if [ -e /etc/default/autorip ]; then
  say "  preserved  /etc/default/autorip (never overwritten)"
elif [ "$DRY_RUN" -eq 1 ]; then
  say "  WOULD CREATE  /etc/default/autorip (empty NTFY_URL)"
else
  mkdir -p /etc/default
  tmp="$(mktemp /etc/default/.lathe-install.XXXXXX)"
  TMPFILES+=("$tmp")
  cat >"$tmp" <<'EOF'
# Environment for autorip@.service. NOT in the lathe repo — it holds a live
# ntfy topic URL, which is a capability: anyone with it can push to your phone.
#
# Empty means autorip.sh pushes nothing and logs rip failures to the journal.
# Set it to a full topic URL to get a push when a rip fails:
#
#   NTFY_URL=https://ntfy.sh/some-long-random-string
NTFY_URL=
EOF
  chmod 0600 "$tmp"
  chown root:root "$tmp"
  mv -f "$tmp" /etc/default/autorip
  say "  created    /etc/default/autorip (NTFY_URL unset — edit to enable pushes)"
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
  # Restart the watcher so a changed unit takes effect now. Restarting a path
  # unit only re-arms the watch; it does not start an import, and anything
  # already in the inbox still triggers on the next change.
  if systemctl is-enabled --quiet inbox.path 2>/dev/null; then
    systemctl restart inbox.path
    say "restarted inbox.path"
  fi
fi

if ! systemctl is-enabled --quiet inbox.path 2>/dev/null; then
  say "enabling inbox.path (the inbox watcher)"
  systemctl enable --now inbox.path
fi

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
