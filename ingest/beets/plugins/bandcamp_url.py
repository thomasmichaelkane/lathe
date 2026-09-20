"""Keep the Bandcamp release URL in the file, out of the MusicBrainz ID fields.

beets maps whatever ID a metadata source provides onto `mb_albumid`
(beets/autotag/hooks.py: `"album_id": "mb_albumid"`), so a Bandcamp-sourced
release ends up with bandcamp.com URLs in MUSICBRAINZ_ALBUMID, MUSICBRAINZ_
TRACKID, MUSICBRAINZ_ARTISTID and friends. Those fields are defined to hold
MusicBrainz UUIDs, and Navidrome forwards them to ListenBrainz as MBIDs, so a
URL there is not merely untidy — it is wrong data leaving the house.

The `zero` plugin (see config.yaml) strips those fields when they hold a URL.
This plugin makes sure the URL is not simply lost when that happens: it writes
it to BANDCAMP_ALBUM_URL / BANDCAMP_TRACK_URL instead.

Why put it in the file at all, when beets keeps it in library.db? Because
/srv/music is the master and library.db is derived. Without this, rebuilding
the library from the files alone would permanently lose the link back to the
Bandcamp release — which is what librariand's quarantine-resolve flow needs, and
the only way to re-fetch metadata for a release MusicBrainz does not have.

Reads from `item` rather than from `tags`, so it does not care whether `zero`
runs before or after it — both listen for the same `write` event and the order
is not guaranteed.
"""

import mediafile

from beets.plugins import BeetsPlugin

FIELDS = (
    ("bandcamp_album_url", "BANDCAMP_ALBUM_URL", "mb_albumid"),
    ("bandcamp_track_url", "BANDCAMP_TRACK_URL", "mb_trackid"),
)


class BandcampUrlPlugin(BeetsPlugin):
    def __init__(self):
        super().__init__()
        for name, tag, _ in FIELDS:
            # Registered for every container, not just FLAC: nothing in the
            # pipeline rejects lossy, so mp3/m4a arrive through /srv/inbox too.
            self.add_media_field(
                name,
                mediafile.MediaField(
                    mediafile.MP3DescStorageStyle(tag),
                    mediafile.MP4StorageStyle(
                        f"----:com.apple.iTunes:{tag}"
                    ),
                    mediafile.StorageStyle(tag),
                    mediafile.ASFStorageStyle(tag),
                ),
            )
        self.register_listener("write", self.on_write)

    def on_write(self, item, path, tags):
        for name, _, source in FIELDS:
            value = item.get(source) or ""
            if "bandcamp.com" in value:
                tags[name] = value
