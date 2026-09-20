#!/usr/bin/env python3
"""Rip history, and the one thing the ripper cannot tell you itself.

`autorip.sh` writes one JSON log per disc into /srv/logs/rips, named by
MusicBrainz disc ID. That log records **the rip and nothing after it**: the
ripper is a producer, it moves the album into /srv/inbox and stops, and beets
runs later in a different process (§6.2, §12). So a rip log saying `status:
"ok"` means the disc read cleanly, not that the album is in your library.

Resolving the rest is this module's job, and §10 specifies how: each log
carries `handoff_path`, the name the album was moved in under. Where that name
has ended up says what happened to it.

    still in /srv/inbox      -> not imported yet; the path unit will get to it
    now in /srv/quarantine   -> beets saw it and would not match it
    in neither               -> imported; beets moved it into /srv/music

That last one is an inference rather than a fact, and it is worth being honest
about which is which. Nothing writes "this rip was imported" anywhere, because
nothing is in a position to: the ripper has exited and beets does not know a
rip happened. The alternative would be a shared database between two things
that currently share only a directory, which §14 is explicit about not doing.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

from quarantine import INBOX, QUARANTINE, RIP_LOGS

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

    # Derived here, not recorded anywhere. See the module docstring.
    outcome: str = "unknown"         # imported | awaiting import | quarantined
                                     # | rip failed | unknown
    quarantine_entry: str | None = None
    readable: bool = True
    problem: str | None = None

    @property
    def needs_attention(self) -> bool:
        return self.status != "ok" or self.read_errors or self.outcome == "quarantined"


def _handoff_name(rip: Rip) -> str | None:
    if not rip.handoff_path:
        return None
    return Path(rip.handoff_path).name


def _resolve_outcome(rip: Rip) -> None:
    """Work out where the album ended up. See the module docstring."""
    if rip.status != "ok":
        rip.outcome = "rip failed"
        return

    name = _handoff_name(rip)
    if not name:
        # 'ok' with no hand-off path should not happen; autorip.sh only writes
        # 'ok' after the move succeeds. Say so rather than guessing.
        rip.outcome = "unknown"
        return

    if (INBOX / name).exists():
        rip.outcome = "awaiting import"
        return
    if (QUARANTINE / name).exists():
        rip.outcome = "quarantined"
        rip.quarantine_entry = name
        return
    rip.outcome = "imported"


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
    _resolve_outcome(rip)
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

    # The staging directory abcde is writing into, if we can spot it. Best
    # effort: it tells you something is happening, not how far along it is.
    working = None
    if RIPS_STAGING.is_dir():
        dirs = [d for d in RIPS_STAGING.iterdir() if d.is_dir()]
        if dirs:
            working = max(dirs, key=lambda d: d.stat().st_mtime).name

    return {"unit": unit, "device": device, "working_dir": working}


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
