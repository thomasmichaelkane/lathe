#!/usr/bin/env python3
"""Split single-file CD images into tracks before beets sees them.

Deployed to /usr/local/bin/cuesplit.py. inbox-import.sh runs it on each
inbox item before the beets passes (#59).

Many lossless downloads are a CD IMAGE: the whole disc in one audio file
(`CDImage.ape`, `Album.flac`) plus a `.cue` sheet saying where each track
starts. beets has no cue splitting in this pipeline, so it saw one
45-minute "track", matched nothing, and the album quarantined — and even
accepted by hand it would be one giant track in Navidrome.

    cuesplit.py ITEM          # split every image directory under ITEM

A directory is split only when it is unambiguously an image: exactly ONE
audio file, and exactly one .cue in it listing more than one track against a
single FILE. Anything else is left alone — a per-track rip that happens to
ship a cue, a cue for a file that is not there, a one-track cue.

Tracks are written as FLAC (the archive format; #58 converts the rest of the
lossless formats the same way), tagged from the cue, into a temporary
directory first. Only when every track has been written does the image go
and the tracks move in, so a failure leaves the directory exactly as it was
and the album quarantines as it always would have.

Standard library and ffmpeg only: it runs with the system python3 as the
`music` user, like the rest of the ingest scripts.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

AUDIO_SUFFIXES = {".flac", ".ape", ".wv", ".wav", ".aiff", ".aif"}
FFMPEG = os.environ.get("FFMPEG", "ffmpeg")


@dataclass
class Track:
    number: int
    start: float                       # seconds, from INDEX 01
    title: str | None = None
    performer: str | None = None


@dataclass
class Cue:
    files: list[str] = field(default_factory=list)
    title: str | None = None
    performer: str | None = None
    date: str | None = None
    genre: str | None = None
    disc: str | None = None
    tracks: list[Track] = field(default_factory=list)


def _read_text(path: Path) -> str:
    # Cue sheets come from Windows rippers as often as not: UTF-8 (with or
    # without a BOM) first, then cp1252, which never fails to decode.
    raw = path.read_bytes()
    for enc in ("utf-8-sig", "cp1252"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("latin-1")


def _unquote(s: str) -> str:
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] == '"':
        return s[1:-1]
    return s


_TIME = re.compile(r"^(\d+):(\d{1,2}):(\d{1,2})$")


def _seconds(stamp: str) -> float:
    # mm:ss:ff, where ff is 1/75 s (CD frames) and mm may exceed 59.
    m = _TIME.match(stamp.strip())
    if not m:
        raise ValueError(f"bad cue time: {stamp!r}")
    mm, ss, ff = (int(x) for x in m.groups())
    return mm * 60 + ss + ff / 75


def parse(path: Path) -> Cue:
    cue = Cue()
    track: Track | None = None
    for line in _read_text(path).splitlines():
        parts = line.strip().split(None, 1)
        if not parts:
            continue
        key, rest = parts[0].upper(), (parts[1] if len(parts) > 1 else "")
        if key == "FILE":
            # FILE "name" WAVE — the type is the last word, the name the rest.
            name = rest.rsplit(None, 1)[0] if " " in rest else rest
            cue.files.append(_unquote(name))
        elif key == "TRACK":
            num = rest.split()[0]
            track = Track(number=int(num), start=-1.0)
            cue.tracks.append(track)
        elif key == "INDEX" and track is not None:
            idx, stamp = rest.split(None, 1)
            if int(idx) == 1:
                track.start = _seconds(stamp)
        elif key == "TITLE":
            if track is None:
                cue.title = _unquote(rest)
            else:
                track.title = _unquote(rest)
        elif key == "PERFORMER":
            if track is None:
                cue.performer = _unquote(rest)
            else:
                track.performer = _unquote(rest)
        elif key == "REM" and track is None:
            sub = rest.split(None, 1)
            if len(sub) == 2:
                what, val = sub[0].upper(), _unquote(sub[1])
                if what == "DATE":
                    cue.date = val
                elif what == "GENRE":
                    cue.genre = val
                elif what == "DISCNUMBER":
                    cue.disc = val
    return cue


def _safe(name: str) -> str:
    name = re.sub(r'[/\\\0<>:"|?*]', "_", name).strip().strip(".")
    return name[:120] or "Track"


def find_images(item: Path) -> list[tuple[Path, Path, Cue]]:
    """Every (directory's audio image, its cue, parsed) under ITEM."""
    out = []
    dirs = [item] if item.is_dir() else []
    if item.is_dir():
        dirs += [d for d in item.rglob("*") if d.is_dir()]
    for d in dirs:
        audio = [p for p in d.iterdir()
                 if p.is_file() and p.suffix.lower() in AUDIO_SUFFIXES]
        cues = [p for p in d.iterdir() if p.is_file() and p.suffix.lower() == ".cue"]
        if len(audio) != 1 or len(cues) != 1:
            continue
        try:
            cue = parse(cues[0])
        except (OSError, ValueError):
            continue
        if len(cue.files) != 1 or len(cue.tracks) < 2:
            continue
        if any(t.start < 0 for t in cue.tracks):
            continue
        starts = [t.start for t in cue.tracks]
        if starts != sorted(starts) or len(set(starts)) != len(starts):
            continue
        # The cue often names a file that was re-encoded after ripping
        # (`CDImage.wav` beside a `CDImage.ape`). With exactly one audio file
        # in the directory there is no ambiguity about which it means.
        out.append((audio[0], cues[0], cue))
    return out


def split(image: Path, cue: Cue) -> list[Path]:
    """Split IMAGE into FLAC tracks beside it. All or nothing."""
    d = image.parent
    work = Path(tempfile.mkdtemp(prefix=".cuesplit-", dir=d))
    written: list[Path] = []
    try:
        total = len(cue.tracks)
        for i, t in enumerate(cue.tracks):
            end = cue.tracks[i + 1].start if i + 1 < total else None
            title = t.title or f"Track {t.number}"
            out = work / f"{t.number:02d} {_safe(title)}.flac"
            meta = {
                "TITLE": title,
                "ARTIST": t.performer or cue.performer,
                "ALBUMARTIST": cue.performer,
                "ALBUM": cue.title,
                "TRACKNUMBER": str(t.number),
                "TRACKTOTAL": str(total),
                "DATE": cue.date,
                "GENRE": cue.genre,
                "DISCNUMBER": cue.disc,
            }
            cmd = [FFMPEG, "-nostdin", "-loglevel", "error", "-y",
                   "-ss", f"{t.start:.6f}"]
            if end is not None:
                cmd += ["-to", f"{end:.6f}"]
            cmd += ["-i", str(image), "-map", "0:a:0", "-map_metadata", "-1",
                    "-c:a", "flac"]
            for k, v in meta.items():
                if v:
                    cmd += ["-metadata", f"{k}={v}"]
            cmd.append(str(out))
            subprocess.run(cmd, check=True, capture_output=True, text=True)
            written.append(out)
        # Every track is written. Now, and only now, replace the image.
        final = []
        for p in written:
            dest = d / p.name
            if dest.exists():
                raise FileExistsError(f"{dest} already exists")
            final.append(dest)
        for p, dest in zip(written, final):
            p.rename(dest)
        image.unlink()
        return final
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: cuesplit.py ITEM", file=sys.stderr)
        return 2
    item = Path(argv[1])
    failed = 0
    for image, cue_path, cue in find_images(item):
        try:
            tracks = split(image, cue)
        except (subprocess.CalledProcessError, OSError) as exc:
            detail = getattr(exc, "stderr", "") or str(exc)
            print(f"cuesplit: could not split {image} — left as it was: "
                  f"{detail.strip()[:300]}", file=sys.stderr)
            failed += 1
            continue
        print(f"cuesplit: split {image.name} into {len(tracks)} tracks "
              f"using {cue_path.name}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
