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

from quarantine import QUARANTINE, QuarantineError, _resolve as _resolve_entry

BEET = os.environ.get("BEET_CMD", "beet")
BEETS_CONFIG = Path(os.environ.get("BEETS_CONFIG", "/srv/config/beets/config.yaml"))

# How long to let one album's import run. Fetching art and computing ReplayGain
# over a long release on a Pi is not fast, and a timeout that fires mid-import
# leaves a half-moved album.
TIMEOUT = int(os.environ.get("RESOLVE_TIMEOUT", "1800"))

UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I
)


def classify(identifier: str) -> tuple[str, str]:
    """Return (kind, plugin_to_disable) for an identifier.

    Raises rather than guessing. An identifier that is neither a UUID nor a
    URL would otherwise reach beets as a search string and quietly match
    something else entirely.
    """
    ident = (identifier or "").strip()
    if UUID_RE.match(ident):
        return "musicbrainz", "bandcamp"
    if ident.startswith(("http://", "https://")):
        if "bandcamp.com" not in ident:
            raise QuarantineError(
                f"only bandcamp.com URLs are understood, got: {ident}"
            )
        return "bandcamp", "musicbrainz"
    raise QuarantineError(
        "identifier must be a MusicBrainz release UUID "
        "(e.g. 1a2b3c4d-....-............) or a bandcamp.com album URL, "
        f"got: {ident!r}"
    )


def resolve(name: str, identifier: str, dry_run: bool = False) -> dict:
    """Import one quarantine entry against `identifier`.

    Imports in place, from the quarantine directory. `import.move: yes` means a
    successful import physically relocates the files into /srv/music and leaves
    the quarantine entry empty, so "did the entry disappear" is the honest
    success test — beets exits 0 whether or not it matched anything, because
    `quiet_fallback: skip` treats a non-match as an ordinary outcome.
    """
    path = _resolve_entry(name)          # rejects traversal, checks existence
    kind, disable = classify(identifier)

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
           "import", "--search-id", identifier.strip(), str(path)]

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

    still_there = (QUARANTINE / name).exists() and any(
        p.is_file() for p in (QUARANTINE / name).rglob("*")
    ) if (QUARANTINE / name).is_dir() else (QUARANTINE / name).exists()

    if not still_there:
        return {"ok": True, "source": kind, "detail": "imported",
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
            f"untouched. Check the id is for the right release, and that the "
            f"track count matches — a release missing tracks will not match "
            f"even with a forced id."
        ),
        "output": output.strip(),
    }
