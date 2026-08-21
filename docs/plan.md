# Private Music Server — Build Plan

A self-hosted music library on a Raspberry Pi, with automatic CD ripping and a custom Android client.

**Names:** the Android app is **Deadwax**; the Pi-side repo is **lathe**. See §14 for components, repos, and conventions.

**Status:** Planning complete. Ready for implementation.
**Target:** Hand to Claude Code, phase by phase.

---

## 1. Goals

1. All my music, stored at home, on hardware I own.
2. Streamable to my Android phone anywhere, and to any desktop browser.
3. Insert a CD → walk away → it appears in the library, correctly tagged, no interaction.
4. A player app I built myself.
5. Custom endpoints for rip status, quarantine review, and stats.

**Non-goals:** video, sharing publicly, multi-tenant hosting, iOS.

---

## 2. Locked decisions

| Area | Decision | Why |
|---|---|---|
| Server | **Navidrome** | Go, tiny, Subsonic + OpenSubsonic API, huge client ecosystem, excellent on ARM |
| Host | **Raspberry Pi 5, 4GB** | 8GB is ~2x the price in the 2026 memory shortage and unnecessary for this workload |
| OS | **Raspberry Pi OS Lite, 64-bit** | Headless, minimal, Debian-based, best Pi hardware support |
| Boot device | **NVMe SSD via M.2 HAT** | SD cards die under sustained SQLite writes. This is the #1 preventable failure. |
| Library storage | **4TB self-powered USB 3 desktop HDD** | ~8,000 albums in FLAC. Cheap tier during shortage. Never bus-powered. |
| Deployment | **Docker Compose** | Reproducible, portable to a real NAS later |
| Rip pipeline | **On the host, not in Docker** | udev + device access in containers is more pain than it's worth |
| Ripper | **abcde**, paranoia relaxed | "Fast and hands-off" was the stated priority |
| Archive format | **FLAC (-5)** | Lossless master. Transcode on the fly for mobile. |
| Tagger | **beets**, non-interactive | MusicBrainz matching, art, ReplayGain, consistent naming |
| Unmatched discs | **Stay in staging → quarantine** | Never let a bad match pollute the library |
| Remote access | **Tailscale** | No open ports, 10-minute setup, works on Android |
| Backups | **restic → Backblaze B2**, cloud-only at first | Local drive deferred; adding one later is ~20 min of work |
| Android app | **Expo dev build + RNTP v5 (`@rntp/player`)** | Handles background audio, lockscreen, Bluetooth, Android Auto |
| Desktop client | **Navidrome's built-in web UI** | Free. Build nothing. |
| App v1 scope | Streaming only, with local metadata cache | Offline downloads deferred to v2 (see §9) |
| Custom API | **FastAPI**, Python | Same language as the rip scripts; small surface |
| Scrobbling | **ListenBrainz, server-side only** | Navidrome scrobbles natively. Deadwax implements nothing — see §9. |
| **App philosophy** | **Album/EP only.** No playlists, no autoplay, no track shuffle | The queue *is* the album. Collapses the fiddliest part of any player. |
| Album art | **One `cover.jpg` per folder, never embedded** | One source of truth; no image duplicated inside every FLAC |
| Multi-disc releases | **One release per disc**, merge endpoint later | Preserves the one-folder rule; merging is a v2 nicety |
| Singles | **Treated as one-track releases** | Rare enough not to warrant a special case |
| Search | **Subsonic `search3`** only | Artist / album / track is all that's wanted. No custom index. |
| Distribution | **Personal, but kept releasable** | No hardcoded server; spec-compliant, not Navidrome-specific |
| Repos | **Two now** (server, app), a third later (client library) | Different languages, toolchains, and publication futures — see §14 |
| Naming | **App gets a real name; server components stay boring** | You debug infrastructure at 11pm; you market an app |

---

## 3. Bill of materials

Prices are USD, approximate, as of August 2026. **The memory/storage shortage is distorting everything** — verify before buying, and check `rpilocator.com` for Pi stock at official pricing rather than marketplace markup.

### Required

| Item | Recommendation | Price |
|---|---|---|
| Single-board computer | Raspberry Pi 5, **4GB** | $100–120 |
| Power supply | Official 27W USB-C PD | $14 |
| Case + cooling | Argon NEO 5 M.2 NVMe (case + cooler + NVMe slot in one) | $40–50 |
| Boot drive | 256GB NVMe M.2 2280 SSD | $40–60 |
| Library drive | 4TB USB 3 **desktop** HDD, own power brick (WD Elements Desktop / Seagate Expansion Desktop) | $100–115 |
| Optical drive | Any external USB CD/DVD drive | $25–35 |
| Powered USB 3 hub | 4-port with its own 12V supply | $30 |
| Ethernet cable | Cat6, whatever length | $8 |
| microSD card | 32GB, for initial flash only | $10 |

**Total: ~$370–445**

### Notes on the BOM

- **Do not buy an 8GB or 16GB Pi right now.** You are paying an AI-datacenter tax for RAM you will not use.
- **The Argon NEO 5 M.2 bundles case, active cooling, and the NVMe carrier**, which is cheaper than buying the official case + official cooler + M.2 HAT+ separately. If you'd rather go official: official case ($10) + Active Cooler ($10) + M.2 HAT+ ($15).
- **Desktop-form HDDs, not portable ones.** Portable 2.5" drives are bus-powered and the Pi cannot reliably feed one plus an optical drive. Desktop 3.5" units ship with their own power brick.
- **The powered hub is for the optical drive**, which is usually bus-powered and draws hard during spin-up. Skip it only if your optical drive has its own PSU.
- **Avoid SSDs for the library.** <200 GB/$ during the NAND shortage. HDD is correct here — you're streaming a few hundred kbps, not doing random IO.
- **No local backup drive at launch** — cloud-only, see §8. Add one when the library passes ~500GB. Deferring costs nothing architecturally and HDD prices may ease.

### Optional / deferred

| Item | Price |
|---|---|
| Backblaze B2 offsite | $6/TB/month — **~$1.80/mo at 300GB** |
| Second 4TB HDD for local backups (add later) | $100–115 |
| UPS HAT (clean shutdown on power loss) | $30–60 |

### Running cost

~5–8W continuous. Roughly **$8–12/year** in electricity at US average rates.

---

## 4. Filesystem layout

```
/srv/
  music/            # THE LIBRARY. Navidrome mounts this read-only.
  staging/
    rips/           # abcde output lands here
    fetched/        # farfetchd drops here, awaiting human review (see docs/fetch-contract.md)
    incoming/       # rsync landing area for uploads. UNWATCHED — see §6.5
  quarantine/       # beets could not confidently match these
  inbox/            # manual drops: Bandcamp, purchases, existing collection
  config/
    navidrome/      # SQLite DB, cache
    beets/          # config.yaml, library.db
    libraryd/       # custom service config
  logs/
    rips/           # one log per disc, named by MusicBrainz disc ID
    beets-import.log
```

**Rule: nothing writes to `/srv/music` except beets.** This is what keeps the library clean. Everything else stages.

This rule has no exceptions, including the initial migration. The existing collection enters through `/srv/inbox/` and is imported by beets like anything else — it is never rsynced straight into `/srv/music`. Copying it in directly would leave those albums absent from beets' `library.db`, which means `incremental: yes` skips them forever, they never conform to the §6.3 path templates, and the library is inconsistent from day one. See Phase 1 in §11.

Create a dedicated `music` user (uid 1001) owning all of `/srv`. Run containers and the rip service as that user.

---

## 5. Server stack

### docker-compose.yml

```yaml
services:
  navidrome:
    image: deluan/navidrome:latest
    container_name: navidrome
    restart: unless-stopped
    user: "1001:1001"
    ports:
      - "4533:4533"
    environment:
      ND_MUSICFOLDER: /music
      ND_DATAFOLDER: /data
      ND_LOGLEVEL: info
      ND_SCANSCHEDULE: "@every 6h"
      ND_SESSIONTIMEOUT: 720h
      ND_ENABLETRANSCODINGCONFIG: "true"
      ND_DEFAULTTHEME: Dark
    volumes:
      - /srv/music:/music:ro
      - /srv/config/navidrome:/data

  libraryd:
    build: ./libraryd
    container_name: libraryd
    restart: unless-stopped
    user: "1001:1001"
    ports:
      - "8080:8080"
    environment:
      NAVIDROME_URL: http://navidrome:4533
    volumes:
      - /srv:/srv
```

Deliberately **no reverse proxy in v1** — Tailscale handles access and there's no TLS to terminate on a tailnet. Add Caddy later only if you decide to expose it publicly.

### Navidrome settings to set after first boot

- Create your user account (first user created becomes admin).
- **Transcoding:** enable Opus 128k as a downsample option. Configure the Android app to request the original FLAC on WiFi and 128k Opus on cellular.
- **ListenBrainz:** add your token under user settings.
- **Scan schedule:** every 6h plus the filesystem watcher. The rip pipeline also pokes a rescan directly when it finishes, so new discs show up in seconds, not hours.
- **Then turn `ND_ENABLETRANSCODINGCONFIG` back off.** That flag exists to let the web UI define transcoding *commands*, which is effectively remote command execution by design. It's acceptable on a single-user tailnet, but it only needs to be on for the few minutes it takes to configure Opus. Set it to `"false"` afterwards and redeploy.

---

## 6. The rip pipeline

Four stages: **detect → rip → tag → notify.**

### 6.1 Detect — udev triggers systemd

udev's `RUN+=` kills long-running processes. Always hand off to systemd.

`/etc/udev/rules.d/99-autorip.rules`:

```
ACTION=="change", KERNEL=="sr[0-9]", SUBSYSTEM=="block", \
  ENV{ID_CDROM_MEDIA_TRACK_COUNT_AUDIO}=="?*", \
  TAG+="systemd", ENV{SYSTEMD_WANTS}="autorip@%k.service"
```

The `ID_CDROM_MEDIA_TRACK_COUNT_AUDIO` check means data discs and DVDs are silently ignored — only audio CDs trigger a rip.

`/etc/systemd/system/autorip@.service`:

```ini
[Unit]
Description=Auto-rip audio CD on %i

[Service]
Type=oneshot
User=music
ExecStart=/usr/local/bin/autorip.sh %i
TimeoutStartSec=3600
Nice=10
IOSchedulingClass=idle
```

`Nice` and `IOSchedulingClass=idle` mean a rip in progress never makes playback stutter.

### 6.2 Rip — abcde

`/etc/abcde.conf`, tuned for speed over archival paranoia:

```sh
CDROM=/dev/sr0
OUTPUTTYPE=flac
FLACOPTS='-5'
OUTPUTDIR=/srv/staging/rips

CDDBMETHOD=musicbrainz
CDDBLOCALRECURSIVE=n

# Fast path: no re-read retries on bad sectors.
CDPARANOIAOPTS="-Z"

ACTIONS=cddb,read,encode,tag,move,clean
INTERACTIVE=n
EJECTCD=y
MAXPROCS=4

OUTPUTFORMAT='${ARTISTFILE}/${ALBUMFILE}/${TRACKNUM} ${TRACKFILE}'
VAOUTPUTFORMAT='Various/${ALBUMFILE}/${TRACKNUM} ${ARTISTFILE} - ${TRACKFILE}'
```

**The tradeoff you accepted:** `-Z` disables paranoia retries. A scratched disc rips fast but may contain silent errors. Mitigation: `autorip.sh` captures cdparanoia's stderr per disc into `/srv/logs/rips/`, and flags any disc that reported read errors so the custom API can surface it for a manual re-rip.

`MAXPROCS=4` uses all four Pi cores for FLAC encoding. Encoding will finish before reading does, so ripping is drive-bound, roughly 5–10 minutes per disc.

### 6.3 Tag — beets

`/srv/config/beets/config.yaml`:

```yaml
directory: /srv/music
library: /srv/config/beets/library.db

import:
  move: yes
  quiet: yes
  quiet_fallback: skip     # the safety valve — never guess, leave it in place
  incremental: yes
  # LOAD-BEARING, and coupled to the two-pass import in inbox-import.sh.
  # At its default (`no`), beets records SKIPPED directories to the incremental
  # history as well as imported ones (importer/tasks.py, ImportTask.finalize).
  # Pass 1 (MusicBrainz) would therefore mark everything it could not match as
  # "seen", and pass 2 (Bandcamp) would skip all of it — the second pass would
  # silently do nothing while still exiting 0. Do not set this back to `no`
  # without collapsing the cascade back to a single pass.
  incremental_skip_later: yes
  log: /srv/logs/beets-import.log

match:
  # DISTANCE threshold, not a confidence score: beets auto-accepts matches
  # scoring BELOW this value. Lower is stricter. 0.04 is the beets default.
  # Do NOT raise this thinking it tightens the filter — it loosens it.
  strong_rec_thresh: 0.04
  max_rec:
    missing_tracks: low
    unmatched_tracks: low

# 'musicbrainz' is load-bearing: beets 2.x moved MB matching out of core and
# into a plugin. Omit it and every import silently finds no match and falls
# through to quiet_fallback: skip. It was implicit in 1.6.
# Both metadata sources are listed here, but inbox-import.sh never runs them
# together: it imports twice, disabling one each time with `beet -P`, so
# MusicBrainz gets first refusal and Bandcamp only sees what it could not
# match. See the cascade note in docs/plan.md 6.3 for why.
#
# 'bandcamp' (beetcamp) is not optional for a download-based collection:
# Bandcamp edits, bootlegs and unofficial remixes are largely absent from
# MusicBrainz and can never match without it.
plugins: musicbrainz bandcamp fetchart replaygain scrub lastgenre missing edit inline zero bandcamp_url

# Local plugin dir. beets resolves pluginpath against the CWD, not the config
# directory, so it must be absolute — the test overlay replaces this the same
# way it replaces `directory` and `library`.
pluginpath:
  - /srv/config/beets/plugins

# Splits multi-disc sets into one release per disc.
# Returns '' rather than 0 for single-disc releases: %if{} treats the empty
# string as unambiguously false, whereas how it coerces the string "0" is a
# beets-version detail the library layout must not depend on.
item_fields:
  multidisc: 1 if disctotal > 1 else ''

# No `singleton:` template. Nothing in the pipeline ever passes `beet import
# -s`, so it was unreachable; and a singleton files with no cover.jpg, which
# breaks the one-folder-one-cover rule. A single is a one-track *release* and
# goes through `default:` like everything else.
paths:
  default: $albumartist/$album%aunique{}%if{$multidisc, (Disc $disc)}/$track $title
  comp: Various Artists/$album%aunique{}%if{$multidisc, (Disc $disc)}/$track $title

fetchart:
  auto: yes
  cautious: yes
  sources:                # beets 2.x requires list form here;
    - filesystem         # the old space-separated string is rejected
    - cover_art_url      # beetcamp sets album.cover_art_url; this core source
                         # consumes it. beetcamp's own 'Bandcamp' source is NOT
                         # a valid key here — fetchart rejects it at startup.
    - coverart
    - itunes
    - albumart
  filename: cover        # always cover.jpg — one image, one name

replaygain:
  auto: yes
  backend: ffmpeg

scrub:
  auto: yes

# Strip MusicBrainz ID fields that do not contain a MusicBrainz ID.
#
# beets maps whatever ID a metadata source supplies onto mb_albumid
# (autotag/hooks.py: "album_id": "mb_albumid"), so Bandcamp-sourced releases
# arrive with bandcamp.com URLs in MUSICBRAINZ_ALBUMID, MUSICBRAINZ_TRACKID,
# MUSICBRAINZ_ARTISTID and the rest. Those fields are UUIDs by definition and
# Navidrome forwards them to ListenBrainz as MBIDs, so the URL is wrong data
# leaving the house. There is no MusicBrainz ID for a release MusicBrainz does
# not have, so the honest value is none at all — the URL itself is preserved in
# BANDCAMP_ALBUM_URL/BANDCAMP_TRACK_URL by the bandcamp_url plugin.
#
# Two things here are easy to get wrong and both fail silently:
#
#   1. The patterns are UNANCHORED. beets 2.x made the artist-ID fields
#      multi-valued; '^https?://' does not match the stringified list, so the
#      tag survives while the config looks correct.
#   2. The PLURAL fields must be listed too. mediafile writes
#      MUSICBRAINZ_ARTISTID from mb_artistids, so zeroing only mb_artistid
#      leaves the tag in place.
#
# update_database stays at its default (off) on purpose: library.db keeps the
# URL in mb_albumid, which is what makes it available for re-resolution.
zero:
  fields: mb_albumid mb_albumartistid mb_albumartistids mb_artistid mb_artistids mb_trackid mb_releasetrackid mb_releasegroupid mb_workid
  mb_albumid: ['https?://']
  mb_albumartistid: ['https?://']
  mb_albumartistids: ['https?://']
  mb_artistid: ['https?://']
  mb_artistids: ['https?://']
  mb_trackid: ['https?://']
  mb_releasetrackid: ['https?://']
  mb_releasegroupid: ['https?://']
  mb_workid: ['https?://']
```

**`quiet_fallback: skip` is the critical line.** Anything beets isn't confident about is left where it is rather than guessed at. `autorip.sh` then sweeps leftovers from `/srv/staging/rips/` into `/srv/quarantine/` for later review.

### The library rules these paths enforce

1. **One release = one folder.** Never nested, never split.
2. **A folder contains audio tracks and exactly one `cover.jpg`.** Nothing else.
3. **No embedded artwork.** `embedart` is deliberately absent from the plugin list. The image lives once, on disk, and Navidrome serves it via `getCoverArt`.
4. **Multi-disc sets become one release per disc** — `Album (Disc 01)`, `Album (Disc 02)`. This preserves rule 1 at the cost of splitting a conceptual release; `libraryd` gets a merge endpoint later (§10) to stitch them back together at the presentation layer.
5. **Singles are one-track releases**, foldered like everything else.

The `multidisc` field comes from the `inline` plugin. **Verified on beets 2.13.1 (2026-08-21)** against a real single-disc import, rendering `$album%if{$multidisc, (Disc $disc)}`:

| `multidisc` expression | Value | Output |
|---|---|---|
| `1 if disctotal > 1 else ''` (shipping) | `''` | `Grapefruit Regret` |
| `1 if disctotal >= 1 else ''` (forces true branch) | `1` | `Grapefruit Regret (Disc 01)` |

Both branches behave, the leading space after the comma is preserved (it's what separates title from suffix), and single-disc albums get no suffix.

**`$disc` is zero-padded to two digits on 2.x** — a second disc folders as `Album (Disc 02)`, not `Album (Disc 2)`. Padding sorts correctly, so it is kept; note it here because it differs from what this plan specified under 1.6.

Test the branches by flipping the *condition* (`> 1` vs `>= 1`), not by substituting a bare literal. `item_fields` values are Python expression bodies, and the `inline` plugin fails to load on a bare `1` or `0` — a substitution test looks like it ran and proves nothing.

### Two metadata sources, imported in two passes

`bandcamp` (beetcamp) is configured alongside `musicbrainz`, but **they are
never loaded at the same time**. `inbox-import.sh` imports twice, disabling one
source per pass with `beet -P`:

```sh
beet -c "$BEETS_CONFIG" -P bandcamp    import "$INBOX"   # MusicBrainz first
beet -c "$BEETS_CONFIG" -P musicbrainz import "$INBOX"   # then the remainder
```

`-P/--disable-plugins` subtracts from the configured list, so both passes keep
`fetchart`, `replaygain`, `scrub` and the rest. (`-p/--plugins` *replaces* the
list and would silently drop them.) `import.move: yes` means pass 1 physically
removes what it matched, so pass 2 only ever sees leftovers.

Bandcamp is not optional for a download-based collection: edits, bootlegs and
unofficial remixes are largely absent from MusicBrainz and can never match
without it. But running the two sources *together* is actively broken. beets
penalises any candidate whose `data_source` differs from the file's existing
tag, and the guard is on the number of loaded plugins, not on the candidates:

```python
# beets/autotag/distance.py — add_data_source
if before != after and (before or len(find_metadata_source_plugins()) > 1):
    self.add("data_source", metadata_plugins.get_penalty(after))
```

Fresh downloads have no `data_source` tag, so `before` is empty and **every**
candidate from **every** source takes the default 0.5 — per album *and* per
track. Measured 2026-08-21: a byte-perfect 13-track Bandcamp release scored
0.1125 instead of 0.0000 and quarantined, with `data_source: 0.5` as the only
penalty on every single track. With both sources loaded and the default in
place, nothing reaches `strong_rec_thresh` and the whole library quarantines.

Splitting the passes means one metadata source plugin is loaded at a time, the
guard is false, and the penalty never applies at all — verified: single-source
matching produces `keys=[]`, no penalty keys whatsoever. That is why the
cascade is the fix rather than tuning the penalty around it. An earlier attempt
did tune it, and needed a local plugin to work around beetcamp disagreeing with
itself about case (`DATA_SOURCE = "bandcamp"` on the metadata it produces vs
`data_source = "Bandcamp"` on the plugin, which makes
`bandcamp.data_source_mismatch_penalty` silently inert). The two-pass form
deletes that plugin and both tuned constants.

It also means MusicBrainz wins whenever it has the release **by construction**
rather than by a tie-break — which matters, because beetcamp writes Bandcamp
**URLs** into `MUSICBRAINZ_ALBUMID` and `MUSICBRAINZ_TRACKID`. And Bandcamp is
only queried for what MusicBrainz could not match.

**Two settings are load-bearing for this and must not drift:**

`incremental_skip_later: yes`. At its default, beets records *skipped*
directories to the incremental history as well as imported ones
(`importer/tasks.py`, `ImportTask.finalize`). Pass 1 would mark everything it
could not match as seen, and pass 2 would skip all of it — doing nothing while
still exiting 0. `import-testdata.sh` refuses to run if this is not set.

The **MusicBrainz-unreachable abort**. A network failure is not an import
failure to beets: it logs the error, skips the album, and `beet import` still
exits 0. Harmless in a single-pass setup — the album quarantines and you retry.
Under the cascade it is corrupting, because pass 2 then matches everything from
Bandcamp and files MusicBrainz-catalogued releases with bandcamp.com URLs in
their MBID fields, `incremental` records them as done, and the real MBIDs are
gone from the archive masters. So pass 1's output is scanned for MusicBrainz
errors, and on a hit the run aborts *before* pass 2 and before the quarantine
sweep, leaving the inbox exactly as it was. This is not theoretical: it fired
during testing when musicbrainz.org was answering in ~22s against beets' 10s
read timeout, and both albums were filed as Bandcamp releases before the guard
existed.

**`autorip.sh` must use the same two passes**, for the same reasons. A CD rip
has no `data_source` tag either.

### MusicBrainz ID fields on Bandcamp releases — settled

beets maps whatever ID a metadata source supplies onto `mb_albumid`
(`autotag/hooks.py`: `"album_id": "mb_albumid"`). It is not a beetcamp quirk —
every source goes through it, and only Discogs got a dedicated
`discogs_albumid` alongside. So a Bandcamp-sourced release arrives with
bandcamp.com URLs in five ID fields: `MUSICBRAINZ_ALBUMID`,
`MUSICBRAINZ_TRACKID`, `MUSICBRAINZ_RELEASETRACKID`, `MUSICBRAINZ_ARTISTID`
and `MUSICBRAINZ_ALBUMARTISTID`.

Those fields are UUIDs by definition, and Navidrome forwards them to
ListenBrainz as MBIDs, so a URL there is wrong data leaving the house. There is
no MusicBrainz ID for a release MusicBrainz does not have, so **the correct
value is none at all** — the `zero` plugin strips them, matched on the value
looking like a URL so genuine MBIDs are untouched.

Two ways to get that config subtly wrong, both of which fail silently and look
like they worked:

- **Patterns must be unanchored.** beets 2.x made the artist-ID fields
  multi-valued; `^https?://` does not match the stringified list and the tag
  survives.
- **The plural fields must be listed.** mediafile writes `MUSICBRAINZ_ARTISTID`
  from `mb_artistids`, so zeroing only `mb_artistid` leaves the tag in place.

`MUSICBRAINZ_ALBUMSTATUS` and `MUSICBRAINZ_ALBUMTYPE` deliberately survive —
they are enumerated values, not identifiers.

The URL itself is preserved, in `BANDCAMP_ALBUM_URL` / `BANDCAMP_TRACK_URL`, by
`ingest/beets/plugins/bandcamp_url.py`. In the *file*, not just in `library.db`:
`/srv/music` is the master and the database is derived, so a rebuild from files
alone must not lose the only route back to a release MusicBrainz cannot
describe. That route is what `libraryd`'s quarantine-resolve needs, since
`album_for_id(<bandcamp url>)` re-fetches the release. Verified 2026-08-21:
beets reads both fields back off a FLAC with `mb_albumid` empty.

The plugin reads from `item` rather than from the `tags` dict, so it does not
matter whether `zero` runs before or after it — both listen for `write` and the
order is not guaranteed.

### What counts as one multi-disc album on disk

beets decides how many import tasks a directory becomes *before* any matching
happens, by collapsing directories that look like discs of one release. It
collapses on the markers `dis[ck]`, `cd`, `cassette`, `digital media` and
`vinyl`, each followed by a digit. Measured 2026-08-21:

| Layout | Import tasks |
|---|---|
| `Album/CD1/`, `Album/CD2/` | 1 |
| `Album/Disc 1/`, `Album/Disc 2/` | 1 |
| `Album Disc 1/`, `Album Disc 2/` (siblings) | 1 |
| `Album (1 of 2)/`, `Album (2 of 2)/` | **2** |
| all tracks flat in one folder | 1 |

Sibling folders are fine as long as the name carries a marker. The trap is the
sensible-looking name that carries none — `(1 of 2)` silently becomes two
half-releases, and see below for why those can never import.

**Deliberately not using the `chroma` (AcoustID fingerprinting) plugin.** It's slow on ARM and CDs have a reliable disc ID already. Add it later only for the `/srv/inbox/` path where files arrive without disc IDs.

### 6.3a Multi-disc CDs — the ripper produces one disc at a time

This is the case that makes `multidisc` fiddly, and it is not about folder
layout. A multi-disc set is ripped one disc per insertion, so without
intervention each disc reaches `/srv/inbox/` as its own import task, minutes or
days apart.

**A single disc of a multi-disc set can never auto-import.** Presented alone
against the full release it is missing half the tracklist, and `max_rec` turns
that into a hard stop rather than a judgement call:

```yaml
max_rec:
  missing_tracks: low
```

`autotag/match.py` caps the recommendation at `max_rec[key]` whenever a penalty
of that key is present, and quiet mode only applies `Recommendation.strong`. So
any missing track downgrades the result to `low`, `quiet_fallback: skip` fires,
and the disc quarantines — no matter how good the match otherwise is. Measured
on half an 8-track album: distance 0.2718, penalties `missing_tracks`,
`data_source`, `tracks`, recommendation `none`.

That is correct behaviour and the threshold should not be relaxed to work
around it. Every disc of every box set landing in quarantine for manual repair
would, however, gut the "ripping is fully automated" goal.

**So `autorip.sh` must accumulate a set before handing it over**, rather than
importing each disc as it finishes:

1. Look the disc's TOC up by MusicBrainz disc ID (`/ws/2/discid/<id>`). The
   response identifies the release *and* its medium list, which gives both this
   disc's position and the total disc count — before ripping anything.
2. `disctotal == 1`, or no disc ID match: straight to `/srv/inbox/` as now.
   This is the overwhelming majority of discs and must not be delayed.
3. `disctotal > 1`: rip into `/srv/staging/rips/<release-mbid>/CD<n>/` and stop
   there. Only when all `disctotal` disc directories are present does the whole
   `<release-mbid>` directory move into `/srv/inbox/`, where beets collapses the
   nested `CD1`/`CD2` layout into a single import task (see the table in §6.3)
   and the `multidisc` path template splits it back out into
   `Album (Disc 01)` / `Album (Disc 02)`.

Consequences to design for:

- **The notification in §6.4 becomes stateful.** "Disc 1 of 2 done — insert
  disc 2" is the useful message; a bare "done" is actively misleading.
- **Incomplete sets need a sweeper.** A set whose remaining discs never arrive
  must not sit in staging forever. Age it out into `/srv/quarantine/` with the
  discs it does have, so it surfaces for review rather than being silently
  half-ripped.
- **`libraryd` needs to show pending sets** — which releases are waiting on
  which discs — otherwise the only way to know is to `ls` the staging tree.
- **A re-rip of a disc already present** should replace it, not collide.

### 6.4 Notify

At the end of `autorip.sh`:

1. Eject the disc (physical signal that it's done).
2. POST to Navidrome's rescan endpoint so the album appears immediately.
3. Push via **ntfy** — self-hosted or ntfy.sh with a random topic. Message: album name, track count, and whether it went to library or quarantine.

### 6.5 The non-CD path

`/srv/inbox/` is watched by a systemd path unit. Anything dropped there (Bandcamp downloads, existing collection, purchases) gets the same beets import with the same quarantine behaviour.

**One ingest pipeline, three entry points:**

| Entry | Lands in | Reviewed before import? |
|---|---|---|
| Optical drive | `/srv/staging/rips/` | No — disc ID is trustworthy |
| Upload from a computer | `/srv/inbox/` via `/srv/staging/incoming/` | No — you sent it deliberately |
| `farfetchd` | `/srv/staging/fetched/` | **Yes** — confirm it fetched the right release |

The third is the only one with a review gate, because it's the only one where
something automated *chose* what to retrieve. Approving moves the directory to
`/srv/inbox/`, at which point it's indistinguishable from a manual drop and the
existing path unit takes over. No second pipeline, no new systemd units.

See `docs/fetch-contract.md` for the full interface.

#### Uploading from a computer

The common case — you found 30 albums on a laptop and want them on the server.

```bash
./lathe/ingest/push-music.sh ~/albums/          # runs on the laptop
```

rsync rather than scp, because it resumes; a dropped connection partway
through 30GB shouldn't mean starting over. For a genuinely large one-time
migration, plugging the drive into the Pi and copying locally beats any
network transfer.

**Two stages, and the reason matters.** `push-music.sh` rsyncs into
`/srv/staging/incoming/`, then moves into `/srv/inbox/`:

> **A systemd path unit fires on the first change, not on quiescence.**
> rsync-ing 30 albums straight into `/srv/inbox/` would trigger the import
> while files were still arriving — beets imports a three-track version of a
> nine-track album, or moves files out from under rsync mid-write. A single
> album copies fast enough that you'd probably never see this; a bulk upload
> hits it every time.

`/srv/staging/incoming/` is not watched, and both directories are on the same
filesystem, so the `mv` is atomic and albums appear in the inbox complete or
not at all. Same principle as `farfetchd` writing `fetch.json` last.

`inbox-import.sh` **also** waits for the inbox to go quiet for two minutes
before importing, as a safety net for the times something gets copied in
directly. Belt and braces, because the failure is silent and costs a re-file.

**Ownership.** You upload as `tom`; beets runs as `music` and needs to *move
and delete* those files, not just read them. `push-music.sh` passes
`--chmod=Dg+rwxs,Fg+rw` so they arrive group-writable, which requires `tom` to
be in the `music` group and the staging directories to be setgid (Phase 0).
Without this the import fails on permissions.

**Set expectations:** albums off a computer are messier than CD rips — mixed
formats, embedded art, junk files, tags from whatever ripped them years ago.
With `strong_rec_thresh: 0.04` expect a substantial quarantine pile on the
first bulk import. That's the config working, not failing.

### 6.6 Library hygiene

The rules in §6.3 are only real if something checks them. `lint.py` runs nightly via systemd timer and on demand via `libraryd`.

**Structural checks** — walk every release folder and flag:

| Violation | Example |
|---|---|
| Stray non-audio files | `.cue`, `.log`, `.m3u`, `.nfo`, `.txt`, `Thumbs.db`, `.DS_Store` |
| Wrong artwork name or count | `folder.jpg`, `front.png`, `back.jpg`, booklet scans, zero images, two images |
| Embedded artwork present | Should have been stripped — indicates a bad import path |
| Nested subfolders | Violates one-release-one-folder |
| Naming drift | Filename doesn't match the beets path template |
| Empty folders | Left behind by moves |

**Metadata checks:**

| Violation | Why it matters |
|---|---|
| Missing `albumartist`, `album`, `date`, or `track` | Breaks browse and sort |
| Missing MusicBrainz release ID | Can't re-tag or merge later |
| Missing ReplayGain | Volume jumps between releases |
| Track number gaps | Usually a failed rip, not a real gap |
| `albumtype` absent | Needed to distinguish album / EP / single |
| Cover art below ~500px | Looks bad in an artwork-first UI |

**Fixable vs. reportable.** Split the output. Deletable junk (`.DS_Store`, empty folders, stray logs) gets a `--fix` flag. Anything involving metadata or artwork is reported only — never let an automated tool rewrite tags unattended.

Output as JSON to `/srv/logs/lint.json`, served by `libraryd` at `GET /library/violations` and rendered in the dashboard.

Related: run `beet fetchart --quiet` periodically to backfill art, and `beet missing` to surface incomplete releases from failed rips.

---

## 7. Networking

**Tailscale on the Pi and the phone.** That's it for v1.

- `tailscale up --ssh` gives you SSH access too.
- MagicDNS means the server is reachable at a stable name like `http://pi:4533` from anywhere.
- No ports forwarded, no dynamic DNS, no certificate management, no attack surface.

**Wired ethernet, not WiFi.** Free reliability.

The cable goes into **the router, or a switch plugged into the router** — not a power socket. Wall ethernet sockets only work if the house has structured wiring patched back to the router; check for a panel before assuming. If there's no port where the Pi will live, in order of preference: run a long cable, use a powerline adapter, or just use the Pi's built-in WiFi. WiFi is genuinely adequate here — ethernet is about reliability, not bandwidth.

**Streaming does not consume household internet bandwidth.** Playing music at home is LAN traffic: phone → router → Pi, never touching the WAN link. FLAC is ~1 Mbps against a ~1,000 Mbps LAN. Remote streaming does use upstream, but at ~1 Mbps for FLAC or ~0.13 Mbps for Opus it's negligible. The only thing that will genuinely degrade the house connection is the initial backup upload — see §8.

**Static DHCP reservation** on your router for the Pi, as a fallback path if Tailscale ever misbehaves.

Only consider a public reverse proxy (Caddy + real domain + Let's Encrypt) if you later want to share with family who won't install Tailscale. Note it if you do — that's a real jump in threat model and warrants fail2ban and a hard look at Navidrome's auth settings.

---

## 8. Backups

**Cloud-only to start.** A local backup drive is deferred until the library outgrows a comfortable cloud restore (~500GB).

The reasoning: B2 is more durable than a drive sitting in the same room as the server. A local copy buys **restore speed**, not safety — and while the library is small, waiting a few hours to restore is an acceptable trade for $115 and a spare USB port. You also physically own the CDs, so anything ripped already has a third copy.

`restic`, nightly, via systemd timer:

```
/srv/music   → Backblaze B2      (the library)
/srv/config  → Backblaze B2      (small, but painful to rebuild)
```

### Bandwidth — the one thing that will annoy the household

Streaming is invisible to the rest of the house. Backup uploads are not.

The initial backup of a few hundred GB will saturate your upstream for **days** if left unthrottled, and everyone's video calls will be miserable. Two mitigations, use both:

```bash
restic backup /srv/music \
  --limit-upload 2000 \        # KiB/s — set to ~50% of your upstream
  --exclude-caches
```

- **Cap the upload rate** at roughly half your measured upstream.
- **Schedule the timer overnight** (`OnCalendar=*-*-* 02:30:00`, with `RandomizedDelaySec`).

After the first run, incremental backups are a handful of MB and you will never notice them again.

### Practices

- Encrypt the repo — restic does this by default. **Store the password somewhere that is not the Pi.**
- `restic check --read-data-subset=5%` monthly. An unverified backup is a rumour.
- `restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune` to stop the repo growing forever.
- **Do a real restore test once**, early, while the library is small enough that it's quick.

### Cost

$0.006/GB/month, first 10GB free. ~$1.80/month at 300GB. Egress is free up to 3× stored, so a full restore falls inside the free allowance — no surprise bill on the day you need it.

### Adding a local tier later

Trivial, and nothing here needs redoing: plug in a drive, `restic init` a second repository, add a second systemd timer. Roughly 20 minutes. Trigger points: library past ~500GB, or the first time a restore wait feels unacceptable.

Alternatives if B2 disappoints: Hetzner Storage Box (cheap, restic over SFTP), rsync.net, Cloudflare R2.

---

## 9. Deadwax — the Android app

### Stack

| Layer | Choice |
|---|---|
| Framework | Expo (**dev build**, not Expo Go — native modules) |
| Language | TypeScript |
| Audio | `@rntp/player` (RNTP v5) |
| Navigation | Expo Router |
| State | Zustand |
| Local DB | `expo-sqlite` + Drizzle ORM |
| Data fetching | TanStack Query |
| Secrets | `expo-secure-store` |
| Hashing | `js-md5` (RN has no built-in MD5) |

**Licensing note:** RNTP v5 is commercially licensed but free for personal use. That's this project. If it ever becomes commercial, either pay or fall back to v4 (Apache-2.0, on the `v4` branch, different package name and incompatible API).

> **Verify this before scaffolding, not after.** RNTP is the one dependency with no realistic substitute — background playback, lockscreen and notification controls, Bluetooth buttons, audio focus, and Android Auto are all native Android plumbing that nothing else in the RN ecosystem wraps as completely. Two things must be confirmed current at the moment work starts:
>
> 1. **The licence still permits personal use on the terms above.** The fallback is v4, which is a different package with an incompatible API — a rewrite of the playback layer, not a version bump.
> 2. **v5's Expo config plugin supports the Expo SDK version you're about to scaffold.** If it lags, the choice is pinning to an older SDK or patching the plugin yourself, and it is much cheaper to know that before there are screens on top of it.
>
> Ten minutes of reading. Do it as the first action of Phase −1(c) and record the answer here.

### Auth model

Subsonic uses salted-token auth in query strings. Per request:

```
salt  = random hex string (regenerate per request)
token = md5(password + salt)
```

Sent as `?u=<user>&t=<token>&s=<salt>&v=1.16.1&c=<appname>&f=json`

Store the **password** (not the token) in SecureStore. The key property: because auth lives in the query string, `stream` URLs are self-contained — you hand the raw URL to RNTP and it plays. No custom headers, no proxy shim, no auth interceptor in the audio layer.

### Design philosophy — the constraint that defines the app

**The queue is the album.** Nothing else is ever queued. This is not a missing feature; it is the product.

What this removes, and what each removal buys:

| Not built | Consequence |
|---|---|
| Playlists | No playlist CRUD, no sync, no reordering, ~4 endpoints dropped |
| Autoplay / continuous play | Playback ends when the record ends. No "what's next" logic. |
| Track shuffle | Track order is the artist's decision |
| Arbitrary queueing | No queue persistence, no drag-to-reorder, no queue screen |
| Song-level browsing | Search returns tracks, but they resolve to *their release* |

What remains: **choose a record, put it on, listen to it.**

Skip-within-album stays (you're allowed to skip a track on a record). Previous/next move within the current album only, and stop at its edges.

**Starting a second album replaces the first, immediately.** "No queue" means no queue *accumulates* — it does not mean you're locked out of the controls while something is playing. On a turntable you lift the needle and put on the other record; you don't wait for side B to run out. So pressing play on album B while album A is playing stops A and starts B at track 1, with no confirmation prompt and nothing retained. The invariant to hold is that **exactly one release is loaded at any moment**, never zero-plus-a-pending-list. Anything that would make "what plays next" a question the app has to answer is the thing being excluded.

### Prior art — study before designing

The album-first philosophy is well established, but **only on iOS, and only against Apple Music or local files**. Nobody has built it for Subsonic on Android.

- **Longplay** (iOS) — the reference implementation. Artwork-first grid, browse by cover not text, next/previous move between albums, no track shuffle. Read its feature list closely; it has solved problems you haven't hit yet.
- **Albums**, **Album Time!**, **The Record Player** (iOS) — same philosophy, different emphases.
- One minimal iOS/macOS Subsonic client explicitly ships without playlist support — closest existing thing, wrong platform.

The gap you're filling is specifically **album-first × Android × OpenSubsonic**.

### API surface for v1

| Purpose | Endpoint |
|---|---|
| Connection test | `ping` |
| Capability detection | `getOpenSubsonicExtensions` |
| Release grid | `getAlbumList2` (`newest`, `random`, `byYear`, `byGenre`, `alphabeticalByArtist`, `starred`) |
| Artist list | `getArtists` |
| Artist detail | `getArtist` |
| Release detail + tracks | `getAlbum` |
| Search | `search3` |
| Artwork | `getCoverArt` (pass `size` — request thumbnails for the grid) |
| Playback | `stream` (with `maxBitRate`, `format`) |
| Favourites | `star`, `unstar`, `getStarred2` |

**Deliberately unused:** `getPlaylists`, `getPlaylist`, `createPlaylist`, `updatePlaylist`, `deletePlaylist`, `getRandomSongs`, `scrobble`.

**On `scrobble`:** Navidrome scrobbles to ListenBrainz server-side, off the back of the `stream` requests the app is already making. Deadwax implementing `scrobble` itself would duplicate that, and hand the app a "have we passed 50%?" progress-tracking concern for no gain. Configure the ListenBrainz token in Navidrome (§5) and the app stays ignorant of scrobbling entirely — which is also what `PHILOSOPHY.md` asks for.

`getAlbumList2` gives you every browse axis you need without a single playlist. `albumtype` from MusicBrainz already distinguishes album / EP / single / compilation / live — filter on it for free.

**Search behaviour:** `search3` returns artists, albums, and songs. Artists and albums navigate directly. A song result navigates to **its release, scrolled to that track** — never to an isolated song. This is the one place the philosophy needs deliberate enforcement in the UI.

### Screens (v1)

1. **Setup** — server URL, username, password, connection test
2. **Shelf** — artwork grid, the primary surface. Sort/filter control (newest, random, year, genre, artist, starred, EP vs album).
3. **Artist** — that artist's releases, as artwork
4. **Release** — large cover, tracklist, single Play button
5. **Search** — one field, results grouped by artist / release / track
6. **Now Playing** — cover dominant, position within the *album* as well as the track, transport, star
7. **Settings** — transcoding quality by network type, cache size, ListenBrainz, logout

No queue screen. No playlist screen. Seven screens total, and two of them are trivial.

### Keeping it releasable

These cost nothing now and mean publishing later is a packaging decision rather than a rewrite:

- **No hardcoded server URL, username, or password.** Ever. Not even in dev — use a `.env` that's gitignored.
- **Target the OpenSubsonic spec, not Navidrome.** Feature-detect via `getOpenSubsonicExtensions`; never assume a Navidrome-specific behaviour.
- **Isolate the API client** in its own module with no UI imports. It should be liftable into a standalone package.
- **Handle spec violations gracefully.** Other servers (Gonic, Ampache, LMS, Airsonic-Advanced, Supysonic) implement the spec unevenly. Missing optional fields should degrade, not crash.
- **Don't assume integer IDs.** Navidrome IDs are strings; other servers differ. Treat every ID as opaque.
- **Multi-server support in the data model** even if the UI only exposes one. A `serverId` column now costs nothing; adding it later is a migration.
- **Pick a licence early.** GPL-3.0 or MPL-2.0 if you want it to stay open.

If you do release: the differentiator is the philosophy, not features. You will lose a feature race to Symfonium and Tempo instantly. The first three requests will be playlists, offline, and iOS — and **saying yes to playlists dissolves the entire point of the app.**

### Local metadata cache

Build this in v1 even though downloads are v2. Rationale: browsing a 5,000-album library over a Tailscale link with a round trip per screen is sluggish. Mirror albums/artists/tracks into SQLite, sync deltas on launch via `getAlbumList2` sorted by `newest`, serve the UI from local, refresh in background.

This also happens to be exactly the foundation offline downloads need.

### Transcoding policy

- **WiFi:** request original (FLAC). Pi handles it trivially — it's just file serving.
- **Cellular:** request `format=opus&maxBitRate=128`. Navidrome transcodes on the fly via ffmpeg. A Pi 5 handles a couple of concurrent transcodes fine.
- Make this a user-visible setting; don't hide the choice.

### v2: offline downloads

Deferred, but designed for:

- `downloads` table: `trackId`, `releaseId`, `state` (queued/downloading/complete/failed), `localPath`, `bytesTotal`, `bytesDone`
- **Releases are the only download unit.** Consistent with everything else — you don't download half a record.
- `expo-file-system` for transfers with resume support
- User-set disk quota with LRU eviction
- Now Playing resolves `localPath` first, falls back to `stream` URL
- Visual state on album tiles: not downloaded / partial / complete / stale

RNTP v5's built-in audio caching is a partial substitute in the meantime — it'll cover the "song I played an hour ago" case but not "prepare for a flight."

---

## 10. Custom service (`libraryd`)

FastAPI. Reachable only over Tailscale. Simple bearer token on top of that.

*(Named `libraryd`, not `ripd` — it covers lint, library operations and stats as well as rips. See §14.)*

| Method | Path | Does |
|---|---|---|
| GET | `/health` | Disk free, drive presence, last successful rip |
| GET | `/rips` | Rip history with status and error flags |
| GET | `/rips/current` | Live progress of an in-flight rip |
| GET | `/events` | SSE stream of rip progress |
| GET | `/quarantine` | Albums beets couldn't match, with candidate matches |
| POST | `/quarantine/{id}/resolve` | Apply a chosen MusicBrainz release ID, re-run beets import |
| GET | `/fetched` | Releases `farfetchd` retrieved, awaiting review |
| POST | `/fetched/{id}/approve` | Move to `/srv/inbox/` for the normal beets import |
| POST | `/fetched/{id}/reject` | Delete the directory |
| GET | `/library/violations` | Lint results from §6.6 — junk files, artwork problems, metadata gaps |
| POST | `/library/lint` | Run the linter now |
| POST | `/library/fix` | Apply only the safe auto-fixes (junk deletion, empty folders) |
| GET | `/releases/split` | Multi-disc sets currently living as separate releases |
| POST | `/releases/merge` | Merge `Album (Disc 1)` + `(Disc 2)` into one presented release |
| POST | `/library/rescan` | Trigger Navidrome scan |
| POST | `/eject` | Eject the tray remotely |
| GET | `/stats` | Album count, total size, rips per month, top artists |

Ship a minimal web dashboard on the same service — this is the actual UI for quarantine review and lint violations, and it works from any browser, so it doesn't need to live in the Android app.

**On `/releases/merge`:** do this by rewriting tags (set a shared `album` and continuous `disc`/`track` numbering) and letting beets re-file, *not* by maintaining a separate mapping table that the app has to know about. Rewriting means the merge is visible to every client, survives a rebuild, and needs zero app-side logic. It does break the one-folder rule for that release — accept the exception, or keep the discs separate and let it go. Low priority either way.

---

## 11. Build phases

Each phase ends in something that works. Stop at any point and you still have a functioning system.

### Phase −1 — Before the hardware arrives

Almost everything here is unblocked. Only the rip pipeline genuinely needs the Pi. Do this work on a laptop and it transfers to the Pi verbatim.

**a) Set up a laptop mirror of the server — do this first, it unblocks everything else**

Run Navidrome in Docker locally, pointed at a folder of test music. Two minutes of work, and it becomes the development target for the app, `lint.py`, and `libraryd`. Because the app is built against the OpenSubsonic spec rather than Navidrome specifics, developing against a laptop instance is functionally identical to developing against the Pi.

**b) Tune beets — highest value of the real work**

**Install beets 2.x — not the distro package.** Ubuntu ships beets `1.6.0` (2022) and that is the only apt candidate, so `apt upgrade` will never move you off it. 1.6.0 writes a corrupted `RELEASETYPE` tag: it stores `albumtypes` as the plain string `album`, mediafile exposes that tag as a *list* field, so it iterates the string character by character and writes `a;l;b;u;m` into every file. These are the archive masters — do not build the library with it.

A system-wide `pip install` is blocked by PEP 668 (`EXTERNALLY-MANAGED`). Use `uv`, which puts `beet` on `PATH` in an isolated environment without touching system packages:

```sh
uv tool install "beets[fetchart,lastgenre]"
```

Skip beets' own `replaygain` extra — it pulls PyGObject for the GStreamer backend, which needs system dev headers to build. §6.3 uses `backend: ffmpeg`, which has no Python dependency. Confirm `which beet` resolves to `~/.local/bin/beet` and not `/usr/bin/beet`; leaving the apt package installed is harmless as long as `~/.local/bin` precedes `/usr/bin` on `PATH`.

Verified on **2.13.1** (2026-08-21): all seven plugins load, MusicBrainz matching works, `RELEASETYPE=album` writes correctly.

The rest is the fiddliest config in the plan and the one most likely to bite. Point beets at a **copy** of existing music (never the original — `import.move: yes` physically relocates and renames every file it touches, so a bad template rearranges your actual collection), and iterate until:

- Path templates produce exactly the folder structure in §6.3
- The `inline` plugin's `multidisc` expression actually evaluates — verify before trusting it
- `quiet_fallback: skip` leaves unmatched albums where you expect
- `fetchart` writes a single `cover.jpg` and nothing is embedded
- ReplayGain via ffmpeg completes without errors

Discovering a broken template now costs an afternoon. Discovering it after 200 CDs costs a re-file of the entire library.

**The test harness** lives at `music-server/testdata/`, outside both repos:

```
testdata/
  originals/    # pristine master copy. NEVER written to.
  staging/      # disposable copy; beets consumes this
  library/      # beets output — check the structure here
  quarantine/   # what quiet_fallback: skip left behind
  beets/        # config-test.yaml + library.db
  logs/
```

`lathe/ingest/reset-testdata.sh` wipes everything derived and re-copies `originals/` → `staging/`, because `move: yes` means each import consumes its input and you'll run it many times.

**`incremental: yes` state does not live in `library.db`.** beets keeps the set of already-imported paths in a `state.pickle` next to the config, so deleting the database resets nothing — every import after the first reports `Skipping previously-imported path` and exits 0, and you can spend an afternoon "tuning templates" while running no imports at all. The test overlay pins `statefile:` into `testdata/beets/` and `reset-testdata.sh` deletes it alongside the db. Left at its default it lands inside the `lathe` repo (gitignored, but still the wrong place).

**Two harness entry points.** `lathe/ingest/import-testdata.sh` is the one to
use for import runs: it invokes the *real* `inbox-import.sh` with the test paths
injected as environment variables, so the two-pass cascade under test is
literally the code that ships rather than a copy of it that can drift. It
inherits `inbox-import.sh`'s quarantine sweep too, so the whole flow is
exercised end to end. `lathe/ingest/beet-test.sh` stays for ad-hoc single
commands — `ls`, `config`, a one-off `import` while tuning a template.

**Config layering — use those wrappers, don't call `beet` directly.** The test setup must run the *real* production config so that what gets tuned is what ships. beets layers `$BEETSDIR/config.yaml` as the base with `-c` overlaid on top, so the wrapper sets `BEETSDIR=lathe/ingest/beets` and passes `testdata/beets/config-test.yaml` as the overlay, which replaces only the three paths.

> **beets has no `include:` directive.** It accepts the key, ignores it, and reads nothing — no warning, no error. An earlier draft of this plan assumed otherwise and the test config silently contained *only* the path overrides: no plugins, no path templates, no match thresholds. Verified against beets 1.6.0. `beet-test.sh` asserts `strong_rec_thresh` is present in the merged config and that `directory` points inside `testdata/`, and refuses to run otherwise — the second check exists so a broken overlay can never write into a real music directory.

**What to put in `originals/`** — 8–12 albums chosen for coverage, not volume:

| Case | Tests |
|---|---|
| Normal single-disc album, well known | The happy path |
| **A multi-disc release** | The `multidisc` expression — the #1 flagged risk |
| Various-artists compilation | The separate `comp` path template |
| An EP or single | `albumtype`, via the `default` path — a single is a one-track *release*, not a beets singleton |
| A Bandcamp single-track download | The worst real case: Bandcamp gives these **no `ALBUM` tag at all**, with everything crammed into `TITLE`. Nothing can match them automatically — they are the quarantine path |

Mostly FLAC, since that's the archive format and ReplayGain-via-ffmpeg needs testing on it. NIN's *Ghosts I–IV* (free, FLAC, CC, well-catalogued in MusicBrainz, genuinely multi-disc) and *The Slip* cover the first two cheaply.

Broken cases are **synthesised, not sourced** — strip tags off a copy to exercise `quiet_fallback: skip`, embed art in another to confirm `scrub` removes it, scatter `.cue`/`.nfo`/`Thumbs.db` to give `lint.py` something to find. Synthetic is better: you control exactly what's wrong.

**c) Validate the app concept before building it**

Run the stock clients — Symfonium, Tempo, Substreamer — against local Navidrome for half an hour. Either this confirms the album-only instinct or it saves you from building the wrong thing. Then study Longplay properly and sketch the seven screens.

**d) Start the Android app (Phase 5 work, fully unblocked)**

The largest single chunk in the plan, and it needs no Pi:

- **First: confirm the RNTP v5 licence terms and Expo SDK support (§9).** Ten minutes, and it gates everything below it.
- Expo dev build scaffold, RNTP wired up, audio playing at all
- The Subsonic client module: salted-token auth, `js-md5`, capability detection via `getOpenSubsonicExtensions`
- SQLite schema + Drizzle, sync logic
- Shelf and Release screens against local Navidrome

Populate the test library with a few hundred albums if you can, so pagination and scroll performance assumptions are realistic rather than flattering.

**e) Write `lint.py` (§6.6)**

Pure Python over a directory tree, no server dependency. Run it against the current messy library — it will immediately tell you how much cleanup Phase 1 involves.

**f) Scaffold `libraryd` against fake data**

The dashboard, quarantine review, and violations view all work off JSON. Only `/eject` and live rip progress need real hardware.

**g) Do the entire backup flow end to end**

Backblaze account, restic repo, back up a small folder, **and do a restore test**. Practising restore at 2GB is the right order of operations; practising at 300GB is not.

**h) Housekeeping**

- Install Tailscale on phone and laptop, get comfortable with it
- Download the Pi OS Lite 64-bit image
- Git repos initialised, `.gitignore` in place, licence chosen — **`deadwax` is GPL-3.0**; `lathe` stays unlicensed, since it's personal config with your paths in it and isn't for publishing
- Settle the §13 open questions — offline downloads is **decided: v2**, per `PHILOSOPHY.md`

**Done when:** the Pi arrives and Phase 0–1 is a single evening — plug in, `docker compose up`, rsync the collection into `/srv/inbox/` and let beets file it.

**Blocked until hardware:** NVMe boot, the udev rule, `autorip.sh`, `/etc/abcde.conf`, anything touching `/dev/sr0`.

### Phase 0 — Base
- Flash Pi OS Lite 64-bit to microSD, boot, update
- Move root filesystem to NVMe, verify boot from NVMe, retire the SD card
- Create `music` user (uid 1001), create `/srv` tree, mount library drive by UUID in `/etc/fstab`
- **Add your own user to the `music` group, and make `/srv/staging/incoming` and `/srv/inbox` setgid** (`chgrp music`, `chmod 2775`). Uploads arrive owned by you but must be movable and deletable by beets, which runs as `music`. Skipping this makes every upload fail on permissions at import time rather than at copy time, which is a confusing place to find out.
- Install Docker + Compose, Tailscale
- **Done when:** you can SSH in over Tailscale from your phone's hotspot

### Phase 1 — Serving music
- `docker compose up` with Navidrome
- **Migrate the existing collection through `/srv/inbox/`, not into `/srv/music`.** rsync it to `/srv/inbox/`, then run the beets import over it. Beets is what places files in `/srv/music` — see §4. This is also the first real test of the §6.3 config at volume, so expect a meaningful quarantine pile on the first pass and budget an evening for working through it.
- Create account, configure transcoding, connect ListenBrainz, then turn `ND_ENABLETRANSCODINGCONFIG` back off
- **Done when:** music plays in a desktop browser and in a stock Subsonic client on your phone over Tailscale

> At this point the system is genuinely useful. Everything after is upgrade.

### Phase 2 — Ripping, manually
- Install `abcde`, `flac`, `cdparanoia`, `beets` and plugins
- Write `/etc/abcde.conf` and beets config
- Rip one CD by hand, import by hand, confirm it lands correctly and appears in Navidrome
- **Done when:** one album has gone disc → library with correct tags and art

### Phase 3 — Automation
- `autorip.sh`, the systemd template unit, the udev rule
- Per-disc logging, error detection, quarantine sweep
- ntfy notifications, auto-eject, Navidrome rescan poke
- `/srv/inbox/` path unit + `inbox-import.sh` for non-CD ingest (settle wait, quarantine sweep)
- `lint.py` (§6.6) + nightly timer
- **Done when:** insert disc, walk away, get a phone notification, album is in the library — and the linter reports zero violations

### Phase 4 — Backups
- restic to Backblaze B2, systemd timer, upload rate capped, scheduled overnight
- Retention policy (`forget --prune`), monthly `check`
- **Done when:** a restore test has actually succeeded — and the first full upload didn't ruin anyone's week

### Phase 5 — Android app
- Expo dev build scaffold, RNTP wired up
- Subsonic API client in its own module, salted-token auth, capability detection
- SQLite metadata cache + sync
- Screens 1–7
- **Done when:** it's the app you reach for instead of the stock client — and nothing in it can queue anything but a release

### Phase 6 — libraryd
- FastAPI service, endpoints above
- Web dashboard: quarantine review, lint violations, rip history
- **Done when:** you can resolve a bad match from your phone

### Phase 7 — v2 features
- Offline downloads
- Android Auto (RNTP v5 supports it natively)
- Whatever you actually miss by then

---

## 12. Gotchas

- **udev `RUN+=` kills long processes.** Dispatch to systemd. Non-negotiable.
- **Expo Go can't load native modules.** You need a dev build from day one of app work.
- **Mount the library drive by UUID**, never `/dev/sda1`. Device order changes when you plug in the optical drive.
- **First Navidrome scan of a large library is slow** on a Pi. Let it finish before judging performance.
- **Some Subsonic clients coerce IDs to integers.** Navidrome IDs are strings. If you write your own client, don't make that mistake.
- **abcde with `-Z` won't tell you loudly about read errors.** That's why per-disc logging is in Phase 3, not optional.
- **Set `ND_SESSIONTIMEOUT` long.** Default logs you out inconveniently often on mobile.
- **beets `incremental: yes` uses a state file** — if you move directories around manually, it gets confused. Let beets own `/srv/music`.
- **HDD spin-down** can cause a 5–10s stall on first play. Either disable it (`hdparm -S 0`) or accept it. For an always-on server, disabling is fine and probably better for drive life than constant spin cycles.
- **Verify the `inline` plugin's `multidisc` expression** before importing a box set, or you'll refile a lot of files twice.
- **Gapless matters more in an album-only app** than in a normal one, because you'll notice every seam on a continuous record. Test with a live album early.
- **A song result in search must never become a standalone queue.** It's the one spot where the philosophy is easy to violate by accident.
- **`strong_rec_thresh` is a distance, not a confidence.** Raising it loosens matching. Default 0.04, lower is stricter.
- **Never rsync music directly into `/srv/music`.** It bypasses beets, so those albums are invisible to `library.db` and `incremental: yes` will never revisit them. Everything enters via `/srv/inbox/`.
- **Never rsync directly into `/srv/inbox/` either.** The path unit fires on the first change, so a long copy gets imported half-finished. Stage in `/srv/staging/incoming/` and move — that's what `push-music.sh` does.
- **`find -newermt "-120 seconds"` is a GNU extension.** Other `find` implementations reject it, and if the error is suppressed the result reads as "nothing changed recently" — so a settle-check built on it silently concludes the copy has finished and imports mid-write. Use a reference file with POSIX `-newer`, and don't suppress the error.
- **Confirm RNTP v5's licence and Expo SDK support before scaffolding the app.** The fallback is an incompatible API, so discovering a problem late means rewriting the playback layer.

---

## 13. Still open

- ~~**Offline downloads: v1 or v2?**~~ **Settled: v2**, per `PHILOSOPHY.md`. The local metadata cache still ships in v1, which is the foundation downloads need — so this stays cheap to add later.
- **Gapless playback.** RNTP v5 has preloading, which gets close. True gapless for continuous albums may need real work — and matters more here than in most players.
- **Classical music tagging.** Composer-vs-performer is genuinely hard and beets' defaults handle it poorly. Only worth solving if a meaningful part of the collection is classical.
- **Family access.** Currently single-user. Adding people means either Tailscale invites (easy, requires them to install it) or a public reverse proxy (harder, real threat model change).
- **UPS.** Whether an unclean shutdown risk to the SQLite DBs justifies $30–60.
- **Whether to release the app at all.** Deferred by design — Phase 5 keeps the option open at no cost. Decide once it's something you actually use daily.

---

## 14. Components, repositories, and naming

### There is only one actual service

Worth being precise about this, because it prevents over-splitting:

| Component | What it actually is |
|---|---|
| Ingest pipeline | Event-triggered batch job (udev → systemd → script) |
| Linter | Scheduled batch job |
| `libraryd` API | The only long-running HTTP service in this repo |
| `fetchd` | A second long-running service, in the separate `farfetchd` repo |
| Dashboard | A frontend served by `libraryd` |
| Deadwax | An Android client |
| Subsonic client | A library inside Deadwax |
| Navidrome | Third-party — you write config, not code |

The first three **do not talk over HTTP**. They integrate through the filesystem contract in `/srv`: the ripper writes per-disc JSON logs, the linter writes `lint.json`, `libraryd` reads both. They share a machine, a language, a user account, and a directory layout.

Splitting them into separate repos would make every change to that contract a coordinated multi-repo commit, in exchange for nothing.

### Repositories

**`lathe`** — everything that runs on the Pi.

```
lathe/
  compose/          docker-compose.yml, Navidrome env
  ingest/           autorip.sh, abcde.conf, beets config
  lint/             lint.py
  libraryd/         FastAPI service
    dashboard/      web UI for quarantine + violations
  systemd/          units, timers, udev rules
  docs/             this plan
```

All Python, one deployment target, versioned together.

> **The server is deliberately not called `deadwax-server`.** If Deadwax is published, a matching "server" repo implies the app needs a specific backend — the opposite of the pitch. Deadwax works with any OpenSubsonic server (Navidrome, Gonic, Ampache, LMS); a decoupled name protects that.
>
> `lathe` is the cutting lathe that carves a master lacquer — including the run-out groove the app is named after. It reads as machinery rather than product, which is the right signal for a repo that is mostly config, systemd units, and personal paths rather than anything installable by a stranger.

**`deadwax`** — the Android app. Different language, different toolchain, different release cadence, and the only thing that might ever be published.

**`farfetchd`** — fetches releases from a site that hosts them for free download, drops them in `/srv/staging/fetched/` for review. **Private, permanently.**

Split out for the same reason the app is: a different publication future. `lathe` could plausibly be published with paths scrubbed; this one never will be. Deciding that per-repo rather than per-directory is the whole argument from the bottom of this section.

It earns the split cheaply because it integrates the same way everything else here does — through the filesystem, not HTTP. It writes one directory and a sidecar JSON; `libraryd` reads them. It never reads beets' database, never queries Navidrome, never touches `/srv/music`. One-directional coupling means either repo can be rewritten without touching the other. It also ships its own compose file and mounts only `/srv/staging/fetched`, so `lathe` stays deployable on its own rather than depending on a build path into a sibling private repo.

The daemon inside it is `fetchd` — boring, per the convention below. The repo carries the joke; the thing you read in `systemctl status` does not.

Interface spec: `docs/fetch-contract.md`.

**`opensubsonic-client`** — extracted from the app **later**, once it stops changing daily. Give it a generic name rather than a Deadwax-branded one so it's useful to others.

> **Don't extract the client library early.** Live with `src/subsonic/` inside the app repo, enforce the no-UI-imports rule from day one, and pull it out when it's stable. Premature extraction means npm-linking and a version bump for every fix, during exactly the phase when you're changing it constantly.

The real justification for splitting server from app isn't technical — it's that they have **different publication futures**. The app is the thing you might open-source; the server repo has your paths and your setup in it. Separate repos means "should I publish this?" is answered per-repo rather than per-directory.

A monorepo is also defensible for a solo project and gives you atomic cross-cutting commits. The split is recommended for the publication reason, not a technical one.

### Naming conventions

**Server side: boring and functional.** `autorip`, `lint`, `libraryd`. You will be SSH'd in at 11pm reading `systemctl status autorip` — the name should tell you what broke, not require recalling which metaphor maps to which job. Thematic names for infrastructure are a tax paid forever for a joke enjoyed once.

*(§10 originally called the API service `ripd`. Since it covers lint, library operations and stats as well as rips, **`libraryd` is the name — settled**, and used consistently throughout this document, in `docker-compose.yml`, and as the directory in the repo.)*

**App side: Deadwax.** Public-facing, and the name that has to do work.

Three things it locks in:

- **Android package ID** — `io.github.<username>.deadwax` (free, no domain needed). Effectively permanent once published.
- **Subsonic `c=` parameter** — `Deadwax`. This is the client identifier on every API call, so it appears in Navidrome's logs and in the logs of any other server if you release it.
- **Repo, F-Droid, and Play listing names.**

**Collision check — partial.** Clear on GitHub, npm, F-Droid, and Google Play. **Not clear conceptually:** at least two vinyl-collection apps named Deadwax exist on iOS (Discogs collection managers / pressing identification), and `deadwax.app`, `deadwax.io` and `deadwaxhq.com` are all taken. Also adjacent: **DeaDBeeF**, an open-source audio player since 2009.

Irrelevant for a personal Android project. If this is ever published, expect to be the third or fourth Deadwax in the music space and to spend effort distinguishing yourself. Runners-up that avoid the collector-app space entirely: **Gatefold**, **Spindle**, **Lacquer**.

**Lock in early:** register the GitHub repos. For the Android package ID, use `io.github.<username>.deadwax` — free, conventional, maps to a namespace you control, and preferred by F-Droid. The package ID cannot be changed after publishing — decide it deliberately rather than typing something provisional into `app.json`.
