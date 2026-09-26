#!/usr/bin/env bash
# Is beets actually able to do its job? Exits 0 only if every plugin the config
# asks for loaded.
#
# Deployed to /usr/local/bin/beets-check.sh. install.sh runs it as `music` after
# every deploy, and the release workflow runs it on every PR and tag, so a
# broken beets install fails loudly rather than at 2am during an import.
#
#   sudo -u music beets-check.sh                # check the deployed install
#   beets-check.sh BEET CONFIG                  # check a specific pair
#
# Why this exists: beets does not fail when a plugin cannot load. It prints a
# traceback, drops the plugin, and carries on with exit status 0. Measured:
#
#   plugins: musicbrainz nosuchplugin fetchart   ->   plugins: fetchart, musicbrainz
#
# So a missing beetcamp silently disables the `bandcamp` source and every
# Bandcamp release quarantines; a missing ffmpeg silently disables replaygain;
# and a missing `musicbrainz` means every import matches nothing at all. None
# of those is an error anywhere. The only way to notice is to compare what the
# config asks for with what actually loaded, which is what this does.
#
# It never touches the real library. `beet version` opens the database and runs
# schema migrations, so the check points beets at a throwaway one.
#
# PLUGINPATH, if set, replaces the config's pluginpath — for CI, where the
# deployed /srv/config/beets/plugins does not exist and the repo's copy does.

set -euo pipefail

BEET="${1:-beet}"
CONFIG="${2:-/srv/config/beets/config.yaml}"

[ -r "$CONFIG" ] || { echo "beets-check: cannot read $CONFIG" >&2; exit 2; }
command -v "$BEET" >/dev/null 2>&1 || { echo "beets-check: $BEET not found on PATH" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# beets layers $BEETSDIR/config.yaml underneath the -c file, so pointing
# BEETSDIR at the config's own directory makes the real config the base and
# this overlay the only thing that differs from production.
{
  echo "directory: $WORK/music"
  echo "library: $WORK/library.db"
  echo "statefile: $WORK/state.pickle"
  if [ -n "${PLUGINPATH:-}" ]; then
    echo "pluginpath:"
    echo "  - $PLUGINPATH"
  fi
} >"$WORK/overlay.yaml"

if ! out="$(BEETSDIR="$(dirname "$CONFIG")" "$BEET" -c "$WORK/overlay.yaml" version 2>&1)"; then
  echo "beets-check: beet failed to run:" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

# `plugins: a b c` in the config; `plugins: a, b, c` from beet version.
wanted="$(sed -n 's/^plugins:[[:space:]]*//p' "$CONFIG" | head -1)"
loaded="$(printf '%s\n' "$out" | sed -n 's/^plugins:[[:space:]]*//p' | tr -d ',')"
version="$(printf '%s\n' "$out" | sed -n 's/^beets version //p')"

[ -n "$wanted" ] || { echo "beets-check: no plugins: line in $CONFIG" >&2; exit 2; }

missing=()
for p in $wanted; do
  case " $loaded " in *" $p "*) ;; *) missing+=("$p") ;; esac
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "beets-check: beets ${version:-?} is running WITHOUT: ${missing[*]}" >&2
  echo "beets-check: loaded only: ${loaded:-nothing}" >&2
  # Show why, without the migration chatter.
  printf '%s\n' "$out" | grep -vE '^(Created database backup|beets version|Python version|plugins:)' >&2 || true
  exit 1
fi

echo "beets ${version:-?}: all $(printf '%s\n' $wanted | wc -l | tr -d ' ') plugins loaded"
