#!/usr/bin/env python3
"""Rip history — did the disc read, and if not, why.

`autorip.sh` writes one JSON log per disc into /srv/logs/rips, named by
MusicBrainz disc ID. That log records the rip and nothing after it: the ripper
is a producer, it moves the album into /srv/inbox and stops, and beets runs
later in a different process (§6.2, §12).

**This module reports only what the log records.** An earlier version also
derived where the album ended up, by checking whether `handoff_path` was still
sitting in the inbox or in quarantine. That is dropped, for two reasons:

  1. The interesting case was already better served elsewhere. An album beets
     would not match appears on the Quarantine page, with its rip log attached
     — that is the page with the actions on it, and duplicating the fact here
     just invited you to look in the wrong place.

  2. The rest of it was an inference from ABSENCE, and it degraded. "In
     neither, therefore imported" is true right up until you delete something
     from quarantine by hand, at which point a months-old rip log silently
     starts claiming an album reached the library. A log that changes its mind
     about the past is worse than one that says less.

So: a rip passed or it failed, and if it failed there is a reason. Read errors
are reported alongside because they are also a recorded fact about the disc,
and they mean "consider a re-rip" whether or not the rip itself succeeded.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from quarantine import RIP_LOGS

# Where abcde works before the hand-off. A directory here with no matching
# finished log is a rip that is either running or died without writing one.
RIPS_STAGING = Path(os.environ.get("RIPS", "/srv/staging/rips"))

# Overridable so the tests can stand in for systemd and the optical drive.
SYSTEMCTL = os.environ.get("SYSTEMCTL", "systemctl")
EJECT = os.environ.get("EJECT_CMD", "eject")

SUPPORTED_SCHEMAS = {1}


class RipError(RuntimeError):
    pass


@dataclass
class Rip:
    disc_id: str
    status: str                      # 'ok' | 'failed', straight from the log
    finished_at: str | None = None
    device: str | None = None
    detail: str | None = None
    handoff_path: str | None = None
    artist: str | None = None
    album: str | None = None
    track_count: int = 0
    read_errors: bool = False
    raw_log: str | None = None
    schema: int | None = None

    readable: bool = True
    problem: str | None = None

    @property
    def passed(self) -> bool:
        return self.status == "ok"

    @property
    def needs_attention(self) -> bool:
        """Failed, or read badly enough to be worth re-ripping."""
        return self.status != "ok" or self.read_errors


def _read_one(p: Path) -> Rip:
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return Rip(disc_id=p.stem, status="unknown", readable=False,
                   problem=f"{p.name} could not be read: {exc}")

    schema = data.get("schema")
    if schema not in SUPPORTED_SCHEMAS:
        return Rip(disc_id=data.get("disc_id") or p.stem, status="unknown",
                   schema=schema if isinstance(schema, int) else None,
                   readable=False,
                   problem=(f"{p.name} is schema {schema!r}; this librariand "
                            f"understands {sorted(SUPPORTED_SCHEMAS)}."))

    rip = Rip(
        disc_id=data.get("disc_id") or p.stem,
        status=data.get("status") or "unknown",
        finished_at=data.get("finished_at"),
        device=data.get("device"),
        detail=data.get("detail"),
        handoff_path=data.get("handoff_path"),
        artist=data.get("artist"),
        album=data.get("album"),
        track_count=int(data.get("track_count") or 0),
        read_errors=bool(data.get("read_errors")),
        raw_log=data.get("raw_log"),
        schema=schema,
    )
    return rip


def entries() -> list[Rip]:
    """Rip history, newest first."""
    if not RIP_LOGS.is_dir():
        return []
    out = [_read_one(p) for p in RIP_LOGS.glob("*.json")]
    out.sort(key=lambda r: (r.finished_at or ""), reverse=True)
    return out


def get(disc_id: str) -> Rip:
    for r in entries():
        if r.disc_id == disc_id:
            return r
    raise RipError(f"no such rip: {disc_id}")


def current() -> dict | None:
    """The rip in progress, if there is one.

    Deliberately shallow: whether a unit is running, and what it is working on.
    Real per-track progress means parsing abcde's output as it goes, and the
    drive is not attached yet — building that against a guess at the output
    format would be writing tests for fiction. §10's /events SSE stream is
    deferred for the same reason.
    """
    try:
        proc = subprocess.run(
            [SYSTEMCTL, "list-units", "autorip@*.service",
             "--state=active", "--no-legend", "--plain"],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None

    unit = ""
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line.startswith("autorip@"):
            unit = line.split()[0]
            break
    if not unit:
        return None

    device = unit[len("autorip@"):].removesuffix(".service")

    # The work directory abcde is writing into, if we can spot it. Best
    # effort: it tells you something is happening, not how far along it is.
    # autorip.sh works in $RIPS/.work/<disc id>.<pid>, so that is where to
    # look — the top of $RIPS only ever holds `.work` itself.
    working = disc_id = None
    work_root = RIPS_STAGING / ".work"
    if work_root.is_dir():
        dirs = [d for d in work_root.iterdir() if d.is_dir()]
        if dirs:
            working = max(dirs, key=lambda d: d.stat().st_mtime).name
            head, _, pid = working.rpartition(".")
            disc_id = head if head and pid.isdigit() else working

    return {"unit": unit, "device": device, "working_dir": working,
            "disc_id": disc_id}


def eject(device: str = "sr0") -> str:
    """Open the tray.

    autorip.sh already ejects on a successful hand-off — this is for the disc
    that failed, or the one you put in and changed your mind about. Refuses
    while a rip is running, because ejecting mid-read produces a corrupt album
    and a confusing log rather than an error.
    """
    if not device or "/" in device:
        raise RipError(f"invalid device: {device!r}")

    running = current()
    if running and running.get("device") == device:
        raise RipError(
            f"a rip is in progress on {device} — ejecting now would leave a "
            f"half-read album behind. Wait, or stop {running['unit']} first."
        )

    if shutil.which(EJECT) is None:
        raise RipError(f"{EJECT} is not installed (apt install eject)")

    try:
        proc = subprocess.run([EJECT, f"/dev/{device}"],
                              capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError) as exc:
        raise RipError(f"eject failed: {exc}") from None

    if proc.returncode != 0:
        raise RipError(f"eject failed: {proc.stderr.strip() or proc.returncode}")
    return f"ejected /dev/{device}"
