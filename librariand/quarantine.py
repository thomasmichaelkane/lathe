#!/usr/bin/env python3
"""Review and resolve what beets refused to import.

`inbox-import.sh` sweeps anything beets could not confidently match into
/srv/quarantine (§6.5). This is the tool for working through that pile: see
what is there, understand why each thing failed, and act on it.

    quarantine.py list                 # what is in quarantine, and why
    quarantine.py show ENTRY           # per-track tags, rip log, disc ID
    quarantine.py groups               # entries that look like one multi-disc set
    quarantine.py merge A B [C ...]    # combine those discs, hand back to the inbox
    quarantine.py retry ENTRY...       # hand back to the inbox unchanged
    quarantine.py drop ENTRY...        # delete

The interesting command is `merge`. A multi-disc CD set is ripped one disc per
insertion, so each disc reaches the inbox as its own import task. Presented
alone against the full release a single disc is missing half the tracklist,
`max_rec: missing_tracks: low` caps the recommendation, `quiet_fallback: skip`
fires, and the disc quarantines — correctly, and no matter how good the match
otherwise is (§6.3a). `merge` is the repair: it restacks the discs into the
Album/CD1, Album/CD2 layout beets collapses into a single import task, and
moves that back into the inbox where the normal pipeline takes it from there.

This is a library as much as a CLI — librariand's /quarantine endpoints (§10)
import these functions rather than shelling out to them.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path

# Same override convention as inbox-import.sh and autorip.sh: the defaults are
# the real paths, and nothing in production sets these. The test harness points
# them at a temporary tree so it exercises this exact code.
QUARANTINE = Path(os.environ.get("QUARANTINE", "/srv/quarantine"))
INBOX = Path(os.environ.get("INBOX", "/srv/inbox"))
RIP_LOGS = Path(os.environ.get("RIP_LOGS", "/srv/logs/rips"))

AUDIO_SUFFIXES = {".flac", ".mp3", ".m4a", ".ogg", ".opus", ".wav", ".wv", ".ape"}

# MusicBrainz asks for a real contact in the User-Agent and allows one request
# per second. Both are conditions of use, not suggestions.
MB_UA = os.environ.get(
    "MB_USER_AGENT",
    "lathe-quarantine/1.0 (https://github.com/thomasmichaelkane/lathe)",
)
MB_RATE_SECONDS = 1.1

# Disc IDs autorip.sh invents when it cannot compute a real one. Neither is a
# MusicBrainz disc ID, so looking either up would just burn a request.
NON_MB_DISCID = ("freedb-", "unknown-")


# --- Reading what is there ------------------------------------------------

def _load_mediafile():
    """mediafile, if it is importable.

    It ships with beets, so on the Pi it is always present. Import it lazily
    anyway: without it every command here still works and only the tag-derived
    columns go blank, which is a much better failure than the whole tool being
    unusable on a machine where beets lives in its own virtualenv.
    """
    try:
        import mediafile
        return mediafile
    except ImportError:
        return None


_MEDIAFILE = _load_mediafile()

# Disc markers, for both directions: stripping one off a name to get the album
# title, and spotting that two names differ only by one. Deliberately a
# superset of what beets collapses on (§6.3) — beets needs the marker followed
# by a digit, but a human reviewing quarantine wants "(1 of 2)" and "Disc One"
# grouped too, precisely because those are the ones beets did not.
DISC_MARKER = re.compile(
    r"[\s._\-]*[\(\[\{]?\s*(?:"
    r"(?:dis[ck]|cd|disque|vol(?:ume)?)\s*\.?\s*"
    r"(\d+|one|two|three|four|five|six|seven|eight)"
    r"|(\d+)\s*(?:of|/|-)\s*(\d+)"
    r")\s*[\)\]\}]?\s*$",
    re.IGNORECASE,
)

WORD_NUMBERS = {"one": 1, "two": 2, "three": 3, "four": 4,
                "five": 5, "six": 6, "seven": 7, "eight": 8}


def strip_disc_marker(name: str) -> tuple[str, int | None, int | None]:
    """('Album (Disc 2)') -> ('Album', 2, None); ('Album (1 of 3)') -> ('Album', 1, 3)."""
    m = DISC_MARKER.search(name)
    if not m:
        return name, None, None
    base = name[: m.start()].strip(" .-_")
    single, pos, total = m.group(1), m.group(2), m.group(3)
    if single:
        n = WORD_NUMBERS.get(single.lower())
        if n is None:
            n = int(single)
        return base, n, None
    return base, int(pos), int(total)


@dataclass
class Tags:
    albumartist: str | None = None
    album: str | None = None
    disc: int | None = None
    # Every disc number present across the entry's files, sorted. A folder
    # holding a complete set carries more than one, and `disc` on its own
    # cannot tell that apart from a lone disc of a set — see read_tags.
    discs: list[int] = field(default_factory=list)
    disctotal: int | None = None
    tracktotal: int | None = None
    year: int | None = None
    mb_albumid: str | None = None
    tracks: list[int] = field(default_factory=list)


@dataclass
class Entry:
    name: str
    path: str
    is_dir: bool
    audio_files: int
    bytes: int
    mtime: float
    tags: Tags
    rip_log: dict | None = None
    notes: list[str] = field(default_factory=list)

    @property
    def disc_id(self) -> str | None:
        return (self.rip_log or {}).get("disc_id")

    def album_key(self) -> tuple[str, str]:
        """What two discs of one set should agree on, lowercased for matching."""
        album = self.tags.album or strip_disc_marker(self.name)[0]
        artist = self.tags.albumartist or ""
        return (artist.strip().lower(), album.strip().lower())


def _audio_paths(path: Path) -> list[Path]:
    if path.is_file():
        return [path] if path.suffix.lower() in AUDIO_SUFFIXES else []
    return sorted(p for p in path.rglob("*")
                  if p.is_file() and p.suffix.lower() in AUDIO_SUFFIXES)


def read_tags(audio: list[Path]) -> Tags:
    """Album-level tags, taken from the first file that carries each one.

    Track numbers are collected across every file because a gap or an overlap
    between two entries is the tell that they are two discs of one release
    rather than two rips of the same disc.

    Disc numbers are collected the same way, and for the same reason. Taking
    `disc` from the first file alone was wrong for the shape a download
    actually arrives in: a complete multi-disc set, flat in one folder, whose
    later files carry disc 2. The first file says disc 1 and `disctotal` says
    2, so the entry read as a lone half of a set — pointing the reader at a
    merge for a set that was already complete. Measured on a 30-track White
    Album download, 2026-09-20.
    """
    tags = Tags()
    if _MEDIAFILE is None:
        return tags
    discs: set[int] = set()
    for p in audio:
        try:
            mf = _MEDIAFILE.MediaFile(str(p))
        except Exception:
            continue
        if mf.track:
            tags.tracks.append(int(mf.track))
        if mf.disc:
            discs.add(int(mf.disc))
        for attr in ("albumartist", "album", "disc", "disctotal",
                     "tracktotal", "year", "mb_albumid"):
            if getattr(tags, attr) is None:
                v = getattr(mf, attr, None)
                # An untagged rip reports albumartist as '' rather than None.
                if v not in (None, ""):
                    setattr(tags, attr, v)
    tags.tracks.sort()
    tags.discs = sorted(discs)
    return tags


def _rip_logs() -> dict[str, dict]:
    """Rip logs keyed by the basename they handed off to the inbox.

    That basename is the only join between a disc and the quarantine entry it
    became: autorip.sh hands off as '<artist> - <album>' and inbox-import.sh
    keeps the name when it sweeps.
    """
    out: dict[str, dict] = {}
    if not RIP_LOGS.is_dir():
        return out
    for p in sorted(RIP_LOGS.glob("*.json")):
        try:
            log = json.loads(p.read_text())
        except (OSError, ValueError):
            continue
        handoff = log.get("handoff_path")
        if handoff:
            out.setdefault(os.path.basename(handoff), log)
    return out


def _match_rip_log(name: str, logs: dict[str, dict]) -> dict | None:
    if name in logs:
        return logs[name]
    # inbox-import.sh appends '.<timestamp>' and autorip.sh ' [<discid>]' when
    # a name is already taken — which is exactly what the second disc of a set
    # does, so this branch is the multi-disc case, not an edge case.
    for handoff, log in logs.items():
        if name.startswith(handoff + ".") or name.startswith(handoff + " ["):
            return log
    return None


def entries() -> list[Entry]:
    """Everything currently sitting in quarantine.

    Loose files count, not just directories — Bandcamp hands you a bare .flac
    for a single-track release, and inbox-import.sh sweeps those too.
    """
    if not QUARANTINE.is_dir():
        return []
    logs = _rip_logs()
    out: list[Entry] = []
    for p in sorted(QUARANTINE.iterdir()):
        if p.name.startswith("."):  # .merge-* work directories
            continue
        audio = _audio_paths(p)
        e = Entry(
            name=p.name,
            path=str(p),
            is_dir=p.is_dir(),
            audio_files=len(audio),
            bytes=sum(f.stat().st_size for f in audio),
            mtime=p.stat().st_mtime,
            tags=read_tags(audio),
            rip_log=_match_rip_log(p.name, logs),
        )
        _annotate(e)
        out.append(e)
    return out


def _annotate(e: Entry) -> None:
    """Cheap guesses at why beets refused this one.

    Hints, not diagnoses — the authoritative answer is in inbox-import.log.
    They exist so a pile of thirty quarantined albums can be triaged by eye.
    """
    t = e.tags
    if e.audio_files == 0:
        e.notes.append("no audio files")
    if not e.is_dir:
        e.notes.append("loose file — no album folder")
    if _MEDIAFILE is not None and e.audio_files and not t.album:
        e.notes.append("no ALBUM tag")
    if len(t.discs) > 1:
        # Every disc is already here, in one folder. There is nothing to merge
        # — beets collapses a folder like this into a single import task on its
        # own — so the repair is `retry`, not `merge`.
        if t.disctotal and set(t.discs) == set(range(1, t.disctotal + 1)):
            e.notes.append(f"complete {t.disctotal}-disc set in one folder "
                           "— retry, not merge")
        else:
            listed = ", ".join(str(d) for d in t.discs)
            e.notes.append(f"discs {listed} of {t.disctotal or '?'} "
                           "in one folder")
    elif t.disctotal and t.disctotal > 1:
        e.notes.append(f"disc {t.disc or '?'} of {t.disctotal} — needs merging")
    elif strip_disc_marker(e.name)[1] is not None:
        e.notes.append("name carries a disc marker — likely part of a set")
    if t.tracktotal and e.audio_files and e.audio_files < t.tracktotal:
        e.notes.append(f"{e.audio_files} of {t.tracktotal} tracks present")
    if e.rip_log and e.rip_log.get("read_errors"):
        e.notes.append("rip reported read errors — consider a re-rip")


# --- MusicBrainz disc ID lookup -------------------------------------------

def _cache_path() -> Path:
    return RIP_LOGS / ".discid-cache.json"


def _load_cache() -> dict:
    try:
        return json.loads(_cache_path().read_text())
    except (OSError, ValueError):
        return {}


def _save_cache(cache: dict) -> None:
    try:
        _cache_path().parent.mkdir(parents=True, exist_ok=True)
        _cache_path().write_text(json.dumps(cache, indent=2))
    except OSError:
        pass  # A cache that cannot be written is a slow tool, not a broken one.


_last_request = 0.0


def lookup_discid(disc_id: str | None, cache: dict | None = None) -> dict | None:
    """Ask MusicBrainz which release this disc belongs to, and which disc it is.

    The response carries the release MBID and its full medium list, so one
    lookup answers both 'which set is this' and 'how many discs am I waiting
    for'. Returns None for anything that is not a real MusicBrainz disc ID, for
    a lookup that finds nothing, and for any network failure — a tool for
    reviewing quarantine has to work on a Pi with no internet.
    """
    global _last_request
    if not disc_id or disc_id.startswith(NON_MB_DISCID):
        return None
    cache = _load_cache() if cache is None else cache
    if disc_id in cache:
        return cache[disc_id] or None

    url = ("https://musicbrainz.org/ws/2/discid/"
           + urllib.parse.quote(disc_id, safe="") + "?fmt=json")
    req = urllib.request.Request(url, headers={"User-Agent": MB_UA})
    wait = MB_RATE_SECONDS - (time.monotonic() - _last_request)
    if wait > 0:
        time.sleep(wait)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
    except (urllib.error.URLError, OSError, ValueError):
        return None  # Deliberately not cached: retry when the network is back.
    finally:
        _last_request = time.monotonic()

    result = None
    for release in data.get("releases", []):
        media = release.get("media", [])
        # Which medium is *this* disc: the one whose disc list contains the ID.
        position = next(
            (m.get("position") for m in media
             if any(d.get("id") == disc_id for d in m.get("discs", []))),
            None,
        )
        result = {
            "release_mbid": release.get("id"),
            "title": release.get("title"),
            "disc_count": len(media) or release.get("medium-count"),
            "position": position,
        }
        break
    cache[disc_id] = result
    _save_cache(cache)
    return result


# --- Grouping -------------------------------------------------------------

@dataclass
class Group:
    key: str
    confidence: str          # 'certain' | 'strong' | 'possible'
    reason: str
    members: list[str]       # entry names, in disc order
    expected_discs: int | None = None
    album: str | None = None
    mergeable: bool = True

    @property
    def complete(self) -> bool:
        return self.expected_discs is not None and len(self.members) >= self.expected_discs


def groups(online: bool = False) -> list[Group]:
    """Sets of quarantine entries that look like discs of one release.

    Three signals, strongest first, and an entry is only claimed once:

      certain  — rip logs whose disc IDs resolve to the same MusicBrainz
                 release. Needs --online, and is the only signal that also
                 knows how many discs the set is supposed to have.
      strong   — same album artist and album, with disc/disctotal tags that
                 agree it is a set.
      possible — same album with non-overlapping track numbers, or two names
                 differing only by a disc marker. Look before merging.
    """
    all_entries = entries()
    claimed: set[str] = set()
    out: list[Group] = []

    if online:
        cache = _load_cache()
        by_release: dict[str, list[tuple[int | None, Entry, dict]]] = {}
        for e in all_entries:
            info = lookup_discid(e.disc_id, cache)
            if info and info.get("release_mbid"):
                by_release.setdefault(info["release_mbid"], []).append(
                    (info.get("position"), e, info))
        for mbid, found in by_release.items():
            if len(found) < 2:
                continue
            found.sort(key=lambda m: (m[0] is None, m[0] or 0))
            info = found[0][2]
            out.append(Group(
                key=mbid,
                confidence="certain",
                reason=f"same MusicBrainz release ({mbid}) by disc ID",
                members=[m[1].name for m in found],
                expected_discs=info.get("disc_count"),
                album=info.get("title"),
            ))
            claimed.update(m[1].name for m in found)

    # Tag agreement.
    by_album: dict[tuple[str, str], list[Entry]] = {}
    for e in all_entries:
        if e.name in claimed or not e.tags.album:
            continue
        by_album.setdefault(e.album_key(), []).append(e)

    for key, members in by_album.items():
        if len(members) < 2:
            continue
        discs = [m.tags.disc for m in members]
        totals = {m.tags.disctotal for m in members if m.tags.disctotal}
        if all(d is not None for d in discs) and len(set(discs)) == len(discs):
            members.sort(key=lambda m: m.tags.disc or 0)
            confidence = "strong"
            reason = "matching album tags, distinct disc numbers"
        elif not all(m.tags.tracks for m in members):
            # No disc numbers and no track numbers is not evidence either way.
            # Say so rather than guessing: the two branches below both claim to
            # know something, and here nothing is known.
            confidence = "possible"
            reason = ("matching album tags, but no disc or track numbers to "
                      "tell a set from a duplicate — check the contents first")
        elif _tracks_disjoint(members):
            confidence = "possible"
            reason = "matching album tags, no overlapping track numbers"
        else:
            # Same album, overlapping tracks: two rips of the same disc, not a
            # set. Merging those would build a nonsense release, so report the
            # pair and refuse to suggest a merge for it.
            out.append(Group(
                key="dup:" + "|".join(key),
                confidence="possible",
                reason="matching album tags with OVERLAPPING track numbers — "
                       "likely duplicates, not a set",
                members=[m.name for m in members],
                album=members[0].tags.album,
                mergeable=False,
            ))
            claimed.update(m.name for m in members)
            continue
        out.append(Group(
            key="tags:" + "|".join(key),
            confidence=confidence,
            reason=reason,
            members=[m.name for m in members],
            expected_discs=max(totals) if totals else None,
            album=members[0].tags.album,
        ))
        claimed.update(m.name for m in members)

    # Name markers — the last resort, for files that never got as far as having
    # an album tag to compare.
    by_stripped: dict[str, list[tuple[int | None, Entry]]] = {}
    for e in all_entries:
        if e.name in claimed:
            continue
        base, pos, _total = strip_disc_marker(e.name)
        if pos is None:
            continue
        by_stripped.setdefault(base.lower(), []).append((pos, e))
    for base, found in by_stripped.items():
        if len(found) < 2:
            continue
        found.sort(key=lambda m: m[0] or 0)
        totals = {strip_disc_marker(m[1].name)[2] for m in found} - {None}
        out.append(Group(
            key="name:" + base,
            confidence="possible",
            reason="names differ only by a disc marker",
            members=[m[1].name for m in found],
            expected_discs=max(totals) if totals else None,
            album=strip_disc_marker(found[0][1].name)[0],
        ))
        claimed.update(m[1].name for m in found)

    order = {"certain": 0, "strong": 1, "possible": 2}
    out.sort(key=lambda g: (order[g.confidence], g.key))
    return out


def _tracks_disjoint(members: list[Entry]) -> bool:
    """True only if every member has track numbers and none of them collide."""
    if any(not m.tags.tracks for m in members):
        return False
    seen: set[int] = set()
    for m in members:
        if seen & set(m.tags.tracks):
            return False
        seen |= set(m.tags.tracks)
    return True


# --- Acting ---------------------------------------------------------------

class QuarantineError(RuntimeError):
    pass


def _resolve(name: str) -> Path:
    p = QUARANTINE / name
    if p.parent != QUARANTINE or not p.exists():
        raise QuarantineError(f"no such quarantine entry: {name}")
    return p


def _free_name(directory: Path, name: str) -> Path:
    """A destination that does not already exist.

    Same collision rule as inbox-import.sh: never clobber, suffix instead.
    """
    dest = directory / name
    if not dest.exists():
        return dest
    return directory / f"{name}.{time.strftime('%Y%m%d%H%M%S')}"


def merge(names: list[str], album: str | None = None, dry_run: bool = False) -> str:
    """Combine several quarantined discs into one release, back in the inbox.

    Builds <album>/CD1, <album>/CD2, ... — the layout beets collapses into a
    single import task (§6.3) — and moves the finished tree into the inbox with
    one rename, because inbox.path fires on the first change and the album has
    to appear complete or not at all.

    The order of `names` is the disc order. Nothing here rewrites tags: beets
    re-reads the whole set against MusicBrainz on import and writes disc
    numbers itself, so a merge that guessed them would only be a second, worse
    source of truth for the same field.

    The work directory lives inside quarantine so every move is a rename within
    one filesystem, and so an interrupted merge leaves the discs recoverable
    under .merge-* rather than half-copied into the inbox.
    """
    if len(names) < 2:
        raise QuarantineError("merge needs at least two entries")
    if len(set(names)) != len(names):
        raise QuarantineError("the same entry was listed twice")
    sources = [_resolve(n) for n in names]
    for s in sources:
        if not s.is_dir():
            raise QuarantineError(f"{s.name} is a loose file, not a disc directory")

    if album is None:
        wanted = set(names)
        albums = {e.tags.album for e in entries()
                  if e.name in wanted and e.tags.album}
        album = albums.pop() if len(albums) == 1 else strip_disc_marker(names[0])[0]
    album = album.strip().replace("/", "_")
    if not album:
        raise QuarantineError("could not work out an album name — pass --as")

    dest = _free_name(INBOX, album)
    if dry_run:
        plan = "\n".join(f"  {n}  ->  {dest.name}/CD{i}"
                         for i, n in enumerate(names, 1))
        return f"would create {dest}\n{plan}"

    work = QUARANTINE / f".merge-{os.getpid()}"
    staged = work / album
    staged.mkdir(parents=True, exist_ok=False)
    done: list[tuple[Path, Path]] = []
    try:
        for i, src in enumerate(sources, 1):
            target = staged / f"CD{i}"
            src.rename(target)
            done.append((src, target))
        INBOX.mkdir(parents=True, exist_ok=True)
        staged.rename(dest)
    except OSError:
        # Put every disc back exactly where it was. Losing the only copy of a
        # rip to a failed merge is the one outcome this tool must never have.
        for src, target in reversed(done):
            if target.exists() and not src.exists():
                target.rename(src)
        raise
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return f"merged {len(names)} discs into {dest}"


def retry(names: list[str], dry_run: bool = False) -> str:
    """Hand entries back to the inbox unchanged, for another import attempt.

    Worth doing after fixing tags by hand, or when the failure was MusicBrainz
    being unreachable rather than anything about the album itself.
    """
    moved = []
    for name in names:
        src = _resolve(name)
        dest = _free_name(INBOX, name)
        if dry_run:
            moved.append(f"would move {src} -> {dest}")
            continue
        INBOX.mkdir(parents=True, exist_ok=True)
        src.rename(dest)
        moved.append(f"{name} -> {dest}")
    return "\n".join(moved)


def drop(names: list[str], yes: bool = False) -> str:
    if not yes:
        raise QuarantineError("refusing to delete without --yes")
    targets = [_resolve(n) for n in names]
    for p in targets:
        if p.is_dir():
            shutil.rmtree(p)
        else:
            p.unlink()
    return f"deleted {len(targets)} entries"


# --- CLI ------------------------------------------------------------------

def _human(n: float) -> str:
    for unit in ("B", "K", "M", "G"):
        if n < 1024 or unit == "G":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}G"


def _cmd_list(args) -> int:
    es = entries()
    if args.json:
        print(json.dumps([asdict(e) for e in es], indent=2, default=str))
        return 0
    if not es:
        print(f"quarantine is empty ({QUARANTINE})")
        return 0
    width = max(len(e.name) for e in es)
    print(f"{'ENTRY'.ljust(width)}  TRACKS   SIZE  WHY")
    for e in es:
        print(f"{e.name.ljust(width)}  {e.audio_files:>6}  {_human(e.bytes):>5}  "
              f"{'; '.join(e.notes) or '-'}")
    print(f"\n{len(es)} entries in {QUARANTINE}")
    return 0


def _cmd_show(args) -> int:
    e = next((x for x in entries() if x.name == args.entry), None)
    if e is None:
        print(f"error: no such quarantine entry: {args.entry}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(asdict(e), indent=2, default=str))
        return 0
    print(f"{e.name}\n{'-' * len(e.name)}")
    print(f"path        {e.path}")
    print(f"audio       {e.audio_files} files, {_human(e.bytes)}")
    t = e.tags
    print(f"albumartist {t.albumartist or '-'}")
    print(f"album       {t.album or '-'}")
    shown = ", ".join(str(d) for d in t.discs) if t.discs else (t.disc or "-")
    print(f"disc        {shown} of {t.disctotal or '-'}")
    print(f"tracks      {t.tracks or '-'} (of {t.tracktotal or '?'})")
    print(f"mb_albumid  {t.mb_albumid or '-'}")
    if e.rip_log:
        print(f"disc id     {e.disc_id}")
        print(f"rip status  {e.rip_log.get('status')} "
              f"({e.rip_log.get('read_errors')} read errors)")
        if args.online:
            info = lookup_discid(e.disc_id)
            print(f"musicbrainz {info if info else 'no match'}")
    if e.notes:
        print("notes       " + "\n            ".join(e.notes))
    return 0


def _cmd_groups(args) -> int:
    gs = groups(online=args.online)
    if args.json:
        print(json.dumps([asdict(g) for g in gs], indent=2))
        return 0
    if not gs:
        print("no multi-disc candidates found"
              + ("" if args.online else " (try --online for disc ID lookup)"))
        return 0
    for g in gs:
        have = len(g.members)
        of = f" of {g.expected_discs}" if g.expected_discs else ""
        state = ("complete" if g.complete
                 else "INCOMPLETE" if g.expected_discs else "set size unknown")
        print(f"[{g.confidence}] {g.album or g.key}  —  {have}{of} discs, {state}")
        print(f"    {g.reason}")
        for i, m in enumerate(g.members, 1):
            print(f"    CD{i}  {m}")
        if g.mergeable:
            quoted = " ".join(f'"{m}"' for m in g.members)
            print(f"    merge: quarantine.py merge {quoted}")
        print()
    return 0


def _cmd_merge(args) -> int:
    print(merge(args.entries, album=args.album, dry_run=args.dry_run))
    return 0


def _cmd_retry(args) -> int:
    print(retry(args.entries, dry_run=args.dry_run))
    return 0


def _cmd_drop(args) -> int:
    print(drop(args.entries, yes=args.yes))
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        prog="quarantine.py",
        description=__doc__.split("\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=f"paths: QUARANTINE={QUARANTINE} INBOX={INBOX} RIP_LOGS={RIP_LOGS}",
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    lst = sub.add_parser("list", help="what is in quarantine, and why")
    lst.add_argument("--json", action="store_true")
    lst.set_defaults(func=_cmd_list)

    show = sub.add_parser("show", help="everything known about one entry")
    show.add_argument("entry")
    show.add_argument("--json", action="store_true")
    show.add_argument("--online", action="store_true",
                      help="look the disc ID up at MusicBrainz")
    show.set_defaults(func=_cmd_show)

    grp = sub.add_parser("groups", help="entries that look like one multi-disc set")
    grp.add_argument("--json", action="store_true")
    grp.add_argument("--online", action="store_true",
                     help="look disc IDs up at MusicBrainz "
                          "(slow — one request per second)")
    grp.set_defaults(func=_cmd_groups)

    mrg = sub.add_parser("merge",
                         help="combine discs into one release, back in the inbox")
    mrg.add_argument("entries", nargs="+", help="entry names, in disc order")
    mrg.add_argument("--as", dest="album", help="album name for the merged folder")
    mrg.add_argument("--dry-run", action="store_true")
    mrg.set_defaults(func=_cmd_merge)

    rty = sub.add_parser("retry", help="move back to the inbox unchanged")
    rty.add_argument("entries", nargs="+")
    rty.add_argument("--dry-run", action="store_true")
    rty.set_defaults(func=_cmd_retry)

    drp = sub.add_parser("drop", help="delete entries")
    drp.add_argument("entries", nargs="+")
    drp.add_argument("--yes", action="store_true",
                     help="required — this deletes files")
    drp.set_defaults(func=_cmd_drop)

    args = p.parse_args(argv)
    try:
        return args.func(args)
    except QuarantineError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
