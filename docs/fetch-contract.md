# The fetched-drop contract

What `lathe` expects to find in `/srv/staging/fetched/`, and why that
directory is not `/srv/inbox/`.

This is a contract about a **destination**, not about a particular program.
Anything that assembles a complete album directory and drops it there works.
`farfetchd` is the tool that currently does it, but nothing here depends on
that, and `lathe` cannot tell the difference.

---

## What `farfetchd` is

A standalone command-line tool. It takes a URL — a Bandcamp release, a magnet
link, whatever adapters exist — downloads it, and puts the result in a
directory you name:

```sh
farfetchd https://artist.bandcamp.com/album/name -o /srv/staging/fetched
farfetchd 'magnet:?xt=urn:btih:…'                -o ~/Downloads
```

It exits when it's done. No daemon, no HTTP surface, no config pointing at
this project. It has never heard of beets, Navidrome, or `/srv/music`, and
`-o /srv/staging/fetched` is just one destination among many.

**What follows from that:** `farfetchd` does no searching, no fuzzy matching,
and produces no confidence scores. You hand it a URL you already found. All
matching happens downstream, in beets, where it already happens for rips and
manual drops — see the cascade in §6.3 of `plan.md`.

This is the same integration style as the ripper and the linter (§14 of
`plan.md`): **the filesystem is the API.** The coupling is one-directional and
per-directory — `farfetchd` writes into `/srv/staging/fetched/`, `lathe` reads
it and moves things out. Nothing else passes between them.

---

## The drop location

```
/srv/staging/fetched/<id>/
    01 Track.flac
    02 Track.flac
    cover.jpg
    fetched.json
```

`<id>` is opaque to `lathe` — any filesystem-safe unique string.

### Completeness: assemble elsewhere, then move in

`farfetchd` downloads into its own work directory and moves the finished
album into `-o` as its last action. On one filesystem that's an atomic
rename, so a directory in the destination is either complete or absent —
never half-written.

This is a property worth having in the tool regardless of `lathe`: it's what
makes it safe to point `-o` at *any* watched folder — a Syncthing share, a
Plex inbox, this. Same principle `push-music.sh` uses for uploads (§6.5).

`fetched.json` is then written last, itself via tmp-file + `rename()`. Its
presence is the signal that the directory is finished and readable. A
directory without it is in progress or failed, and `lathe` ignores it. No
locks needed.

### Why not `/srv/inbox/`

`/srv/inbox/` is watched by a systemd path unit that imports immediately.
Fetched material needs a human to confirm the *right release* was retrieved
before that happens, so it lands somewhere unwatched and waits.

### Why not `/srv/quarantine/`

Quarantine means "beets found the files and couldn't confidently match them."
Fetched-but-unreviewed is a different state with a different question attached
— *is this the record I actually wanted?* rather than *what is this?* A magnet
described as `VA - Album [FLAC]` is a claim, not a fact, and no amount of
tagging downstream turns the wrong release into the right one. Sharing a
directory would leave the review dashboard unable to tell the two apart, and
they need different actions.

---

## `fetched.json`

```json
{
  "schema": 1,
  "id": "01J8XV2example",

  "source": {
    "adapter": "bandcamp",
    "url": "https://artist.bandcamp.com/album/name",
    "requested_at": "2026-08-19T14:22:31Z",
    "fetched_at": "2026-08-19T14:23:05Z"
  },

  "release": {
    "artist": "Artist Name",
    "album": "Album Name",
    "year": 2024,
    "track_count": 9,
    "format": "flac"
  },

  "files": [
    { "path": "01 Track.flac", "bytes": 38112044 }
  ],

  "checks": {
    "audio_verified": true,
    "expected_tracks": 9,
    "actual_tracks": 9
  },

  "notes": []
}
```

### Field notes

- **`schema`** — integer, bump on any breaking change. `libraryd` refuses to
  render a schema it doesn't know rather than guessing.
- **`release`** — whatever the source stated, unverified. It is a label for
  the review screen, not metadata for the library; beets decides what the
  tags actually become.
- **`checks`** — the tool's own verification, so review is a glance rather
  than an investigation. `audio_verified` means every FLAC passed `flac -t`
  (a scraped 4KB error page saved as `.flac` is the classic failure mode, and
  it is invisible until you play it). A count mismatch is the other one worth
  seeing before approving.
- **`notes`** — free-text strings for anything a human should see: format
  fallback, missing art, a partial track list.

There is deliberately no `match` block, no candidate list and no confidence
score. Those belonged to a design where the fetcher searched for releases
itself. It doesn't — it is given a URL.

---

## Review, and what happens after

`libraryd` serves the pending queue and performs exactly two actions:

| Action | Effect |
|---|---|
| Approve | Move the directory to `/srv/inbox/` |
| Reject | Delete the directory |

Approval hands off to the existing path unit, so fetched releases go through
the **same beets import as everything else** — same matching, same thresholds,
same `quiet_fallback: skip`, and into quarantine if beets is unsure. No second
ingest pipeline, and no new systemd units on the `lathe` side.

Rips arrive the same way. `autorip.sh` is a producer too: it writes FLACs and
moves them into `/srv/inbox/`, and never runs beets itself (§6.2). All three
entry points end in an atomic move into the inbox, which is what makes "the
filesystem is the API" a real rule rather than a slogan.

Proposed `libraryd` endpoints (see §10 of `plan.md`):

| Method | Path |
|---|---|
| GET | `/fetched` |
| POST | `/fetched/{id}/approve` |
| POST | `/fetched/{id}/reject` |

---

## Torrents: the payload is a copy, never a move

A torrent's identity is the hash of its piece layout over exact file bytes at
exact relative paths. The library is beets' output: `import.move: yes`
relocates and renames every file to the §6.3 template, then `scrub` strips
tags, `zero` blanks the MusicBrainz ID fields, `replaygain` writes gain tags
and `fetchart` adds a `cover.jpg` that was never in the torrent.

**So a library file can never seed the torrent it came from.** The two systems
disagree about whether files are allowed to change, and no configuration
reconciles that. Don't try.

The arrangement that works:

- The torrent client keeps its own download directory (`/srv/torrents/`, or
  anywhere outside the beets world). That copy is the seed, and nothing ever
  touches it again.
- `farfetchd` **copies** the completed payload into `-o`, leaves the torrent
  seeding, and exits.
- Cost is 2× disk for seeded material, for as long as you seed. A FLAC album
  is ~350MB; twenty in flight is ~7GB.

**Never hardlink into a beets-managed path.** It is the obvious optimisation
and it is a trap: a hardlink survives the move into `/srv/inbox/`, because a
rename preserves the inode — so beets imports the very inode the client is
seeding and then writes tags into it. The seed corrupts silently and fails a
hash check days later.

**Bound the cost with seed time, not ratio.** Trackers that require seeding
usually specify a duration; set the client's seed-time limit and let it
auto-remove-and-delete when satisfied. That turns 2× forever into 2× for a
fortnight, self-cleaning.

`farfetchd` drives an existing client (transmission-daemon over RPC) rather
than implementing BitTorrent — resume, DHT, piece verification and ratio rules
come free, and status reporting is a query rather than bookkeeping. VPN
binding and killswitch stay the client's concern, which is a second reason not
to absorb it.

---

## Deployment

`farfetchd` is a CLI and runs wherever you are. It needs no access to
`/srv/music`, `/srv/config`, or anything but its own work directory and the
`-o` you give it.

Run it on the Pi and two things join the stack: a torrent client, and
`/srv/torrents/` for it to own. Run it on a laptop and neither does — you
point `-o` at a local folder and get the files across with `push-music.sh`
like any other manual drop.

Either way `lathe`'s compose file doesn't reference it, and `lathe` stays
deployable on its own.

---

## Open, for when this gets built

- **Adapters beyond the first two.** The dispatch is URL → adapter, so the
  value is in how cheap the third one is. Design the registry before writing
  the second adapter, not after the fourth.
- **Batch input.** The first real ask is "I have forty of these, not one" —
  a file of URLs, resume across a failed item, and therefore a small piece of
  persistent state. `status`, `retry` and `--dry-run` fall out of that state
  for free.
- **Deduplication.** `farfetchd` cannot know what you already own — it can't
  read `library.db` and shouldn't. If dedup matters it belongs to whatever
  hands it the URL, not to the fetcher.
- **Failure visibility.** A CLI reports failure by exiting non-zero and
  logging; that covers the interactive case. Fetches launched from elsewhere
  need somewhere for a failure to land, or a request that finds nothing is
  silent forever.
- **Politeness on HTTP sources.** Identifying User-Agent, rate limiting,
  cached index rather than re-crawling per fetch.
