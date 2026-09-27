#!/usr/bin/env python3
"""Re-import one quarantined release against an identifier you chose.

Quarantine means beets found the files and would not confidently match them.
Usually you know what the release is — you can see it on MusicBrainz, or it is
a Bandcamp edit MusicBrainz has never heard of. This hands beets that answer
and lets it do the rest: `beet import --search-id` restricts the candidate set
to exactly that release, so the match is no longer a guess.

**Two identifier types, and they must not be mixed.** beets penalises any
candidate whose `data_source` differs from the file's existing tag, but only
once more than one metadata-source plugin is loaded (`autotag/distance.py`,
`add_data_source`). With a single source loaded the guard is false and the
penalty never applies. This is the same reason `inbox-import.sh` imports in two
passes rather than one, and getting it wrong here would reintroduce the exact
bug that cascade exists to eliminate — silently, as a worse match rather than
an error. So: a MusicBrainz UUID runs with Bandcamp disabled, a Bandcamp URL
runs with MusicBrainz disabled, and there is no third case.

Accepting a Bandcamp URL is not a convenience. Bandcamp edits, bootlegs and
unofficial remixes are largely absent from MusicBrainz, so for a download-based
collection a meaningful slice of quarantine can *only* be resolved this way —
there is no MusicBrainz ID to type in, because there is no MusicBrainz release.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

from quarantine import (QUARANTINE, QuarantineError, _audio_paths,
                        _resolve as _resolve_entry)

BEET = os.environ.get("BEET_CMD", "beet")
BEETS_CONFIG = Path(os.environ.get("BEETS_CONFIG", "/srv/config/beets/config.yaml"))

# How long to let one album's import run. Fetching art and computing ReplayGain
# over a long release on a Pi is not fast, and a timeout that fires mid-import
# leaves a half-moved album.
TIMEOUT = int(os.environ.get("RESOLVE_TIMEOUT", "1800"))

_UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
UUID_RE = re.compile(rf"^{_UUID}$", re.I)

# Pasting the whole address from musicbrainz.org is the natural thing to do,
# so it is accepted — but only a /release/ page names one edition. The page
# search lands you on is the release GROUP, whose UUID looks identical, and
# beets' --search-id finds no release with it: "did not match", which reads
# as the album not matching rather than the wrong kind of ID (#40).
MB_URL_RE = re.compile(
    rf"^https?://(?:beta\.)?musicbrainz\.org/([a-z-]+)/({_UUID})(?:[/?#].*)?$", re.I
)
_MB_WRONG_PAGE = {
    "release-group": "the album as a whole (a release group)",
    "recording": "a single recording",
    "artist": "an artist",
    "work": "a work",
    "label": "a label",
}


def classify(identifier: str) -> tuple[str, str, str]:
    """Return (kind, plugin_to_disable, id_for_beets) for an identifier.

    Raises rather than guessing. An identifier that is neither a UUID nor a
    URL would otherwise reach beets as a search string and quietly match
    something else entirely.
    """
    ident = (identifier or "").strip()
    if UUID_RE.match(ident):
        return "musicbrainz", "bandcamp", ident.lower()
    m = MB_URL_RE.match(ident)
    if m:
        page, uuid = m.group(1).lower(), m.group(2).lower()
        if page == "release":
            return "musicbrainz", "bandcamp", uuid
        raise QuarantineError(
            f"that link is to {_MB_WRONG_PAGE.get(page, 'a ' + page + ' page')}, "
            "not one edition. On MusicBrainz, open the release whose track "
            "count matches your files and copy its /release/ link or ID."
        )
    if ident.startswith(("http://", "https://")):
        if "bandcamp.com" not in ident:
            raise QuarantineError(
                "only musicbrainz.org/release/ and bandcamp.com links are "
                f"understood, got: {ident}"
            )
        return "bandcamp", "musicbrainz", ident
    raise QuarantineError(
        "identifier must be a MusicBrainz release UUID "
        "(e.g. 1a2b3c4d-....-............) or a bandcamp.com album URL, "
        f"got: {ident!r}"
    )


def resolve(name: str, identifier: str, dry_run: bool = False) -> dict:
    """Import one quarantine entry against `identifier`.

    Imports in place, from the quarantine directory. `import.move: yes` means a
    successful import physically relocates the AUDIO into /srv/music, so "is
    any audio left in the entry" is the honest success test — beets exits 0
    whether or not it matched anything, because `quiet_fallback: skip` treats
    a non-match as an ordinary outcome.

    Audio, not files. beets leaves everything else behind — an `Edition
    Info.txt`, a `folder.jpg`, a .cue — and judging by "any file remains" used
    to report a successful import as "did not match", leaving a blank card of
    leftovers behind. Same rule as inbox-import.sh's sweep. On success the
    leftovers are deleted, so the card goes with the album.
    """
    path = _resolve_entry(name)          # rejects traversal, checks existence
    kind, disable, ident = classify(identifier)

    if not BEETS_CONFIG.is_file():
        raise QuarantineError(
            f"beets config not found at {BEETS_CONFIG} — has install.sh run?"
        )
    if shutil.which(BEET) is None:
        raise QuarantineError(
            f"{BEET} is not on PATH. install.sh links it into /usr/local/bin "
            f"from its venv at /usr/local/lib/beets — re-run install.sh."
        )

    cmd = [BEET, "-c", str(BEETS_CONFIG), "-P", disable,
           "import", "--search-id", ident, str(path)]

    if dry_run:
        return {"ok": True, "dry_run": True, "source": kind,
                "command": " ".join(cmd), "detail": "nothing was run"}

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        raise QuarantineError(
            f"beets did not finish within {TIMEOUT}s. It may still be running; "
            f"check the entry before retrying."
        ) from None
    except OSError as exc:
        raise QuarantineError(f"could not run beets: {exc}") from None

    output = (proc.stdout or "") + (proc.stderr or "")

    # A network failure is not an import failure to beets: it logs, skips, and
    # exits 0. Under a forced-id import that means "could not reach the source"
    # and "the id did not match" look identical from the exit code alone. Same
    # trap inbox-import.sh guards against between its two passes.
    unreachable = re.search(
        r"musicbrainz: Error|Max retries exceeded|Read timed out", output, re.I
    )

    entry = QUARANTINE / name
    if not (entry.exists() and _audio_paths(entry)):
        leftovers = []
        if entry.is_dir():
            leftovers = sorted(str(p.relative_to(entry))
                               for p in entry.rglob("*") if p.is_file())
            shutil.rmtree(entry, ignore_errors=True)
        elif entry.exists():
            entry.unlink()
        detail = "imported"
        if leftovers:
            detail += f" — cleared {len(leftovers)} leftover file(s): " + \
                      ", ".join(leftovers[:5]) + (" …" if len(leftovers) > 5 else "")
        return {"ok": True, "source": kind, "detail": detail,
                "output": output.strip()}

    if unreachable:
        raise QuarantineError(
            f"could not reach {kind} — the entry was left untouched. "
            f"Try again when it is back."
        )

    return {
        "ok": False,
        "source": kind,
        "detail": (
            f"beets did not match {name} against that {kind} id. The entry is "
            f"untouched. Check the id is for the right release"
            + (" — a /release/ ID, not the release group's" if kind == "musicbrainz" else "")
            + " — and that the track count matches: a release missing tracks "
            "will not match even with a forced id."
        ),
        "output": output.strip(),
    }
