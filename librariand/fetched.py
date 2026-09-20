#!/usr/bin/env python3
"""The review gate for fetched downloads — `/srv/staging/fetched` (§6.5).

This is the only entry point into the library with a human gate, because it is
the only one where something automated *chose* what to retrieve. A rip is
identified by its disc ID and an upload was picked by hand; a download
described as `VA - Album [FLAC]` is a claim, not a fact, and no amount of
tagging downstream turns the wrong release into the right one.

Two actions only, per docs/fetch-contract.md:

    approve  ->  move the directory into /srv/inbox, where the existing path
                 unit imports it like anything else. No second pipeline.
    reject   ->  delete it.

Everything here reads `fetch.json`, whose shape is the contract's business and
not this file's to redefine. Three rules from it are load-bearing:

  1. A directory WITHOUT fetch.json is in progress or failed. Ignore it
     entirely — the sidecar is written last and atomically, so its presence is
     the signal that the directory is complete.
  2. An UNKNOWN schema is refused rather than guessed at. Rendering a v3
     sidecar with v2 assumptions would show a plausible screen built on wrong
     field meanings, which is worse than showing nothing.
  3. The `release` block is what the SOURCE claimed, unverified. It is a label
     for the review screen, never metadata for the library. beets decides what
     the tags become, and disagreeing with this block is normal.
"""

from __future__ import annotations

import json
import os
import shutil
from dataclasses import dataclass, field
from pathlib import Path

# Imported rather than reimplemented. §10's rule about not duplicating the
# merge applies just as well to the smaller helpers: one definition of what
# counts as an audio file, one collision-avoidance rule for landing in the
# inbox. These live in quarantine.py because that is where they were needed
# first, not because they belong to it.
from quarantine import INBOX, _audio_paths, _free_name, _human  # noqa: F401

FETCHED = Path(os.environ.get("FETCHED", "/srv/staging/fetched"))

# Bump when this file learns a new sidecar version. Anything outside this set
# is surfaced to the operator as unreadable rather than rendered.
SUPPORTED_SCHEMAS = {2}


class FetchedError(RuntimeError):
    """Something the operator did, or asked for, that cannot be done."""


@dataclass
class Fetched:
    id: str
    path: str
    mtime: float
    bytes: int
    audio_files: int

    schema: int | None = None
    readable: bool = True          # False => unknown schema or broken sidecar
    problem: str | None = None     # why it is not readable

    source: dict = field(default_factory=dict)
    release: dict = field(default_factory=dict)
    checks: dict = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)

    # Derived from `checks`, so the review screen leads with what is wrong
    # rather than making you read four booleans and work it out.
    warnings: list[str] = field(default_factory=list)

    @property
    def clean(self) -> bool:
        return self.readable and not self.warnings


def _warnings_from_checks(checks: dict) -> list[str]:
    """Turn the producer's self-verification into things worth reading.

    `audio_verified` is the one that matters most: it means every file passed a
    decode test. A scraped error page saved as `.flac` is the classic failure
    and is otherwise invisible until the day you try to play it.
    """
    out: list[str] = []
    if checks.get("audio_verified") is False:
        out.append("audio did not verify — files may not be playable")
    if checks.get("mixed_formats"):
        out.append("mixed formats in one release")
    if checks.get("cover_present") is False:
        out.append("no cover art")
    zero = checks.get("zero_byte_files") or []
    if zero:
        n = len(zero)
        out.append(f"{n} zero-byte file{'s' if n != 1 else ''}: {', '.join(zero[:3])}")
    return out


def _read_one(d: Path) -> Fetched | None:
    sidecar = d / "fetch.json"
    if not sidecar.is_file():
        # In progress or failed. The contract makes fetch.json the completion
        # signal precisely so that no locking is needed on either side.
        return None

    audio = _audio_paths(d)
    total = 0
    for p in d.rglob("*"):
        if p.is_file():
            try:
                total += p.stat().st_size
            except OSError:
                pass

    base = Fetched(
        id=d.name,
        path=str(d),
        mtime=d.stat().st_mtime,
        bytes=total,
        audio_files=len(audio),
    )

    try:
        data = json.loads(sidecar.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        base.readable = False
        base.problem = f"fetch.json could not be read: {exc}"
        return base

    schema = data.get("schema")
    base.schema = schema if isinstance(schema, int) else None
    if base.schema not in SUPPORTED_SCHEMAS:
        base.readable = False
        base.problem = (
            f"fetch.json is schema {schema!r}; this librariand understands "
            f"{sorted(SUPPORTED_SCHEMAS)}. Refusing to guess at the fields."
        )
        return base

    base.source = data.get("source") or {}
    base.release = data.get("release") or {}
    base.checks = data.get("checks") or {}
    base.notes = list(data.get("notes") or [])
    base.warnings = _warnings_from_checks(base.checks)
    return base


def entries() -> list[Fetched]:
    """Everything awaiting review, newest first.

    Newest first because this is a queue you work down, and the thing you just
    fetched is the thing you are most likely to be looking for.
    """
    if not FETCHED.is_dir():
        return []
    out: list[Fetched] = []
    for d in sorted(FETCHED.iterdir()):
        if d.name.startswith(".") or not d.is_dir():
            continue
        one = _read_one(d)
        if one is not None:
            out.append(one)
    out.sort(key=lambda e: e.mtime, reverse=True)
    return out


def get(fetch_id: str) -> Fetched:
    for e in entries():
        if e.id == fetch_id:
            return e
    raise FetchedError(f"no such fetched entry: {fetch_id}")


def _resolve(fetch_id: str) -> Path:
    """Turn an id into a path, refusing anything that escapes FETCHED.

    The id reaches this module straight off an HTTP path segment, so it is
    untrusted input. A `..` here would reach the rest of /srv.
    """
    if not fetch_id or fetch_id.startswith(".") or "/" in fetch_id or "\\" in fetch_id:
        raise FetchedError(f"invalid entry name: {fetch_id!r}")
    d = FETCHED / fetch_id
    try:
        d.resolve().relative_to(FETCHED.resolve())
    except ValueError:
        raise FetchedError(f"entry is outside {FETCHED}: {fetch_id!r}") from None
    if not d.is_dir():
        raise FetchedError(f"no such fetched entry: {fetch_id}")
    return d


def approve(fetch_id: str, dry_run: bool = False) -> str:
    """Move a reviewed download into the inbox.

    The sidecar goes with it and is harmless there — beets ignores non-audio
    files, and leaving it means a quarantined release still carries the record
    of where it came from, which is exactly when you want to know.

    A rename, not a copy: /srv/staging and /srv/inbox are on one filesystem by
    §4's mount, so the directory appears in the inbox complete or not at all.
    The path unit fires on the first change and would otherwise import a
    half-copied album (§12).
    """
    d = _resolve(fetch_id)
    if not (d / "fetch.json").is_file():
        raise FetchedError(
            f"{fetch_id} has no fetch.json — it is still being written, or it failed"
        )

    dest = _free_name(INBOX, d.name)
    if dry_run:
        return f"would move {d} -> {dest}"
    INBOX.mkdir(parents=True, exist_ok=True)
    os.rename(d, dest)
    return f"approved {fetch_id} -> {dest}"


def reject(fetch_id: str, dry_run: bool = False) -> str:
    """Delete a download that fetched the wrong thing."""
    d = _resolve(fetch_id)
    if dry_run:
        return f"would delete {d}"
    shutil.rmtree(d)
    return f"rejected {fetch_id} (deleted)"
