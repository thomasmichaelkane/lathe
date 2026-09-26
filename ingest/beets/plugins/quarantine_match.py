"""Record what beets thought of an album it refused, for the quarantine page.

`quiet_fallback: skip` is silent by design: beets looks at the candidates,
decides none is strong enough, and moves on. The candidates and their scores
exist only in memory for that moment, so by the time an album reaches
/srv/quarantine nobody can say whether it was a 94% match with one track
missing or a 30% match against the wrong release entirely — and those want
opposite decisions.

This keeps that moment. When a task is skipped, the best candidate is written
to `<dir>/<entry>.json`: its artist, album, year, track count, source, the
similarity beets would have shown interactively, and the penalties that cost
it. When a task is applied, the record is deleted, so a record exists exactly
while the album is unresolved.

**One record per entry, one slot per source.** `inbox-import.sh` imports in two
passes, one metadata source each (see the cascade note in config.yaml), so
the same album is judged twice. Each pass writes its own slot and leaves the
other alone; the reader decides which to show. Collapsing them here would
throw away the one comparison that tells you whether a Bandcamp URL or an
MBID is the better thing to paste.

**Keyed by entry name, not by path.** The entry is the first path component
under whichever configured container holds the files — the inbox for a normal
import, quarantine for a resolve. The name is the one thing that survives the
quarantine sweep, so it is the only join librariand has.

    quarantine_match:
      dir: /srv/logs/matches
      containers: [/srv/inbox, /srv/quarantine]
"""

import json
import os
import time

from beets.importer import Action
from beets.plugins import BeetsPlugin
from beets.util import syspath

# The penalties worth naming on a card. beets tracks more (media, country,
# label...), but those rarely decide a match and would crowd out the ones
# that do.
PENALTY_LIMIT = 4


class QuarantineMatchPlugin(BeetsPlugin):
    def __init__(self):
        super().__init__()
        self.config.add({
            "dir": "/srv/logs/matches",
            "containers": ["/srv/inbox", "/srv/quarantine"],
        })
        self.register_listener("import_task_choice", self.on_choice)

    # --- where things go ------------------------------------------------

    def _entries(self, task) -> set[str]:
        containers = [os.path.realpath(c)
                      for c in self.config["containers"].as_str_seq()]
        names = set()
        for item in task.items:
            path = os.path.realpath(os.fsdecode(syspath(item.path)))
            for c in containers:
                rel = os.path.relpath(path, c)
                if not rel.startswith(os.pardir):
                    names.add(rel.split(os.sep, 1)[0])
                    break
        return names

    def _record_path(self, name: str) -> str:
        return os.path.join(self.config["dir"].as_filename(), name + ".json")

    # --- the event ------------------------------------------------------

    def on_choice(self, session, task):
        # Never let bookkeeping break an import. A card with no score is a
        # worse dashboard; an exception here is an album that did not import.
        try:
            if task.choice_flag is Action.APPLY:
                for name in self._entries(task):
                    try:
                        os.unlink(self._record_path(name))
                    except FileNotFoundError:
                        pass
            elif task.choice_flag is Action.SKIP:
                self._record(task)
        except Exception as exc:  # noqa: BLE001
            self._log.warning("could not record match: {}", exc)

    def _record(self, task):
        candidates = list(task.candidates or [])
        best = candidates[0] if candidates else None
        # Which source this pass used. With no candidate there is no info to
        # read it from, so fall back to whichever source plugin is loaded —
        # under the cascade that is exactly one.
        source = (best.info.get("data_source") if best else None) \
            or self._loaded_source() or "unknown"

        slot = {
            "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "candidates": len(candidates),
            "recommendation": getattr(task.rec, "name", None),
        }
        if best is not None:
            info = best.info
            slot.update({
                "similarity": round((1 - float(best.distance)) * 100, 1),
                "artist": info.get("artist"),
                "album": info.get("album"),
                "year": info.get("year"),
                "label": info.get("label"),
                "id": info.get("album_id"),
                "url": info.get("data_url"),
                "tracks": len(info.tracks or []),
                "matched_tracks": len(best.mapping),
                "extra_items": len(best.extra_items),
                "missing_tracks": len(best.extra_tracks),
                "penalties": [
                    k.replace("_", " ")
                    for k, _ in best.distance.items()[:PENALTY_LIMIT]
                ],
            })

        os.makedirs(self.config["dir"].as_filename(), exist_ok=True)
        for name in self._entries(task):
            path = self._record_path(name)
            try:
                with open(path) as f:
                    record = json.load(f)
            except (OSError, ValueError):
                record = {}
            record.setdefault("sources", {})[source.lower()] = slot
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(record, f, indent=2)
            os.replace(tmp, path)

    @staticmethod
    def _loaded_source():
        from beets.plugins import find_plugins
        names = {p.name for p in find_plugins()}
        for name in ("musicbrainz", "bandcamp"):
            if name in names:
                return name
        return None
