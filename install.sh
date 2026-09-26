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
#   sudo ./install.sh --allow-dirty  deploy a checkout that has local changes
#
# Releases are git tags in 0.1.0 form. Upgrading is:
#
#   git fetch --tags && git checkout 0.2.0 && sudo ./install.sh
#
# and what is deployed is recorded in /etc/lathe-release — `cat` it. The
# version comes from the tag, so there is no version file to forget to bump.
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
#   /etc/lathe/secrets/   (aria2's RPC secret generated if absent; your
#                          WireGuard key only ever permission-tightened)
#
# Code is replaced. Data is not. Albums sitting in quarantine have no bearing
# on a deploy.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=0
FORCE=0
UNINSTALL=0
ALLOW_DIRTY=0
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY_RUN=1 ;;
    -f|--force)   FORCE=1 ;;
    -u|--uninstall) UNINSTALL=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    -h|--help)    sed -n '2,/^$/p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

MUSIC_USER="${MUSIC_USER:-music}"
SRV="${SRV:-/srv}"
LIBRARIAND_DIR="${LIBRARIAND_DIR:-/usr/local/lib/librariand}"
BEETS_VENV="${BEETS_VENV:-/usr/local/lib/beets}"
BEETS_DIR="${BEETS_DIR:-$SRV/config/beets}"
# Overridable for install-test.sh only; the defaults are the real paths.
LATHE_ENV="${LATHE_ENV:-/etc/default/lathe}"
LATHE_RELEASE="${LATHE_RELEASE:-/etc/lathe-release}"
LATHE_SECRETS="${LATHE_SECRETS:-/etc/lathe/secrets}"

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

# git, against the checkout this script lives in. `sudo ./install.sh` runs git
# as root in a repository owned by your user, and git since 2.35.2 refuses that
# outright ("detected dubious ownership") — which would make every version read
# as "unknown" and let the dirty check below pass silently. safe.directory on
# the command line is honoured for exactly this, and scopes the exemption to
# this one repository instead of setting it globally for root.
repo_git() { git -c safe.directory="$REPO" -C "$REPO" "$@"; }

HAVE_GIT=0
if command -v git >/dev/null 2>&1 && repo_git rev-parse --git-dir >/dev/null 2>&1; then
  HAVE_GIT=1
fi

# The deployed version comes from the release tag, not from a file you edit, so
# `git tag 0.1.0` is the whole of cutting a release. On a tag this reads
# "0.1.0". Between tags it is git describe's "0.1.0-3-gabc1234", which is still
# true and says plainly this is not a release; local changes append "-dirty".
# Only tags shaped like a release count, so any other tag cannot masquerade.
VERSION="unknown"
COMMIT="unknown"
if [ "$HAVE_GIT" -eq 1 ]; then
  VERSION="$(repo_git describe --tags --match '[0-9]*.[0-9]*.[0-9]*' --always --dirty 2>/dev/null || echo unknown)"
  COMMIT="$(repo_git rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi

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

# A checkout with local changes is a deployed copy being edited in place —
# §12's rule, one level up. It matters more than it looks, because several of
# the deploy steps below are globs: an untracked systemd/foo.service or
# librariand/foo.py made on the Pi would ship as though it were part of the
# release, and /etc/lathe-release would still claim a clean version. So
# refuse, name what is dirty, and let --allow-dirty override the rare
# deliberate case.
if [ "$HAVE_GIT" -eq 1 ] && [ "$ALLOW_DIRTY" -eq 0 ]; then
  dirty="$(repo_git status --porcelain 2>/dev/null || true)"
  if [ -n "$dirty" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "the checkout has local changes — a real run would refuse:"
      printf '%s\n' "$dirty" | sed 's/^/           /' >&2
    else
      die "the checkout at $REPO has local changes:
$(printf '%s\n' "$dirty" | sed 's/^/         /')
       Deploying would ship them as if they were part of $VERSION.
       Commit them, discard them, or re-run with --allow-dirty if this really
       is deliberate."
    fi
  fi
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
  printf '%s\n' /usr/local/bin/beets-check.sh
  printf '%s\n' /usr/local/bin/beet          # a symlink into $BEETS_VENV
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
  printf '%s\n' /etc/systemd/journald.conf.d/lathe.conf
  # After an uninstall nothing is deployed, so nothing should claim a version.
  printf '%s\n' "$LATHE_RELEASE"

  for f in "$REPO"/librariand/*.py; do
    case "$(basename "$f")" in
      *_test.py) continue ;;   # test-only, never deployed — same rule as the deploy loop
    esac
    printf '%s\n' "$LIBRARIAND_DIR/$(basename "$f")"
  done
  for sub_dir in templates static; do
    for f in "$REPO"/librariand/"$sub_dir"/*; do
      [ -f "$f" ] && printf '%s\n' "$LIBRARIAND_DIR/$sub_dir/$(basename "$f")"
    done
  done
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
  for f in "$REPO"/systemd/*.path "$REPO"/systemd/*.timer "$REPO"/systemd/*.service; do
    [ -e "$f" ] || continue
    grep -q '^\[Install\]' "$f" || continue
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
    # -L as well as -e: a symlink whose target has already gone (the beet link,
    # if the venv was removed by hand) fails -e but is still there to remove.
    [ -e "$target" ] || [ -L "$target" ] || { say "  absent     $target"; continue; }
    if [ "$DRY_RUN" -eq 1 ]; then
      say "  WOULD REMOVE  $target"
    else
      rm -f "$target"
      say "  removed    $target"
      [ "$target" = /etc/abcde.conf ] && abcde_removed=1
    fi
    removed=$((removed + 1))
  done < <(deployed_targets)

  # The venv is not in deployed_targets — it is built, not copied — so take
  # the whole directory rather than leaving a few hundred megabytes of
  # site-packages behind with nothing to run it.
  # Reported even when absent, for the same reason the file loop above reports
  # absent files: the output is the record of what an uninstall covers, and a
  # line that only appears when there is something to delete cannot be checked.
  if [ ! -d "$LIBRARIAND_DIR" ]; then
    say "  absent     $LIBRARIAND_DIR/"
  elif [ "$DRY_RUN" -eq 1 ]; then
    say "  WOULD REMOVE  $LIBRARIAND_DIR/ (including its venv)"
  else
    rm -rf "$LIBRARIAND_DIR"
    say "  removed    $LIBRARIAND_DIR/ (including its venv)"
  fi

  # beets' venv goes the same way. Nothing in /srv depends on it existing:
  # library.db and state.pickle live under /srv/config/beets and are untouched.
  if [ ! -d "$BEETS_VENV" ]; then
    say "  absent     $BEETS_VENV/"
  elif [ "$DRY_RUN" -eq 1 ]; then
    say "  WOULD REMOVE  $BEETS_VENV/ (the beets install)"
  else
    rm -rf "$BEETS_VENV"
    say "  removed    $BEETS_VENV/ (the beets install)"
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    systemctl daemon-reload 2>/dev/null || true
    udevadm control --reload 2>/dev/null || true
    say ""
    say "reloaded systemd and udev"
  fi

  say ""
  say "LEFT ALONE, deliberately:"
  say "  $SRV — the library, the tree, beets' library.db and state.pickle"
  say "  $LATHE_ENV — your ntfy topic, Navidrome login and librariand token"
  say "  the '$MUSIC_USER' user and group"
  say "  the apt packages it installed (ffmpeg, python3-venv) — shared, not lathe's to remove"

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

say "lathe install — $VERSION ($COMMIT) from $REPO"
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
  "$SRV/staging/torrents" \
  "$SRV/config/navidrome" \
  "$SRV/config/aria2" \
  "$SRV/config/gluetun" \
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
  # place to find out (§11 Phase 0). These are the directories a human, or a
  # tool run by one, writes into directly: uploads, and farfetchd's output
  # (docs/fetch-contract.md says what farfetchd has to do on its side).
  chmod 2775 "$SRV/inbox" "$SRV/staging/incoming" "$SRV/staging/fetched"
  say "  setgid     $SRV/inbox, $SRV/staging/incoming, $SRV/staging/fetched"
fi

# The system packages the deploy depends on. These used to be a line in the
# runbook, which left a hard dependency of every import to a manual step:
# without ffmpeg the replaygain plugin fails to load, and beets drops it and
# carries on. Installed here only if missing, so a routine redeploy neither
# touches apt nor needs the network.
#
#   ffmpeg       ReplayGain on every import (config.yaml: backend: ffmpeg)
#   python3-venv the beets and librariand venvs below
#
# git is not here, and cannot be: you need it to clone the repo this script is
# in. `apt-get install` only — never upgrade — so nothing else on the system
# moves. Uninstall leaves these alone; they are shared packages and removing
# ffmpeg could break something that is not lathe's.
#
# APT_PACKAGES is overridable for install-test.sh only.
read -r -a APT_PACKAGES <<<"${APT_PACKAGES:-ffmpeg python3-venv}"
say "system packages:"
if ! command -v dpkg-query >/dev/null 2>&1; then
  warn "dpkg-query not found — not a Debian system? Install by hand: ${APT_PACKAGES[*]}"
else
  missing_pkgs=()
  for pkg in "${APT_PACKAGES[@]}"; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
      say "  present    $pkg"
    else
      missing_pkgs+=("$pkg")
    fi
  done
  if [ "${#missing_pkgs[@]}" -gt 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      for pkg in "${missing_pkgs[@]}"; do say "  WOULD INSTALL  $pkg"; done
    else
      say "  installing ${missing_pkgs[*]} — this needs the network"
      # Lock::Timeout: unattended-upgrades holds the dpkg lock for minutes at a
      # time on a fresh Pi, and without it apt fails immediately instead of
      # waiting its turn.
      if apt-get -qq -o DPkg::Lock::Timeout=300 update >/dev/null 2>&1 \
         && DEBIAN_FRONTEND=noninteractive apt-get -qq -o DPkg::Lock::Timeout=300 \
              install -y --no-install-recommends "${missing_pkgs[@]}" >/dev/null 2>&1; then
        for pkg in "${missing_pkgs[@]}"; do say "  installed  $pkg"; done
      else
        # Not fatal, same as the venvs: the steps that need these report
        # their own failure below, and the next run retries.
        warn "could not install ${missing_pkgs[*]} with apt. The venvs and the"
        warn "beets check below will fail until this succeeds; the next run retries."
      fi
    fi
  fi
fi

say "scripts:"
install_file "$REPO/ingest/autorip.sh"      /usr/local/bin/autorip.sh      0755 root:root || true
install_file "$REPO/ingest/inbox-import.sh" /usr/local/bin/inbox-import.sh 0755 root:root || true
install_file "$REPO/ingest/beets-check.sh"  /usr/local/bin/beets-check.sh  0755 root:root || true

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

# beets itself, in a venv this script owns, pinned by ingest/beets/requirements.txt.
#
# Not a per-user `uv tool install`: that puts beet in one user's ~/.local/bin,
# which the importer — running as `music` with systemd's default PATH — would
# never find, and which Debian's private home directories would not let it
# enter anyway. /usr/local/bin is on every user's default PATH.
#
# Same rules as librariand's venv below: reinstalled whenever the requirements
# differ from the copy recorded after the last SUCCESSFUL install, never fatal,
# retried on the next run if the network fails.
say "beets ($BEETS_VENV):"
BEETS_REQ="$REPO/ingest/beets/requirements.txt"
BEETS_STAMP="$BEETS_VENV/.installed-requirements"
if [ -x "$BEETS_VENV/bin/beet" ] && [ -f "$BEETS_STAMP" ] && cmp -s "$BEETS_REQ" "$BEETS_STAMP"; then
  say "  unchanged  $BEETS_VENV"
elif [ "$DRY_RUN" -eq 1 ]; then
  if [ -x "$BEETS_VENV/bin/beet" ]; then
    say "  WOULD UPDATE  $BEETS_VENV (requirements.txt changed)"
  else
    say "  WOULD CREATE  $BEETS_VENV (downloads beets and its plugins)"
  fi
else
  say "  installing beets — this needs the network"
  if { [ -x "$BEETS_VENV/bin/python" ] || python3 -m venv "$BEETS_VENV" >/dev/null 2>&1; } \
     && "$BEETS_VENV/bin/pip" install --quiet --disable-pip-version-check -r "$BEETS_REQ" >/dev/null 2>&1; then
    cp "$BEETS_REQ" "$BEETS_STAMP"
    say "  ready      $BEETS_VENV"
  else
    warn "could not install beets into $BEETS_VENV. Nothing will import until"
    warn "this succeeds; the next run retries it. Usually the network — check the"
    warn "system packages step above too, since this needs python3-venv."
  fi
fi

# The name everything calls. A symlink rather than a copy, so the venv's own
# absolute shebang keeps working; created under a temp name and renamed, so
# there is no moment where `beet` does not exist.
BEET_LINK=/usr/local/bin/beet
if [ "$(readlink "$BEET_LINK" 2>/dev/null)" = "$BEETS_VENV/bin/beet" ]; then
  say "  unchanged  $BEET_LINK"
elif [ "$DRY_RUN" -eq 1 ]; then
  say "  WOULD CREATE  $BEET_LINK -> $BEETS_VENV/bin/beet"
else
  ln -sfn "$BEETS_VENV/bin/beet" "$BEET_LINK.lathe-install.$$"
  mv -Tf "$BEET_LINK.lathe-install.$$" "$BEET_LINK"
  say "  linked     $BEET_LINK -> $BEETS_VENV/bin/beet"
fi

# Prove it works, as the user that will actually run it. beets drops a plugin it
# cannot load and carries on with exit status 0, so an import can "succeed"
# with no Bandcamp source, no ReplayGain, or no MusicBrainz at all. See
# beets-check.sh. Not fatal to the deploy — everything else still went out —
# but the script exits non-zero at the end so it cannot scroll past unnoticed.
BEETS_BROKEN=0
if [ "$DRY_RUN" -eq 0 ]; then
  if check_out="$(runuser -u "$MUSIC_USER" -- /usr/local/bin/beets-check.sh \
                    "$BEET_LINK" "$BEETS_DIR/config.yaml" 2>&1)"; then
    say "  checked    $check_out"
  else
    BEETS_BROKEN=1
    warn "beets is NOT healthy as $MUSIC_USER:"
    printf '%s\n' "$check_out" | sed 's/^/           /' >&2
  fi
fi

# librariand is a directory of code rather than a single script, so it does not
# fit the copy table's one-file-one-destination shape. Same rules apply: every
# file is renamed into place, and nothing here is ever edited in situ.
say "librariand ($LIBRARIAND_DIR):"
librariand_changed=0
# Globbed, not listed. This was a hand-written list of six modules, and when
# inbox.py was added it was never added here — so librariand would have died on
# `import inbox` the first time it started on the Pi. Deriving the list from the
# directory, the same way deployed_targets() does, means a new module cannot be
# forgotten. The test file is the one .py that must never ship.
for f in "$REPO"/librariand/*.py; do
  rel="$(basename "$f")"
  case "$rel" in *_test.py) continue ;; esac
  if install_file "$f" "$LIBRARIAND_DIR/$rel" 0644 root:root; then
    librariand_changed=1
  fi
done
for sub_dir in templates static; do
  for f in "$REPO"/librariand/"$sub_dir"/*; do
    [ -f "$f" ] || continue
    if install_file "$f" "$LIBRARIAND_DIR/$sub_dir/$(basename "$f")" 0644 root:root; then
      librariand_changed=1
    fi
  done
done

# Its dependencies live in a venv beside it, installed from requirements.txt.
#
# This used to be built once and never touched again, which is the same class of
# bug as a module missing from the deploy: a release that adds or bumps a
# dependency would ship code importing something the venv does not have, and
# librariand would die on start. So the venv is brought up to date whenever
# requirements.txt differs from the copy recorded at the last SUCCESSFUL
# install — recorded only after pip finishes, so a failed install is retried on
# the next deploy rather than mistaken for done.
#
# The one step that touches the network, so never fatal: with no internet
# everything else still deploys, and librariand fails to start until a later
# run gets through.
REQ="$REPO/librariand/requirements.txt"
VENV="$LIBRARIAND_DIR/venv"
REQ_STAMP="$VENV/.installed-requirements"
if [ -x "$VENV/bin/python" ] && [ -f "$REQ_STAMP" ] && cmp -s "$REQ" "$REQ_STAMP"; then
  say "  unchanged  $VENV"
elif [ "$DRY_RUN" -eq 1 ]; then
  if [ -x "$VENV/bin/python" ]; then
    say "  WOULD UPDATE  $VENV (requirements.txt changed)"
  else
    say "  WOULD CREATE  $VENV (downloads librariand's dependencies)"
  fi
else
  say "  installing librariand's dependencies — this needs the network"
  if { [ -x "$VENV/bin/python" ] || python3 -m venv "$VENV" >/dev/null 2>&1; } \
     && "$VENV/bin/pip" install --quiet --disable-pip-version-check -r "$REQ" >/dev/null 2>&1; then
    cp "$REQ" "$REQ_STAMP"
    say "  ready      $VENV"
    librariand_changed=1
  else
    warn "could not install librariand's dependencies into $VENV."
    warn "Everything else deployed fine; librariand will not start until this"
    warn "succeeds, and the next run retries it. Usually the network — check the"
    warn "system packages step above too, since this needs python3-venv."
  fi
fi

# .timer is globbed alongside .service and .path even though no timer exists
# yet, because lint (§6.6) and restic (§8) are both specced to ship one. A unit
# type missing from this glob is not an error anywhere — the file simply never
# reaches /etc/systemd/system, and a timer that was never deployed looks exactly
# like a timer that never fired.
say "systemd units:"
for unit in "$REPO"/systemd/*.service "$REPO"/systemd/*.path "$REPO"/systemd/*.timer; do
  [ -e "$unit" ] || continue
  unit_name="$(basename "$unit")"

  # Enable exactly the units that declare themselves enableable. A unit with
  # no [Install] section cannot be enabled at all — systemctl refuses — and the
  # three that lack one are precisely the three that must not be: autorip@ is
  # templated and started by udev, inbox-import is started by its path unit.
  # Reading the file beats a list of extensions here, because librariand.service
  # IS a long-running service that must come up at boot, and an extension rule
  # would have silently left it deployed and disabled.
  if grep -q '^\[Install\]' "$unit"; then
    ACTIVATABLE+=("$unit_name")
  fi

  if install_file "$unit" "/etc/systemd/system/$unit_name" 0644 root:root; then
    SYSTEMD_CHANGED=1
    CHANGED_UNITS+=("$unit_name")
  fi
done

say "udev rule:"
if install_file "$REPO/systemd/99-autorip.rules" /etc/udev/rules.d/99-autorip.rules 0644 root:root; then
  UDEV_CHANGED=1
fi

# The journal cap. One of the few things still writing to the boot SD card
# once /srv holds the library and every database.
say "journald cap:"
JOURNALD_CHANGED=0
if install_file "$REPO/systemd/journald.conf.d/lathe.conf" \
     /etc/systemd/journald.conf.d/lathe.conf 0644 root:root; then
  JOURNALD_CHANGED=1
fi

# Settings shared by the ripper, the importer and librariand. Holds a live ntfy
# topic, a Navidrome password and librariand's token, none of which belong in
# the repo. Seeded from lathe.env.example once, with everything unset, and
# never overwritten.
#
# Never overwriting is right for credentials but means a release that adds a
# setting ships it to nobody. So on every deploy the template's settings are
# compared with yours and any you lack are named — the file itself is not
# touched. A setting present but commented out counts as present: you have
# seen it and chosen.
TEMPLATE="$REPO/lathe.env.example"
say "settings ($LATHE_ENV):"
if [ -e "$LATHE_ENV" ]; then
  say "  preserved  $LATHE_ENV (never overwritten)"
  if [ -r "$LATHE_ENV" ]; then
    missing_keys=()
    while IFS= read -r key; do
      grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$LATHE_ENV" || missing_keys+=("$key")
    done < <(sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$TEMPLATE")
    if [ "${#missing_keys[@]}" -gt 0 ]; then
      warn "$LATHE_ENV lacks setting(s) this release knows about:"
      for k in "${missing_keys[@]}"; do warn "    $k"; done
      warn "Add them by hand; lathe.env.example says what each one does."
      warn "Your file has not been changed."
    fi
    # librariand listens on every interface, the home LAN included — not just
    # the tailnet. With no token, anyone on your wifi can delete from
    # quarantine. Allowed, because it is your network, but never silently.
    if grep -qE '^[[:space:]]*LIBRARIAND_TOKEN=[[:space:]]*$' "$LATHE_ENV"; then
      warn "LIBRARIAND_TOKEN is empty: the dashboard is open to anyone who can"
      warn "reach port 8080, which includes your home LAN, not only the tailnet."
      warn "Set one with:  openssl rand -hex 24"
    fi
  else
    say "  (not readable as $(id -un), so new settings were not checked — run with sudo)"
  fi
elif [ "$DRY_RUN" -eq 1 ]; then
  say "  WOULD CREATE  $LATHE_ENV (from lathe.env.example, with a generated LIBRARIAND_TOKEN)"
else
  # Seeded with a random librariand token rather than none. librariand binds
  # every interface, so "unset" would mean the dashboard — which can delete —
  # is open to the home LAN from the first boot. Blank it by hand if you
  # really want it open; install.sh will keep saying so.
  mkdir -p "$(dirname "$LATHE_ENV")"
  tmp="$(mktemp "$(dirname "$LATHE_ENV")/.lathe-install.XXXXXX")"
  TMPFILES+=("$tmp")
  token="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  sed "s/^LIBRARIAND_TOKEN=$/LIBRARIAND_TOKEN=$token/" "$TEMPLATE" >"$tmp"
  chmod 0600 "$tmp"
  chown root:root "$tmp"
  mv -f "$tmp" "$LATHE_ENV"
  say "  created    $LATHE_ENV (librariand token generated; the rest unset)"
  say "             read the token with:  sudo grep LIBRARIAND_TOKEN $LATHE_ENV"
fi

# Torrent secrets, for the opt-in gluetun + aria2 pair in compose.
#
# Raw files rather than lines in $LATHE_ENV, because compose bind-mounts them
# into the containers — so `docker compose`, run as you, never has to read a
# root-only file. Two, with different readers:
#
#   aria2_rpc_secret       generated here, once. 0640 root:music — the aria2
#                          container and librariand both run as music.
#   wireguard_private_key  yours, from Proton (docs/torrents.md). 0600 root —
#                          only gluetun, as root, reads it. Never generated,
#                          never printed; this only says whether it is there.
#
# Neither is ever overwritten, so rotating one is: delete it, re-run.
say "torrent secrets ($LATHE_SECRETS):"
aria2_secret="$LATHE_SECRETS/aria2_rpc_secret"
wg_key="$LATHE_SECRETS/wireguard_private_key"
if [ "$DRY_RUN" -eq 1 ]; then
  [ -d "$LATHE_SECRETS" ] || say "  WOULD CREATE  $LATHE_SECRETS (0750 root:$MUSIC_USER)"
  [ -s "$aria2_secret" ] 2>/dev/null \
    || say "  WOULD CREATE  $aria2_secret (random, 0640 root:$MUSIC_USER)"
else
  mkdir -p "$LATHE_SECRETS"
  chown "root:$MUSIC_USER" "$LATHE_SECRETS"
  chmod 0750 "$LATHE_SECRETS"
  if [ -s "$aria2_secret" ]; then
    say "  unchanged  aria2 RPC secret"
  else
    tmp="$(mktemp "$LATHE_SECRETS/.lathe-install.XXXXXX")"
    TMPFILES+=("$tmp")
    head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$tmp"
    chmod 0640 "$tmp"
    chown "root:$MUSIC_USER" "$tmp"
    mv -f "$tmp" "$aria2_secret"
    say "  created    aria2 RPC secret"
  fi
  # Tighten a hand-made key file rather than trusting how it was created.
  if [ -s "$wg_key" ]; then
    chown root:root "$wg_key"
    chmod 0600 "$wg_key"
  fi
fi
if [ -s "$wg_key" ] 2>/dev/null; then
  say "  present    WireGuard key — start torrents with:"
  say "               docker compose -f compose/docker-compose.yml --profile torrents up -d"
else
  say "  absent     WireGuard key — torrents stay off until you add it (docs/torrents.md)"
fi

# What is deployed, written where it can be read without the checkout:
#
#   cat /etc/lathe-release
#
# librariand shows the same file on its overview. Written LAST, so it only ever
# names a version once everything above deployed; set -e means a failure
# earlier leaves the previous stamp in place, which is then still the truth.
# VERSION and COMMIT only — a redeploy of the same release reads as unchanged,
# and the file's mtime says when it was deployed.
say "release ($LATHE_RELEASE):"
release_tmp="$(mktemp)"
TMPFILES+=("$release_tmp")
printf 'VERSION=%s\nCOMMIT=%s\n' "$VERSION" "$COMMIT" >"$release_tmp"
install_file "$release_tmp" "$LATHE_RELEASE" 0644 root:root || true

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
# A code-only change leaves the unit file untouched, so the generic
# changed-unit restart below would not notice. Say so explicitly.
if [ "${librariand_changed:-0}" -eq 1 ] && [ "$DRY_RUN" -eq 0 ] \
   && systemctl is-active --quiet librariand.service 2>/dev/null; then
  CHANGED_UNITS+=("librariand.service")
fi

for unit_name in "${ACTIVATABLE[@]:-}"; do
  [ -n "$unit_name" ] || continue
  # Never fatal. A unit that fails to START is still enabled, and will come
  # up once what it needs arrives — librariand with no venv yet, on a first
  # deploy with no network, is the usual case. Under set -e a failure here
  # used to abort the deploy before udev and journald were reloaded.
  if ! systemctl is-enabled --quiet "$unit_name" 2>/dev/null; then
    say "enabling $unit_name"
    systemctl enable --now "$unit_name" \
      || warn "$unit_name is enabled but did not start — see: journalctl -u $unit_name"
  elif printf '%s\n' "${CHANGED_UNITS[@]:-}" | grep -qxF "$unit_name"; then
    if systemctl restart "$unit_name"; then
      say "restarted $unit_name (its unit file changed)"
    else
      warn "$unit_name did not restart — see: journalctl -u $unit_name"
    fi
  fi
done

# Reload only — no `udevadm trigger`. The rule acts on media-change events,
# which are all in the future, so there is nothing to replay. And trigger's
# default action IS "change": with an audio CD in the tray at deploy time,
# replaying it would start a rip.
if [ "$UDEV_CHANGED" -eq 1 ]; then
  say "reloading udev rules"
  udevadm control --reload
fi

# A restart applies the new cap and trims the journal down to it straight away.
# Safe on a live system: journald re-attaches to its sockets and nothing that
# is logging notices.
if [ "${JOURNALD_CHANGED:-0}" -eq 1 ]; then
  say "restarting systemd-journald"
  systemctl restart systemd-journald
fi

say ""
if [ "${#CHANGED[@]}" -eq 0 ]; then
  say "nothing changed — system already matches the repo."
else
  say "deployed ${#CHANGED[@]} file(s)."
fi

# Last, so it is the final thing on screen. The deploy itself went through;
# this is the one failure that would otherwise present as imports quietly
# matching less than they should.
if [ "${BEETS_BROKEN:-0}" -eq 1 ]; then
  say ""
  warn "deployed, but beets is not healthy — see above. Imports will run"
  warn "without the missing plugin(s) and say nothing. Fix before importing:"
  warn "  sudo -u $MUSIC_USER beets-check.sh"
  exit 1
fi
