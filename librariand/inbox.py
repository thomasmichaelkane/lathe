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
    age_seconds: float

    @property
    def stale(self) -> bool:
        return self.age_seconds > STALE_SECONDS


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

        out.append(Item(
            name=p.name, path=str(p), is_dir=p.is_dir(),
            audio_files=audio, bytes=total, mtime=st.st_mtime,
            age_seconds=max(0.0, now - st.st_mtime),
        ))

    out.sort(key=lambda i: i.mtime)
    return out
