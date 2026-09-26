# The fetched-drop contract

What `lathe` expects to find in `/srv/staging/fetched/`, and what it does with
it. This is a contract about a **destination**, not about a program: anything
that assembles a complete album directory there works, and `lathe` cannot tell
what produced it.

`farfetchd` is the tool that currently does it — a separate, private CLI that
downloads a release from a URL and writes it wherever you point it. **How it
works is its own repo's business**, and nothing here should describe it. This
document only specifies what has to be true of the directory it leaves behind.

The coupling is one-directional and per-directory: the producer writes into
`/srv/staging/fetched/`, `lathe` reads it and moves things out. No HTTP, no
shared database, no imports. Same integration style as the ripper and the
linter (§14 of `plan.md`): **the filesystem is the API.**

---

## The drop location

```
/srv/staging/fetched/<id>/
    01 Track.flac
    02 Track.flac
    cover.jpg
    fetch.json
```

`<id>` is opaque to `lathe` — any filesystem-safe unique string. Something
timestamp-prefixed sorts usefully in a directory listing, but that is the
producer's call.

### Completeness

Two rules, and everything downstream depends on them:

1. **The directory is assembled elsewhere and moved in.** A partially
   downloaded album must never appear at this path. On one filesystem the move
   is an atomic rename, so a directory here is complete or absent.
2. **`fetch.json` is written last, and atomically** — temp file, `fsync`,
   `os.replace`. Its presence is the signal that the directory is finished and
   readable. A directory without it is in progress or failed, and `lathe`
   ignores it.

Together these mean no locking is needed anywhere in either repo.

### Ownership

`lathe` acts on a fetched directory as the `music` user: approving it
*renames the directory itself* into `/srv/inbox/`, and beets later moves the
files out of it. Moving a directory to a new parent needs write permission on
that directory, not just on its parent, so a directory the producer leaves as
`tom:tom 0755` cannot be approved at all — the dashboard's approve fails with
permission denied.

So the producer must leave everything it writes **writable by the `music`
group**. Either of these satisfies it:

- **Run as `music`.** Nothing else to arrange.
- **Run as a human account in the `music` group, with `umask 002`.**
  `install.sh` makes `/srv/staging/fetched/` setgid `music`, so what is
  created under it inherits the group; the umask is what makes that group
  able to write. The default `022` gives the group read-only.

If the producer assembles the directory elsewhere and moves it in (rule 1
above), the setgid bit does not apply to it — set the group explicitly
before the move.

### Why not `/srv/inbox/`

`/srv/inbox/` is watched by a systemd path unit that imports immediately.
Fetched material needs a human to confirm the *right release* was retrieved
before that happens, so it lands somewhere unwatched and waits.

### Why not `/srv/quarantine/`

Quarantine means "beets found the files and couldn't confidently match them."
Fetched-but-unreviewed is a different state with a different question attached
— *is this the record I actually wanted?* rather than *what is this?* A
download described as `VA - Album [FLAC]` is a claim, not a fact, and no
amount of tagging downstream turns the wrong release into the right one.
Sharing a directory would leave the review dashboard unable to tell the two
apart, and they need different actions.

---

## `fetch.json`

```json
{
  "schema": 2,
  "id": "20260819T142305Z-a1b2c3-album-name",
  "state": "pending_review",

  "source": {
    "site": "example.bandcamp.com",
    "adapter": "bandcamp",
    "url": "https://example.bandcamp.com/album/name",
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
    "mixed_formats": false,
    "cover_present": true,
    "zero_byte_files": []
  },

  "notes": []
}
```

### Field notes

- **`schema`** — integer, bump on any breaking change. `librariand` refuses to
  render a schema it doesn't know rather than guessing.
- **`state`** — always `pending_review` when written. Informational; the real
  state is which directory the files are in.
- **`release`** — whatever the source claimed, unverified. It is a label for
  the review screen, not metadata for the library. beets decides what the tags
  actually become, and disagreeing with this block is normal.
- **`checks`** — the producer's own verification, so review is a glance rather
  than an investigation. `audio_verified` means every file passed a decode
  test (`flac -t` or equivalent); a scraped error page saved as `.flac` is the
  classic failure and is otherwise invisible until you play it.
- **`notes`** — free-text for anything a human should see: a format fallback,
  missing art, a partial track list.

There is no `match` block. Matching is beets' job, downstream, in the one
place that already does it for rips and manual drops.

---

## Review, and what happens after

`librariand` serves the pending queue and performs exactly two actions:

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

`librariand` endpoints (see §10 of `plan.md`):

| Method | Path |
|---|---|
| GET | `/fetched` |
| POST | `/fetched/{id}/approve` |
| POST | `/fetched/{id}/reject` |

---

## What is deliberately not here

Where the producer runs, how it is invoked, what it downloads from, how it
handles torrents or seeding, and what it needs from the network are **not
`lathe`'s concerns** and are not specified here. `lathe` reads a directory.

`farfetchd`'s own repo documents all of that.
