#!/usr/bin/env python3
"""What is sitting in /srv/inbox right now.

The inbox is the one stage that is supposed to be empty. Everything converges
here — rips, uploads, approved downloads — and `inbox.path` fires on the first
change, so an item lands and is normally gone within a couple of minutes:
`inbox-import.sh` waits for the directory to settle, imports, and sweeps what
beets refused into quarantine.

So this view exists to answer one question: **is something stuck?** An item
that has been here for an hour means either the settle wait is being reset by
an upload still in flight, or the importer is not running at all — and the
second failure is completely silent, because a disabled path unit produces no
error anywhere. Albums simply arrive and stay.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path

from quarantine import INBOX, _audio_paths

# How long an item can sit before it is worth remarking on. Twice
# inbox-import.sh's default settle window, so a normal import never trips it.
STALE_SECONDS = 300


@dataclass
class Item:
    name: str
    path: str
    is_dir: bool
    audio_files: int
    bytes: int
    mtime: float
    age_seconds: float    # since it ARRIVED, not since its files were written

    @property
    def stale(self) -> bool:
        return self.age_seconds > STALE_SECONDS


NUDGE = ".librariand-nudge"


def nudge() -> None:
    """Start the importer now, by giving inbox.path a change to fire on.

    librariand runs as `music` and cannot `systemctl start` anything, but it
    can write to /srv, and inbox.path fires on any file created in the inbox.
    So: create a marker and delete it straight away.

    Idempotent without any bookkeeping here, because systemd supplies it:
    starting a oneshot unit that is already running is a no-op, so pressing
    this during an import changes nothing. The marker cannot disturb that
    import either — inbox-import.sh's settle check looks only below the inbox
    (`find -mindepth 1`), and the marker is gone long before the unit starts.
    """
    marker = INBOX / NUDGE
    marker.touch()
    marker.unlink(missing_ok=True)


def entries() -> list[Item]:
    """Everything in the inbox, oldest first — the stuck ones float to the top."""
    if not INBOX.is_dir():
        return []

    now = time.time()
    out: list[Item] = []
    for p in sorted(INBOX.iterdir()):
        if p.name.startswith("."):
            continue
        try:
            st = p.stat()
        except OSError:
            continue

        if p.is_dir():
            audio = len(_audio_paths(p))
            total = 0
            for f in p.rglob("*"):
                if f.is_file():
                    try:
                        total += f.stat().st_size
                    except OSError:
                        pass
        else:
            audio = len(_audio_paths(p))
            total = st.st_size

        # ctime, not mtime. Everything reaches the inbox by rename, and a
        # rename keeps the mtime the files had on the laptop — so an album
        # ripped in 2019 would read as having waited seven years the moment
        # it landed. The rename does update ctime, which is therefore when it
        # arrived.
        out.append(Item(
            name=p.name, path=str(p), is_dir=p.is_dir(),
            audio_files=audio, bytes=total, mtime=st.st_mtime,
            age_seconds=max(0.0, now - st.st_ctime),
        ))

    # Longest-waiting first, by the same clock.
    out.sort(key=lambda i: -i.age_seconds)
    return out
