#!/usr/bin/env python3
"""Health and stats — the two read-only views that answer "is it all right?".

Both are deliberately cheap. The library layout §6.3 enforces is
`<AlbumArtist>/<Album>/`, so counting albums and artists is two levels of
`iterdir()` rather than a walk of every file, and disk usage comes from
`statvfs` rather than summing file sizes. On a Pi with a few hundred thousand
files that difference is the whole reason this endpoint is usable.

Nothing here reads beets' `library.db`. It would be the obvious source for an
album count, but it is SQLite being written by a different process (beets,
under systemd, possibly mid-import), and a dashboard refresh is not worth the
lock contention. The filesystem is already the source of truth for this system
— §14 — and it answers the question well enough.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import time
from pathlib import Path

import fetched
import quarantine
import rips

MUSIC = Path(os.environ.get("MUSIC", "/srv/music"))
SRV = Path(os.environ.get("SRV", "/srv"))

# The library walk is cheap but not free, and the dashboard polls. One cached
# answer per minute is plenty — albums do not appear that fast.
_CACHE: dict = {"at": 0.0, "value": None}
CACHE_SECONDS = int(os.environ.get("STATS_CACHE_SECONDS", "60"))


LATHE_RELEASE = Path(os.environ.get("LATHE_RELEASE", "/etc/lathe-release"))


def release() -> dict:
    """What install.sh last deployed, from /etc/lathe-release.

    Read from the stamp rather than from git, on purpose: the checkout says what
    is checked OUT, which is not the same thing if someone checked out a new tag
    and never ran install.sh. The stamp is written only after a deploy finishes.
    """
    out = {"version": None, "commit": None, "deployed_at": None}
    try:
        text = LATHE_RELEASE.read_text(encoding="utf-8")
        out["deployed_at"] = LATHE_RELEASE.stat().st_mtime
    except OSError:
        return out
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep and key.strip() in ("VERSION", "COMMIT"):
            out[key.strip().lower()] = value.strip() or None
    return out


def _is_mountpoint(p: Path) -> bool:
    try:
        return p.is_mount()
    except OSError:
        return False


def health() -> dict:
    """Everything that would make you say "something is wrong"."""
    out: dict = {"release": release()}

    # /srv not being a mount point means the library drive did not come back
    # after a reboot, and `nofail` (§4) means the Pi booted happily anyway.
    # Everything would appear to work while writing to the boot media.
    out["srv_mounted"] = _is_mountpoint(SRV)

    try:
        usage = shutil.disk_usage(SRV)
        out["disk"] = {
            "total": usage.total,
            "used": usage.used,
            "free": usage.free,
            "percent_used": round(usage.used / usage.total * 100, 1) if usage.total else 0,
        }
    except OSError as exc:
        out["disk"] = {"error": str(exc)}

    # An optical drive that has vanished is worth seeing, since the udev rule
    # simply never fires and a rip that never starts looks like nothing at all.
    out["optical_drive"] = sorted(
        p.name for p in Path("/dev").glob("sr[0-9]")
    ) if Path("/dev").is_dir() else []

    out["ripping_now"] = rips.current()

    all_rips = rips.entries()
    last_ok = next((r for r in all_rips if r.status == "ok"), None)
    out["last_successful_rip"] = (
        {"disc_id": last_ok.disc_id, "at": last_ok.finished_at,
         "album": last_ok.album, "artist": last_ok.artist}
        if last_ok else None
    )
    out["rips_needing_attention"] = sum(1 for r in all_rips if r.needs_attention)

    out["pending"] = pending_counts()

    out["beets"] = shutil.which(os.environ.get("BEET_CMD", "beet")) is not None

    # The importer is the one unit whose absence is silent: with it disabled,
    # albums land in the inbox and simply stay there.
    out["inbox_watcher"] = _unit_active("inbox.path")

    return out


def pending_counts() -> dict:
    """The three numbers, counted the cheap way.

    Deliberately NOT quarantine.entries() / fetched.entries(): those read tags
    off every audio file and parse every sidecar, which is the right cost for a
    list view and badly the wrong cost for a number in a nav tab that renders on
    every page load. Counting directory entries is one syscall per item.

    A fetched directory without fetch.json is still being written and is not
    waiting for anyone, so it does not count — same rule the review list uses.
    """
    def count(d, require: str | None = None) -> int:
        if not d.is_dir():
            return 0
        n = 0
        try:
            for p in d.iterdir():
                if p.name.startswith("."):
                    continue
                if require and not (p / require).is_file():
                    continue
                n += 1
        except OSError:
            return 0
        return n

    return {
        "quarantine": count(quarantine.QUARANTINE),
        "fetched": count(fetched.FETCHED, require="fetch.json"),
        # Anything sitting in the inbox is either mid-settle or waiting for the
        # path unit. Persistently non-zero means the importer is not running.
        "inbox": count(quarantine.INBOX),
    }


def _unit_active(unit: str) -> bool | None:
    try:
        proc = subprocess.run(
            [os.environ.get("SYSTEMCTL", "systemctl"), "is-active", unit],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return proc.stdout.strip() == "active"


def _walk_library() -> dict:
    """Count albums and artists from the directory layout §6.3 enforces."""
    if not MUSIC.is_dir():
        return {"albums": 0, "artists": 0, "top_artists": [], "available": False}

    per_artist: dict[str, int] = {}
    albums = 0
    for artist_dir in MUSIC.iterdir():
        if not artist_dir.is_dir() or artist_dir.name.startswith("."):
            continue
        n = 0
        try:
            for album_dir in artist_dir.iterdir():
                if album_dir.is_dir() and not album_dir.name.startswith("."):
                    n += 1
        except OSError:
            continue
        if n:
            per_artist[artist_dir.name] = n
            albums += n

    top = sorted(per_artist.items(), key=lambda kv: (-kv[1], kv[0].lower()))[:10]
    return {
        "albums": albums,
        "artists": len(per_artist),
        "top_artists": [{"artist": a, "albums": n} for a, n in top],
        "available": True,
    }


def stats(force: bool = False) -> dict:
    now = time.time()
    if not force and _CACHE["value"] is not None and now - _CACHE["at"] < CACHE_SECONDS:
        return _CACHE["value"]

    out = _walk_library()

    # Rips per month, from the logs rather than from anything that tracks it.
    by_month: dict[str, int] = {}
    for r in rips.entries():
        if r.finished_at and len(r.finished_at) >= 7:
            by_month[r.finished_at[:7]] = by_month.get(r.finished_at[:7], 0) + 1
    out["rips_per_month"] = [
        {"month": m, "rips": n} for m, n in sorted(by_month.items(), reverse=True)[:12]
    ]
    out["rips_total"] = sum(by_month.values())
    out["generated_at"] = now

    _CACHE["at"] = now
    _CACHE["value"] = out
    return out
