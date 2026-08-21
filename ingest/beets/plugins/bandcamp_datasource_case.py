"""Normalise beetcamp's data_source casing so match penalties apply correctly.

beetcamp is internally inconsistent about the case of its data source name:

    beetcamp/metaguru.py:39            DATA_SOURCE = "bandcamp"   <- on every
                                       AlbumInfo / TrackInfo it produces
    beetsplug/bandcamp/__init__.py:89  data_source = "Bandcamp"   <- what the
                                       plugin advertises about itself

beets resolves a candidate's mismatch penalty by matching the candidate's
`data_source` against each metadata plugin's `data_source`
(beets/metadata_plugins.py, get_penalty). The two strings differ only in case,
so the lookup misses and silently falls back to the hardcoded default of 0.5 —
meaning `bandcamp.data_source_mismatch_penalty` in config.yaml has no effect
whatsoever on Bandcamp candidates.

That penalty is applied per album AND per track, so on a 13-track release it
accumulates: a release that is a byte-perfect match scores 0.1125 instead of
0.0000, lands above strong_rec_thresh, and quarantines under quiet_fallback.
The source added specifically to catch releases MusicBrainz does not have was
the only one being penalised.

Fixing it here rather than in site-packages keeps it surviving `uv tool
upgrade`, and travels with the repo to the Pi. Remove this plugin if beetcamp
ever makes the two constants agree — verify by importing a Bandcamp-only
release and confirming the winning candidate scores 0.0000.
"""

from beets.plugins import BeetsPlugin


class BandcampDatasourceCasePlugin(BeetsPlugin):
    def __init__(self):
        super().__init__()
        # Fires for candidates from search and from a direct URL/ID lookup.
        self.register_listener("albuminfo_received", self._normalise)
        self.register_listener("trackinfo_received", self._normalise)

    def _normalise(self, info):
        self._fix_one(info)
        # The TrackInfo objects nested inside an AlbumInfo never fire
        # `trackinfo_received` — that event is only sent for standalone track
        # lookups. They must be walked explicitly, and they are the bulk of the
        # damage: the penalty is applied per track, so on a 13-track release
        # fixing only the album level leaves 13/14ths of the distance in place.
        for track in getattr(info, "tracks", None) or ():
            self._fix_one(track)

    @staticmethod
    def _fix_one(info):
        source = getattr(info, "data_source", None)
        if isinstance(source, str) and source.lower() == "bandcamp":
            info.data_source = "Bandcamp"
