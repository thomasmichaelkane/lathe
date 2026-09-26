#!/usr/bin/env python3
"""Torrents started from the dashboard, via an aria2 daemon.

Paste a magnet, watch it download, and move it to the inbox once it is done —
by hand, because a torrent's name is a claim about its contents and the move
is the point where it joins the import pipeline. The inbox takes it from
there exactly as it takes a rip.

**One directory per torrent, and the directory is the record.** Each download
gets `/srv/staging/torrents/<id>/`, holding a small `.librariand.json` (the
magnet, its name, when it was added) and whatever aria2 writes beside it.
aria2 is asked about progress, but it is not the source of truth for what
exists: it forgets finished downloads, and after a restart it re-reads its
session under new gids. So downloads are matched to aria2 by directory, never
by gid, and a directory aria2 knows nothing about is judged from disk — aria2
keeps a `<file>.aria2` control file beside anything unfinished and deletes it
on completion, so its absence is the "done" signal.

**No seeding.** Downloads are added with `seed-time=0`, so aria2 stops the
moment the data verifies (decided 2026-09-26; flip it here if that changes).

**Paths must agree.** aria2 is told where to write by absolute path. When it
runs in a container (behind the VPN), bind-mount the torrents directory at the
same path inside it, or the directories below will never fill.

The move into the inbox is a rename. /srv/staging and /srv/inbox are one
filesystem (§12), so the path unit sees the album appear whole; a copy would
be imported half-written. If the rename fails across devices, this refuses
rather than falling back to copying.
"""

from __future__ import annotations

import errno
import json
import os
import re
import secrets
import shutil
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

from quarantine import AUDIO_SUFFIXES, INBOX, _free_name

TORRENTS = Path(os.environ.get("TORRENTS", "/srv/staging/torrents"))
ARIA2_RPC = os.environ.get("ARIA2_RPC", "http://127.0.0.1:6800/jsonrpc")
ARIA2_SECRET = os.environ.get("ARIA2_SECRET", "")

RECORD = ".librariand.json"
ID_RE = re.compile(r"^\d{8}T\d{6}-[0-9a-f]{6}$")
# v1 info hashes: 40 hex, or 32 base32. Anything else is not a magnet aria2
# can do anything with, and is refused before it reaches the daemon.
BTIH_RE = re.compile(r"urn:btih:([0-9a-fA-F]{40}|[A-Za-z2-7]{32})\b")
ARCHIVE_SUFFIXES = {".zip", ".rar", ".7z", ".tar", ".gz", ".tgz"}

_KEYS = ["gid", "status", "dir", "totalLength", "completedLength",
         "downloadSpeed", "connections", "numSeeders", "followedBy",
         "errorMessage", "bittorrent"]


class TorrentError(RuntimeError):
    """Something asked for that cannot be done — shown to the operator."""


class BadId(TorrentError):
    """Not one of our directory names — a malformed request, not a conflict."""


# --- aria2 ----------------------------------------------------------------

def _call(method: str, *params):
    token = [f"token:{ARIA2_SECRET}"] if ARIA2_SECRET else []
    body = json.dumps({"jsonrpc": "2.0", "id": "librariand", "method": method,
                       "params": token + list(params)}).encode()
    req = urllib.request.Request(ARIA2_RPC, body,
                                 {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        # aria2 answers RPC errors (bad gid, bad secret) with a JSON body.
        try:
            data = json.loads(exc.read())
        except ValueError:
            raise TorrentError(f"aria2 answered HTTP {exc.code}") from None
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise TorrentError(f"aria2 is not reachable at {ARIA2_RPC} ({exc})") from None
    if "error" in data:
        raise TorrentError(f"aria2: {data['error'].get('message', data['error'])}")
    return data["result"]


def reachable() -> bool:
    try:
        _call("aria2.getVersion")
        return True
    except TorrentError:
        return False


def _rows_by_dir() -> dict[str, list[dict]]:
    rows = (_call("aria2.tellActive", _KEYS)
            + _call("aria2.tellWaiting", 0, 1000, _KEYS)
            + _call("aria2.tellStopped", 0, 1000, _KEYS))
    out: dict[str, list[dict]] = {}
    for r in rows:
        out.setdefault(os.path.realpath(r.get("dir", "")), []).append(r)
    return out


# --- records --------------------------------------------------------------

def _dir(tid: str) -> Path:
    if not ID_RE.match(tid or ""):
        raise BadId(f"not a torrent id: {tid!r}")
    return TORRENTS / tid


def _read_record(d: Path) -> dict:
    try:
        return json.loads((d / RECORD).read_text())
    except (OSError, ValueError):
        return {}


def _write_record(d: Path, record: dict) -> None:
    tmp = d / (RECORD + ".tmp")
    tmp.write_text(json.dumps(record, indent=2))
    os.replace(tmp, d / RECORD)


def _payload(d: Path) -> list[Path]:
    return [p for p in d.iterdir()
            if p.name not in (RECORD, RECORD + ".tmp")]


def _unfinished(d: Path) -> bool:
    return any(p.suffix == ".aria2" for p in d.rglob("*"))


def parse_magnet(magnet: str) -> tuple[str, str | None]:
    """(info hash, display name) — or TorrentError."""
    magnet = (magnet or "").strip()
    if not magnet.startswith("magnet:?"):
        raise TorrentError("that is not a magnet link — it should start with magnet:?")
    query = urllib.parse.parse_qs(magnet[len("magnet:?"):])
    m = next((BTIH_RE.search(xt) for xt in query.get("xt", [])
              if BTIH_RE.search(xt)), None)
    if not m:
        raise TorrentError("the magnet has no BitTorrent info hash (xt=urn:btih:…)")
    name = (query.get("dn") or [None])[0]
    return m.group(1).lower(), name


# --- what the dashboard shows ----------------------------------------------

@dataclass
class Torrent:
    id: str
    name: str
    state: str          # metadata|downloading|verifying|paused|complete|error|interrupted|unknown
    added_at: float
    progress: float = 0.0
    done_bytes: int = 0
    total_bytes: int = 0
    speed: int = 0
    peers: int = 0
    eta_seconds: int | None = None
    error: str | None = None
    audio_files: int = 0
    archives: list[str] = field(default_factory=list)

    @property
    def finished(self) -> bool:
        return self.state == "complete"

    @property
    def active(self) -> bool:
        return self.state in ("metadata", "downloading", "verifying")


def entries() -> tuple[list[Torrent], bool]:
    """Every torrent directory, newest first, and whether aria2 answered.

    With aria2 down the list still renders — from disk — so a finished
    download can be moved to the inbox even while the daemon is broken.
    """
    if not TORRENTS.is_dir():
        return [], reachable()
    try:
        by_dir = _rows_by_dir()
        online = True
    except TorrentError:
        by_dir, online = {}, False

    out = []
    for d in sorted(TORRENTS.iterdir(), reverse=True):
        if not d.is_dir() or not ID_RE.match(d.name):
            continue
        rec = _read_record(d)
        out.append(_status(d, rec, by_dir.get(os.path.realpath(d), []), online))
    return out, online


def _status(d: Path, rec: dict, rows: list[dict], online: bool) -> Torrent:
    t = Torrent(id=d.name, name=rec.get("name") or "Unnamed torrent",
                state="unknown", added_at=rec.get("added_at", d.stat().st_mtime))

    # A magnet is two downloads to aria2: the metadata, which is then
    # "followedBy" the real one. Show the real one once it exists.
    real = [r for r in rows if not r.get("followedBy")]
    row = next((r for r in real if r["status"] in ("active", "waiting", "paused")),
               real[0] if real else None)

    if row is not None:
        info = (row.get("bittorrent") or {}).get("info") or {}
        if info.get("name"):
            t.name = info["name"]
        t.total_bytes = int(row.get("totalLength") or 0)
        t.done_bytes = int(row.get("completedLength") or 0)
        t.speed = int(row.get("downloadSpeed") or 0)
        t.peers = int(row.get("connections") or 0)
        status = row["status"]
        if status == "active" and not info:
            t.state = "metadata"
        elif status == "active" and t.total_bytes and t.done_bytes >= t.total_bytes:
            t.state = "verifying"
        elif status in ("active", "waiting"):
            t.state = "downloading"
        elif status == "paused":
            t.state = "paused"
        elif status == "complete":
            t.state = "complete"
        elif status == "error":
            t.state, t.error = "error", row.get("errorMessage") or "aria2 reported an error"
        else:  # removed
            t.state = "interrupted"
    elif not online:
        t.state = "complete" if _payload(d) and not _unfinished(d) else "unknown"
    else:
        # aria2 has no memory of it: restarted without a session, or the
        # result was purged. The files say how far it got.
        t.state = "complete" if _payload(d) and not _unfinished(d) else "interrupted"

    if t.total_bytes:
        t.progress = round(100 * t.done_bytes / t.total_bytes, 1)
    if t.state == "complete":
        t.progress = 100.0
        files = [p for p in d.rglob("*") if p.is_file() and p.name != RECORD]
        t.audio_files = sum(p.suffix.lower() in AUDIO_SUFFIXES for p in files)
        t.archives = sorted(p.name for p in files
                            if p.suffix.lower() in ARCHIVE_SUFFIXES)
        if not t.total_bytes:
            t.total_bytes = t.done_bytes = sum(p.stat().st_size for p in files)
    if t.state == "downloading" and t.speed:
        t.eta_seconds = (t.total_bytes - t.done_bytes) // t.speed
    return t


def ready_count() -> int:
    """Finished and waiting to be moved, judged from disk alone — cheap enough
    for the nav badge on every page, and needs no answer from aria2."""
    if not TORRENTS.is_dir():
        return 0
    n = 0
    for d in TORRENTS.iterdir():
        if d.is_dir() and ID_RE.match(d.name) and _payload(d) and not _unfinished(d):
            n += 1
    return n


# --- actions --------------------------------------------------------------

def add(magnet: str) -> dict:
    """Start downloading a magnet. Adding one already here returns that one."""
    info_hash, name = parse_magnet(magnet)
    TORRENTS.mkdir(parents=True, exist_ok=True)
    for d in TORRENTS.iterdir():
        if d.is_dir() and _read_record(d).get("info_hash") == info_hash:
            return {"id": d.name, "detail": "already added"}

    tid = time.strftime("%Y%m%dT%H%M%S") + "-" + secrets.token_hex(3)
    d = TORRENTS / tid
    d.mkdir()
    record = {"id": tid, "magnet": magnet.strip(), "info_hash": info_hash,
              "name": name, "added_at": time.time()}
    _write_record(d, record)
    try:
        record["gid"] = _submit(d, record["magnet"])
    except TorrentError:
        shutil.rmtree(d, ignore_errors=True)
        raise
    _write_record(d, record)
    return {"id": tid, "detail": "added"}


def _submit(d: Path, magnet: str) -> str:
    return _call("aria2.addUri", [magnet], {
        "dir": str(d),
        "seed-time": "0",
        "bt-save-metadata": "false",
    })


def resume(tid: str) -> str:
    """Re-submit an interrupted or failed download into the same directory.

    aria2 picks up from its control file, so nothing already fetched is
    fetched again. A download aria2 still has in hand is left alone.
    """
    d = _dir(tid)
    if not d.is_dir():
        raise TorrentError("that download no longer exists")
    rec = _read_record(d)
    rows = _rows_by_dir().get(os.path.realpath(d), [])
    if any(r["status"] in ("active", "waiting", "paused") for r in rows):
        return "already downloading"
    for r in rows:
        _quietly("aria2.removeDownloadResult", r["gid"])
    rec["gid"] = _submit(d, rec["magnet"])
    _write_record(d, rec)
    return "resumed"


def move(tid: str) -> str:
    """Move a finished download into the inbox. Idempotent: once moved, the
    directory is gone and a second press reports that instead of failing."""
    d = _dir(tid)
    if not d.is_dir():
        return "already moved"
    t = _status(d, _read_record(d), _rows_or_empty(d), online=True)
    payload = _payload(d)
    if not payload:
        shutil.rmtree(d, ignore_errors=True)
        return "already moved"
    if t.state != "complete":
        raise TorrentError(f"not finished yet ({t.state}) — nothing moved")

    for r in _rows_or_empty(d):
        _quietly("aria2.removeDownloadResult", r["gid"])

    # A torrent is usually one folder; move that folder, named as the torrent
    # named it. Loose files move as the torrent's directory, under its name.
    if len(payload) == 1 and payload[0].is_dir():
        src, name = payload[0], payload[0].name
    else:
        src, name = d, _read_record(d).get("name") or t.name or d.name
        (d / RECORD).unlink(missing_ok=True)
    dest = _free_name(INBOX, name.replace("/", "_"))
    INBOX.mkdir(parents=True, exist_ok=True)
    try:
        os.rename(src, dest)
    except OSError as exc:
        if exc.errno == errno.EXDEV:
            raise TorrentError(
                f"{TORRENTS} and {INBOX} are on different filesystems, so the "
                f"move would be a copy the inbox could import half-written. "
                f"Nothing was moved.") from None
        raise
    shutil.rmtree(d, ignore_errors=True)
    return f"moved to the inbox as {dest.name}"


def cancel(tid: str) -> str:
    """Stop a download and delete what it fetched. Idempotent."""
    d = _dir(tid)
    if not d.is_dir():
        return "already gone"
    for r in _rows_or_empty(d):
        _quietly("aria2.forceRemove", r["gid"])
    # forceRemove is asynchronous; give aria2 a moment to close the files
    # before they are deleted from under it.
    time.sleep(0.5)
    for r in _rows_or_empty(d):
        _quietly("aria2.removeDownloadResult", r["gid"])
    shutil.rmtree(d, ignore_errors=True)
    return "cancelled and deleted"


def _rows_or_empty(d: Path) -> list[dict]:
    try:
        return _rows_by_dir().get(os.path.realpath(d), [])
    except TorrentError:
        return []


def _quietly(method: str, *params) -> None:
    try:
        _call(method, *params)
    except TorrentError:
        pass
