# The fetch contract

The interface between `farfetchd` (private, separate repo) and this one.

`farfetchd` retrieves releases from a site that hosts them for free download
and drops them somewhere `lathe` can see. Nothing else passes between them —
no HTTP calls, no shared database, no imports. Same integration style as the
ripper and the linter (§14 of `plan.md`): **the filesystem is the API.**

The coupling is deliberately one-directional. `farfetchd` writes; `lathe`
reads. `farfetchd` never reads beets' `library.db`, never queries Navidrome,
and never touches anything under `/srv/music`. If this rule holds, either
repo can be rewritten without touching the other.

---

## The drop location

```
/srv/staging/fetched/<request-id>/
    01 Track.flac
    02 Track.flac
    cover.jpg
    fetch.json
```

`<request-id>` is opaque to `lathe` — any filesystem-safe unique string.
A ULID or timestamp-prefixed slug sorts usefully; that's `farfetchd`'s call.

### Why not `/srv/inbox/`

`/srv/inbox/` is watched by a systemd path unit that imports immediately.
Fetched material needs a human to confirm the *right release* was retrieved
before that happens, so it lands somewhere unwatched and waits.

### Why not `/srv/quarantine/`

Quarantine means "beets found the files and couldn't confidently match them."
Fetched-but-unreviewed is a different state with a different question attached
— *did we get the right album?* rather than *what is this?* Sharing a
directory would leave the review dashboard unable to tell them apart, and the
two need different actions.

---

## `fetch.json`

Written **last**, after every audio file is completely on disk. Its presence
is the signal that a directory is complete — a directory without it is either
in progress or failed, and `lathe` ignores it. This avoids needing locks.

```json
{
  "schema": 1,
  "request_id": "01J8XV2example",
  "state": "pending_review",

  "request": {
    "raw": "artist - album name",
    "artist": "Artist Name",
    "album": "Album Name",
    "url": null,
    "requested_at": "2026-08-19T14:22:31Z"
  },

  "source": {
    "site": "example.net",
    "adapter": "example",
    "url": "https://example.net/releases/album-name",
    "fetched_at": "2026-08-19T14:23:05Z"
  },

  "match": {
    "confidence": 0.94,
    "method": "search",
    "candidates": [
      { "title": "Album Name", "url": "https://…", "score": 0.94 },
      { "title": "Album Name (Remixes)", "url": "https://…", "score": 0.61 }
    ]
  },

  "release": {
    "artist": "Artist Name",
    "album": "Album Name",
    "year": 2024,
    "track_count": 9,
    "format": "flac",
    "mbid": null
  },

  "files": [
    { "path": "01 Track.flac", "bytes": 38112044 }
  ],

  "notes": []
}
```

### Field notes

- **`schema`** — integer, bump on any breaking change. `libraryd` refuses to
  render a schema it doesn't know rather than guessing.
- **`state`** — always `pending_review` when written. Informational only;
  the real state is which directory the files are in.
- **`match.candidates`** — the runners-up, so review is a glance rather than
  an investigation. This is the field that makes the whole gate cheap, and it
  is the main reason the sidecar exists at all.
- **`match.confidence`** — 0–1. `libraryd` may sort or flag on it, but never
  auto-approves on it. A human always looks.
- **`release.mbid`** — populate when known; it makes the subsequent beets
  match trivial. Null is fine.
- **`notes`** — free-text strings for anything a human should see (format
  fallback, missing art, partial track list).

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

Proposed `libraryd` endpoints (see §10 of `plan.md`):

| Method | Path |
|---|---|
| GET | `/fetched` |
| POST | `/fetched/{id}/approve` |
| POST | `/fetched/{id}/reject` |

---

## Deployment

`farfetchd` ships its own `docker-compose.yml` and is brought up separately.
It mounts **only** `/srv/staging/fetched`, read-write. It gets no access to
`/srv/music`, `/srv/config`, or anything else.

This is why `lathe`'s compose file doesn't reference it: a build path into a
sibling private repo would make `lathe` undeployable on its own.

---

## Open, for when this gets built

- What the site actually is, technically — an API, a feed, or a sitemap makes
  matching far less fragile than scraping HTML.
- Whether requests are `artist + album` (needs search and matching) or a URL
  already found by hand (sidesteps matching entirely — much simpler v1).
- Format preference when several are offered. The archive is FLAC; decide
  whether MP3 is acceptable or a request should fail instead.
- Deduplication against what's already in the library, so a re-request is
  cheap to notice.
- Politeness: identifying User-Agent, rate limiting, cached site index rather
  than re-crawling per search. Worth mentioning to the site's owner.
