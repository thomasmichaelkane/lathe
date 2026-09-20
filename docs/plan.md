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
| Rip → library hand-off | **Atomic move into `/srv/inbox/`** | The ripper produces, `inbox-import.sh` consumes. One ingest pipeline, not two — §6.2 |
| Archive format | **FLAC (-5)** | Lossless master. Transcode on the fly for mobile. |
| Tagger | **beets**, non-interactive | MusicBrainz matching, art, ReplayGain, consistent naming |
| Unmatched albums | **Left in the inbox → swept to quarantine** | Never let a bad match pollute the library |
| Remote access | **Tailscale** | No open ports, 10-minute setup, works on Android |
| Backups | **restic → Backblaze B2**, cloud-only at first | Local drive deferred; adding one later is ~20 min of work |
| Client | **Deadwax**, in its own repo | Album-first Android client. Speaks OpenSubsonic like any other client; its internals are not this repo's concern — §9 |
| Desktop client | **Navidrome's built-in web UI** | Free. Build nothing. |
| Custom API | **FastAPI**, Python | Same language as the rip scripts; small surface |
| Scrobbling | **ListenBrainz, server-side only** | Navidrome scrobbles natively off the `stream` requests clients already make. No client implements it — §9 |
| Album art | **One `cover.jpg` per folder, never embedded** | One source of truth; no image duplicated inside every FLAC |
| Multi-disc releases | **One folder per disc** on disk; discs that arrive separately **quarantine and are merged by hand** — §6.3a, §6.5a | Preserves the one-folder rule, and clients still present it as *one album with disc sections* — measured, §6.5a. Letting them quarantine costs a minute per box set and needs no stateful ripper |
| Singles | **Treated as one-track releases** | Rare enough not to warrant a special case |
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
    rips/           # abcde output lands here, then moves to /srv/inbox/ (§6.2)
    fetched/        # completed downloads land here, awaiting human review (see docs/fetch-contract.md)
    incoming/       # rsync landing area for uploads. UNWATCHED — see §6.5
  quarantine/       # beets could not confidently match these
  inbox/            # manual drops: Bandcamp, purchases, existing collection
  config/
    navidrome/      # SQLite DB, cache
    beets/          # config.yaml, library.db
    librariand/       # custom service config
  logs/
    rips/           # one log per disc, named by MusicBrainz disc ID
    beets-import.log
```

**Rule: nothing writes to `/srv/music` except beets.** This is what keeps the library clean. Everything else stages.

This rule has no exceptions, including the initial migration. The existing collection enters through `/srv/inbox/` and is imported by beets like anything else — it is never rsynced straight into `/srv/music`. Copying it in directly would leave those albums absent from beets' `library.db`, which means `incremental: yes` skips them forever, they never conform to the §6.3 path templates, and the library is inconsistent from day one. See Phase 1 in §11.

Create a dedicated `music` user (uid 1001) owning all of `/srv`. Run containers and the rip service as that user.

**The library drive is mounted at `/srv` as a whole — settled 2026-09-20 — not
at `/srv/music`.** Three reasons, in order of how expensive getting it wrong
is:

1. `staging`, `inbox` and `music` all land on one filesystem, so every hand-off
   in §6.5 is a real rename. Mount them apart and `mv` silently becomes
   copy-then-delete, the path unit fires partway through, and beets imports a
   half-written album — §12.
2. The SQLite databases (Navidrome's, beets' `library.db`) stay off the boot
   media. While the Pi is still on the microSD that matters for write wear; it
   matters for corruption on an unclean shutdown either way.
3. Boot media becomes disposable. Moving the OS from SD to NVMe is then a pure
   OS copy with nothing about the library involved.

The consequence to keep in mind is that `install.sh` writes two files onto the
library drive — `/srv/config/beets/config.yaml` and the plugins — so the beets
config is the one deployed artifact not on the OS drive. Everything else it
touches is under `/usr/local/bin` and `/etc`.

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

  librariand:
    build: ./librariand
    container_name: librariand
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
- **Transcoding:** enable Opus 128k as a downsample option, so clients can request the original FLAC on WiFi and 128k Opus on cellular.
- **ListenBrainz:** add your token under user settings.
- **Scan schedule:** every 6h plus the filesystem watcher. The rip pipeline also pokes a rescan directly when it finishes, so new discs show up in seconds, not hours.
- **Then turn `ND_ENABLETRANSCODINGCONFIG` back off.** That flag exists to let the web UI define transcoding *commands*, which is effectively remote command execution by design. It's acceptable on a single-user tailnet, but it only needs to be on for the few minutes it takes to configure Opus. Set it to `"false"` afterwards and redeploy.

---

## 6. The rip pipeline

Three stages: **detect → rip → hand off.**

Tagging and notification are deliberately *not* the ripper's job. `autorip.sh`
produces a finished album directory, moves it into `/srv/inbox/`, and stops.
From there the shared ingest pipeline takes over — the same beets import
(§6.3) and the same `inbox-import.sh` (§6.5) that handle a manual drop or an
approved `farfetchd` fetch.

**The ripper is a producer; the ingest pipeline is the consumer.** Nothing in
`autorip.sh` runs beets, sweeps quarantine, or knows what the library looks
like. That split is what stops the rip path from quietly becoming a second,
subtly different copy of the import path — see the hand-off below.

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

# Deliberately not EJECTCD=y. autorip.sh ejects, and only after the album has
# been moved into /srv/inbox — see §6.4. If abcde ejected on its own the tray
# would open before the hand-off, and a failed move would look exactly like a
# success.
EJECTCD=n

MAXPROCS=4

OUTPUTFORMAT='${ARTISTFILE}/${ALBUMFILE}/${TRACKNUM} ${TRACKFILE}'
VAOUTPUTFORMAT='Various/${ALBUMFILE}/${TRACKNUM} ${ARTISTFILE} - ${TRACKFILE}'
```

**The tradeoff you accepted:** `-Z` disables paranoia retries. A scratched disc rips fast but may contain silent errors. Mitigation: `autorip.sh` captures cdparanoia's stderr per disc into `/srv/logs/rips/`, and flags any disc that reported read errors so the custom API can surface it for a manual re-rip.

`autorip.sh` layers a small per-run config over this with `abcde -c`, setting
`OUTPUTDIR` to a work directory unique to that disc. Two drives ripping at once
therefore cannot land in the same tree, and the finished album is found by
listing that directory rather than by reproducing abcde's naming rules in the
script.

`MAXPROCS=4` uses all four Pi cores for FLAC encoding. Encoding will finish before reading does, so ripping is drive-bound, roughly 5–10 minutes per disc.

#### Hand off — the atomic move into `/srv/inbox/`

When `abcde` exits, the finished album is sitting at
`/srv/staging/rips/<Artist>/<Album>/`. `autorip.sh` then does three things and
finishes:

1. Write the per-disc log to `/srv/logs/rips/<discid>.json` — cdparanoia's
   stderr, the read-error flag, track count, and the `handoff_path` it is about
   to move to.
2. `mv` the album directory to `/srv/inbox/<Artist> - <Album>/`, appending the
   disc ID if that name is already taken.
3. `rmdir` the now-empty artist directory left behind in staging, and eject
   (§6.4).

**The move must be a rename, not a copy.** `/srv/staging` and `/srv/inbox` are
on the same filesystem, so `mv` is a single atomic `rename(2)` and the path
unit watching `/srv/inbox/` can never observe a half-written album. This is the
same completeness trick `push-music.sh` uses for uploads and `fetch.json` uses
for fetches — it is why none of the three entry points needs a lock.

The destination name is for humans only. It is what you read in the inbox, or
in quarantine if the match fails; beets ignores it entirely and files by tags.

**`autorip.sh` does not run beets.** It is tempting — the disc ID makes the
match near-certain, and importing inline would let a single notification report
the final outcome. Don't. `inbox-import.sh` already implements the settle wait,
the non-zero-exit handling, the collision-safe quarantine sweep and the
empty-directory cleanup; duplicating that in the rip path means two
implementations and two beets invocations to keep in step, and *one ingest
pipeline* stops being true. The price of not duplicating it is that the ripper
no longer knows whether the album reached the library or quarantine — which is
what `handoff_path` in the disc log exists to let `librariand` reconstruct later
(§10).

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

**`quiet_fallback: skip` is the critical line.** Anything beets isn't confident about is left where it is rather than guessed at. `inbox-import.sh` then sweeps whatever is still sitting in `/srv/inbox/` into `/srv/quarantine/` for later review — one sweep, covering rips and manual drops alike, because by this point they are indistinguishable (§6.5).

### The library rules these paths enforce

1. **One release = one folder.** Never nested, never split.
2. **A folder contains audio tracks and exactly one `cover.jpg`.** Nothing else.
3. **No embedded artwork.** `embedart` is deliberately absent from the plugin list. The image lives once, on disk, and Navidrome serves it via `getCoverArt`.
4. **Multi-disc sets become one release per disc** — `Album (Disc 01)`, `Album (Disc 02)`. This preserves rule 1 at the cost of splitting a conceptual release; `librariand` gets a merge endpoint later (§10) to stitch them back together at the presentation layer.
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
describe. That route is what `librariand`'s quarantine-resolve needs, since
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

> **Deferred (2026-08-21), and now superseded for v1 (2026-08-22).** The
> staging design below is unimplemented and stays that way. Multi-disc rips are
> allowed to quarantine, and `quarantine.py merge` (§6.5a) puts them back
> together — one command per box set, no state in the ripper. Keep this section
> as the design to reach for if manual merging turns out to be tedious enough
> to be worth automating.
>
> **Why the cheap answer wins here.** Everything below only pays off if box
> sets are common; a set that never gets its remaining discs still needs the
> ageing-out sweeper, `librariand` still has to show pending sets, and the
> notification becomes stateful — that is three moving parts, all of which fail
> *silently* by leaving music in staging. Quarantine already fails loudly, is
> already swept, already reviewed, and is where a half-ripped set would end up
> anyway. So the merge tool is not the fallback for the staging design; it is
> the thing that makes the staging design optional.
>
> What is unaffected either way: the `multidisc` path template is verified on
> both branches (§6.3), so the *library layout* is proven, and a merged set
> imports through the normal pipeline with no special case.


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
- **`librariand` needs to show pending sets** — which releases are waiting on
  which discs — otherwise the only way to know is to `ls` the staging tree.
- **A re-rip of a disc already present** should replace it, not collide.

### 6.4 Notify

Split across the two halves, because they signal different things.

**`autorip.sh` ejects the disc** as soon as the hand-off move succeeds. That is
a physical signal with a narrow, immediate meaning: *the drive is free, put the
next disc in.* It says nothing about the library, because at that moment the
album has not been imported yet.

**`inbox-import.sh` notifies**, because it is the only thing that knows the
outcome:

1. Poke Navidrome's `startScan` endpoint so new albums appear immediately.
2. Push via **ntfy** — self-hosted or ntfy.sh with a random topic. Message: how
   many albums imported, how many went to quarantine, and their names.

Both are configured in `/etc/default/lathe` (§11) and both are optional. Unset
means the step is skipped and logged; neither can fail an import that has
already succeeded, which is why every failure in them is swallowed after being
logged. The rescan is skipped entirely when nothing was imported — a first bulk
import where everything quarantines has not changed the library.

The rescan uses Subsonic token auth (`t=md5(password+salt)`), so the password
is not sent over the wire, but it is stored in plain text in
`/etc/default/lathe` — hence 0600 and root ownership. Losing the poke costs
latency and nothing else: the scheduled scan and the filesystem watcher still
find everything, which is why a failure here is a log line rather than a
non-zero exit.

Album names are listed in the push up to `NOTIFY_MAX_NAMES` (default 10) and
the rest collapse into a count, so a 300-album migration that mostly
quarantines does not arrive as a 300-line notification.

Putting both on the ingest side means all three entry points get them. Under
the previous design only rips poked Navidrome, so a manual drop or an approved
fetch stayed invisible until the next scheduled scan — a bug avoided here by
accident.

**One failure belongs here rather than to the ripper:** a MusicBrainz outage
during pass 1 aborts the run before the Bandcamp pass and before the quarantine
sweep, leaving the inbox untouched (§6.5). `autorip.sh` cannot see that — it
handed off and exited long before — and the album is *not* in the library
despite the disc having ripped and ejected cleanly. So that abort pushes at
high priority from here. It is the exception that proves the rule below: the
component that knows is the component that reports.

**Every other failure belongs to the ripper.** A rip that never
reaches the inbox is something `inbox-import.sh` will never see and therefore
can never report — it would simply be silent. So `autorip.sh` sends its own
ntfy push when abcde exits non-zero, produces no audio, or produces something
other than the one album directory expected, and it keeps the work directory
for inspection instead of cleaning up. That is the only push it sends: the
consumer announces success, the producer announces the failures the consumer
cannot know about.

Two consequences to expect. The notification is now **per import run, not per
album**: a stack of CDs ripped back to back collapses into one push covering
several discs, and a 30-album migration produces one message rather than
thirty. That is the better default, but it means ntfy is no longer a reliable
"*this* disc is done" signal — the eject is. And an album now appears in the
library roughly `SETTLE_SECONDS` after the rip finishes rather than
immediately. Two minutes of latency on an unattended process is not worth a
second import path to avoid.

### 6.5 The shared ingest path

`/srv/inbox/` is watched by a systemd path unit. Anything that lands there — a
rip, a Bandcamp download, the existing collection, an approved fetch — gets the
same beets import with the same quarantine behaviour.

**One ingest pipeline, three entry points:**

| Entry | Lands in | Reviewed before import? |
|---|---|---|
| Optical drive | `/srv/inbox/` via `/srv/staging/rips/` | No — disc ID is trustworthy |
| Upload from a computer | `/srv/inbox/` via `/srv/staging/incoming/` | No — you sent it deliberately |
| `farfetchd` | `/srv/staging/fetched/` | **Yes** — confirm it fetched the right release |

The third is the only one with a review gate, because it's the only one where
something automated *chose* what to retrieve. Approving moves the directory to
`/srv/inbox/`, at which point it's indistinguishable from a manual drop and the
existing path unit takes over. No second pipeline, no new systemd units.

**All three converge on `/srv/inbox/`.** Whatever produced the files —
cdparanoia, rsync, `farfetchd` — the last step is always an atomic move into the
inbox, and everything downstream of it is shared. `autorip@.service` and
`inbox.path` are separate units with no ordering relationship between them and
no knowledge of each other; the filesystem is the only thing that passes from
producer to consumer.

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

### 6.5a Working through quarantine — `librariand/quarantine.py`

Quarantine is where every failure lands: a bad match, a half-tagged download, a
disc of a set that can never match alone (§6.3a). Nothing decides what happens
next but you, so the whole design goal is to make a pile of thirty directories
triageable in one screen and repairable in one command.

```
quarantine.py list                 # what is there, and a guess at why
quarantine.py show ENTRY           # tags, rip log, disc ID, MusicBrainz lookup
quarantine.py groups               # entries that look like one multi-disc set
quarantine.py merge A B [C ...]    # combine those discs, hand back to the inbox
quarantine.py retry ENTRY...       # hand back to the inbox unchanged
quarantine.py drop ENTRY...        # delete
```

**`merge` is the multi-disc repair.** It restacks the chosen entries as
`<Album>/CD1`, `<Album>/CD2`, … — the layout beets collapses into a single
import task (see the table in §6.3) — and moves that into `/srv/inbox/`. From
there it is an ordinary import: beets sees the complete tracklist, the
`missing_tracks` penalty that quarantined each disc individually never fires,
and the `multidisc` path template files it back out as `Album (Disc 01)` /
`Album (Disc 02)`.

Three properties it has deliberately:

- **It rewrites no tags.** beets re-reads the whole set against MusicBrainz on
  import and writes disc numbers itself; a merge that guessed them would be a
  second, worse source of truth for the same field.
- **The work directory lives inside `/srv/quarantine/`**, so every move is a
  rename within one filesystem, the hand-off into the inbox is the single
  atomic rename `inbox.path` requires, and an interrupted merge leaves the
  discs recoverable under `.merge-*` rather than half-copied into the inbox. A
  failure part-way puts every disc back where it was.
- **It never clobbers.** Same collision rule as `inbox-import.sh` — an existing
  destination gets a timestamp suffix rather than being overwritten.

**What a merged set looks like in a client.** One album, with disc sections —
not two albums, and not a flat run of tracks. **Measured on Navidrome 0.63.2
(2026-08-22)**, against the exact layout the path template produces: two disc
folders, identical `album`/`albumartist` tags, `disc` 1 and 2, `disctotal` 2.

| On disk | Navidrome |
|---|---|
| `Karenn/Grapefruit Regret (Disc 01)/` + `(Disc 02)/` | one album, `songCount: 4`, `discTitles: [{disc 1}, {disc 2}]` |
| same but with no `MUSICBRAINZ_ALBUMID` | identical — still one album |
| `Someone/Just One Disc/` (control) | one album, `discTitles: []` |

**Navidrome groups by tags, and folders are not part of album identity at all.**
The clincher is that the `path` it reports over Subsonic is synthesised from
tags — `Karenn/Grapefruit Regret/01-01 - ….flac`, with no `(Disc 01)` in it —
rather than being the real path on disk. So the `(Disc 01)` suffix the
`multidisc` template writes is cosmetic: it exists to keep one folder per
release on disk (§6.3), and no client ever sees it.

This is the actual argument for merging, and it is stronger than "so the
folders are tidy". Two discs imported separately are **two independent
MusicBrainz matches**, and each is a fresh chance to disagree about the album
name, the release date, or the release MBID — and any of those disagreements
splits the album in the UI. A merged set is *one* import task and therefore one
tagging decision for every track in it, which is what makes the presentation
correct by construction rather than by luck.

> **Correction to §2 and §10.** "One release per disc" describes the *folder*
> layout, not what gets presented — a tag-consistent set has always been one
> album to a client. So `/releases/split` and `/releases/merge` in §10 do not do
> what their names suggest: there is nothing to stitch together at the
> presentation layer, because nothing was split. What can genuinely split an
> album is *tags* — discs that imported separately and got different album
> names or release MBIDs. If those endpoints survive, that is the problem they
> should solve, and `/library/violations` (§6.6) is the more natural home for
> detecting it.

**`groups` is the part that saves the reading.** It proposes sets from three
signals and labels which one it used, because they are not equally trustworthy:

| Confidence | Signal | Needs |
|---|---|---|
| `certain` | Two rip logs whose disc IDs resolve to the same MusicBrainz release | `--online` |
| `strong` | Same album artist and album, distinct disc numbers in the tags | tags |
| `possible` | Same album with non-overlapping track numbers, or names differing only by a disc marker | — |

Only `certain` also knows *how many* discs the set should have, which is the
one thing worth going online for: it is the difference between "these two go
together" and "these two go together and disc 3 is still in the box". The
lookup is one request per disc ID, rate-limited to MusicBrainz's one per
second, cached in `/srv/logs/rips/.discid-cache.json`, and every command works
without it.

Two cases it refuses rather than guesses. **Same album, overlapping track
numbers** is two rips of the same disc, not a set — reported, but with no merge
command offered. **Same album, no disc *or* track numbers** is undecidable, and
says so, because the alternative is a confident-sounding wrong answer about
files it cannot read.

**It is a library as much as a CLI.** `librariand`'s `/quarantine` endpoints
(§10) import `entries()`, `groups()`, `merge()`, `retry()` and `drop()` rather
than shelling out, and `--json` on the read commands is there so the dashboard
and the CLI cannot drift. `mediafile` is imported lazily: without it every
command still works and only the tag-derived columns go blank, which matters on
a machine where beets lives in its own virtualenv.

`quarantine-test.sh` fabricates a quarantine tree with ffmpeg — a real
two-disc set, an untagged one, a duplicate pair, a loose `.flac`, a rip log —
and runs the real script against it. **Write `DISCTOTAL` and `TRACKTOTAL` as
their own Vorbis comments** when fabricating test files: `-metadata disc=1/2`
reaches the file as `DISCNUMBER=1/2`, and mediafile does not split the slash
form on Vorbis the way it does on ID3, so the slash form silently loses
`disctotal` — the field the grouper keys off. beets and abcde both write the
separate fields.

### 6.6 Library hygiene

The rules in §6.3 are only real if something checks them. `lint.py` runs nightly via systemd timer and on demand via `librariand`.

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

Output as JSON to `/srv/logs/lint.json`, served by `librariand` at `GET /library/violations` and rendered in the dashboard.

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

## 9. Deadwax — the Android client

**Deadwax** is the album-first Android client. Separate repo, separate language,
separate release cadence, and the only part of this project that might ever be
published.

It is deliberately **not** a component of this system. It talks to Navidrome over
the OpenSubsonic API exactly as any third-party client would, targets the spec
rather than Navidrome specifically, and hardcodes nothing about this server.
Point it at Gonic or Ampache and it works. That decoupling is the whole pitch
(see the naming note in §14), so its internals do not belong in this document
and nothing here may come to depend on them.

What this server owes it is only what it owes any client: a spec-compliant
OpenSubsonic endpoint, one `cover.jpg` per folder (§6.6), correct `albumtype` and
`discNumber` tags out of beets (§6.3), Opus transcoding enabled, and a long
`ND_SESSIONTIMEOUT` (§5).

The one thing worth knowing on this side: **Deadwax implements no scrobbling.**
Navidrome scrobbles to ListenBrainz server-side off the `stream` requests the app
already makes, so the token goes in Navidrome's config (§5) and the app stays
ignorant of it entirely. Configure it there or it does not happen.

Stack, screens, API surface, visual direction and build phases live in
`docs/plan.md` in the `deadwax` repo; the product constraints live in
`PHILOSOPHY.md` beside it.

---

## 10. Custom service (`librariand`)

FastAPI. Reachable only over Tailscale. Simple bearer token on top of that.

*(Named `librariand` — it tends the library rather than serving it, and it covers lint, rips and stats as well as quarantine. See §14 for the two names it had before this one.)*

| Method | Path | Does |
|---|---|---|
| GET | `/health` | Disk free, drive presence, last successful rip |
| GET | `/rips` | Rip history with status and error flags |
| GET | `/rips/current` | Live progress of an in-flight rip |
| GET | `/events` | SSE stream of rip progress |
| GET | `/quarantine` | Albums beets couldn't match, with candidate matches |
| GET | `/quarantine/groups` | Entries that look like discs of one multi-disc set |
| POST | `/quarantine/merge` | Combine listed entries into `Album/CD1`, `CD2`, … and hand back to the inbox |
| POST | `/quarantine/{id}/retry` | Move back to the inbox unchanged for another import attempt |
| POST | `/quarantine/{id}/resolve` | Apply a chosen MusicBrainz release ID, re-run beets import |
| DELETE | `/quarantine/{id}` | Delete the directory |
| GET | `/fetched` | Completed downloads awaiting review |
| POST | `/fetched/{id}/approve` | Move to `/srv/inbox/` for the normal beets import |
| POST | `/fetched/{id}/reject` | Delete the directory |
| GET | `/library/violations` | Lint results from §6.6 — junk files, artwork problems, metadata gaps |
| POST | `/library/lint` | Run the linter now |
| POST | `/library/fix` | Apply only the safe auto-fixes (junk deletion, empty folders) |
| GET | `/releases/split` | Sets whose discs got *different album tags* and so present as separate albums — **not** merely one folder per disc, see §6.5a |
| POST | `/releases/merge` | Reconcile those tags onto one release |
| POST | `/library/rescan` | Trigger Navidrome scan |
| POST | `/eject` | Eject the tray remotely |
| GET | `/stats` | Album count, total size, rips per month, top artists |

**On `/rips`:** rip history comes from `/srv/logs/rips/`, which records the rip
and nothing after it — the ripper hands off before the import happens (§6.2), so
it cannot know the outcome. Each disc log carries `handoff_path`; `librariand`
resolves final status by checking whether that name is still sitting in
`/srv/quarantine/`.

Ship a minimal web dashboard on the same service — this is the actual UI for quarantine review and lint violations, and it works from any browser, so it doesn't need to live in the Android app.

**On the quarantine endpoints:** they are a thin HTTP layer over
`librariand/quarantine.py` (§6.5a), which is a working CLI in its own right and
does not wait for Phase 6. Import its functions; do not shell out to it, and do
not reimplement the merge — the atomic-rename and rollback behaviour is the
part that must not exist twice.

**There are two different merges, and they are not the same operation.**
`/quarantine/merge` combines discs that *never imported* — it restacks
directories in `/srv/quarantine/` and hands the set back to the inbox, and the
result is one correctly-tagged release. `/releases/merge` below combines discs
that *did* import, as `Album (Disc 01)` and `Album (Disc 02)` already sitting in
`/srv/music/`, and it does so by rewriting tags. The quarantine one is the
common case, is cheap, and ships first; the library one is a presentation
nicety for sets that got through separately. Don't collapse them into one
endpoint — they take different inputs and have different blast radii.

**On `/releases/merge`:** do this by rewriting tags (set a shared `album` and continuous `disc`/`track` numbering) and letting beets re-file, *not* by maintaining a separate mapping table that the app has to know about. Rewriting means the merge is visible to every client, survives a rebuild, and needs zero app-side logic. It does break the one-folder rule for that release — accept the exception, or keep the discs separate and let it go. Low priority either way.

---

## 11. Build phases

Each phase ends in something that works. Stop at any point and you still have a functioning system.

### Getting the repo onto the system paths

Every script in this repo carries a "Deployed to ..." line in its header,
because almost nothing runs from where it is checked out:

| Repo path | System path |
|---|---|
| `ingest/autorip.sh` | `/usr/local/bin/autorip.sh` |
| `ingest/inbox-import.sh` | `/usr/local/bin/inbox-import.sh` |
| `ingest/abcde.conf` | `/etc/abcde.conf` |
| `ingest/beets/config.yaml` | `/srv/config/beets/config.yaml` |
| `ingest/beets/plugins/*.py` | `/srv/config/beets/plugins/` (the absolute `pluginpath` in §6.3) |
| `systemd/*.service`, `systemd/*.path`, `systemd/*.timer` | `/etc/systemd/system/` |
| `systemd/99-autorip.rules` | `/etc/udev/rules.d/` |
| `compose/docker-compose.yml` | **nothing — it runs from the checkout** (see below) |

Copying these by hand is fine exactly once. After that it is a trap, and a
quiet one: **edit the repo copy and deploy it, never edit the deployed copy.**
A hotfix applied directly to `/etc/abcde.conf` at midnight does not fail, it
works — and from then on the repo describes a system that no longer exists,
which is worse than having no repo at all. The next `git pull` and re-copy then
silently reverts the fix.

`install.sh` is that copy table, and it is the only thing that should ever
write to those paths:

```sh
sudo ./install.sh --dry-run    # show what would change, touch nothing
sudo ./install.sh              # deploy
```

An update is `git pull` followed by `sudo ./install.sh`. It replaces code and
never data: `/srv/music`, `/srv/inbox`, `/srv/quarantine`, `/srv/staging`,
beets' `library.db` and `state.pickle`, and Navidrome's database are all
untouched, so a backlog sitting in quarantine has no bearing on a deploy.

`compose/docker-compose.yml` is deliberately not in the table. It runs from the
checkout, so there is no deployed copy to drift from and pulling the repo is the
whole update. Navidrome itself updates on its own axis, with
`docker compose pull && docker compose up -d`.

Three things in the script are worth knowing about, because each exists for a
failure that is silent:

- **Files are renamed into place, never copied over.** `cp` truncates the
  destination in place, and bash reads a script incrementally as it runs it, so
  copying over `/usr/local/bin/inbox-import.sh` during a bulk import — which is
  a `oneshot` with a six-hour timeout and will legitimately run for hours —
  makes the running shell resume at its old byte offset in different content
  and execute whatever it finds. Measured: the `cp` case dies with `unexpected
  EOF while looking for matching '"'`, the rename case finishes cleanly on the
  old version. The script also refuses to deploy while an ingest unit is active;
  `--force` skips that check, and is safe precisely because of the rename.
- **It re-checks that `/srv/inbox` and `/srv/staging` share a filesystem.**
  Nothing else does, and if a remount ever splits them the atomic hand-off
  quietly becomes copy-then-delete — §12.
- **`/srv/config/beets/` gets named files copied into it, never a sync.**
  `library.db` and `state.pickle` live in that directory; clearing it would
  reset `incremental` and lose the library database.
- **Every `.path` and `.timer` in `systemd/` is deployed and enabled**, and
  restarted when its unit file changes. `.service` units are deployed but never
  enabled — `autorip@.service` is templated and started by udev,
  `inbox-import.service` by its path unit. The `.timer` glob is there ahead of
  `lint` (§6.6) and `restic` (§8), because a unit type missing from it is not
  an error anywhere: the file just never arrives, and a timer that was never
  deployed looks exactly like a timer that never fired.

`/etc/default/lathe` is created once with everything unset and never
overwritten. It holds the ntfy topic and the Navidrome login, is 0600
root-owned, and is shared by `autorip@.service` and `inbox-import.service` —
one topic for the whole system, set once. Nothing in it is required: unset
means the notification or the rescan is skipped and logged, never that an
import fails.

### Phase −1 — Before the hardware arrives

Almost everything here is unblocked. Only the rip pipeline genuinely needs the Pi. Do this work on a laptop and it transfers to the Pi verbatim.

**a) Set up a laptop mirror of the server — do this first, it unblocks everything else**

Run Navidrome in Docker locally, pointed at a folder of test music. Two minutes of work, and it becomes the development target for the app, `lint.py`, and `librariand`. Because the app is built against the OpenSubsonic spec rather than Navidrome specifics, developing against a laptop instance is functionally identical to developing against the Pi.

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

**c) Deadwax is unblocked, and tracked in its own repo**

The app needs no Pi — it develops against the laptop Navidrome from (a). One
piece of it is worth doing early whatever happens to the app: run the stock
clients (Symfonium, Tempo, Substreamer) against that instance for half an hour,
which either confirms the album-only instinct or saves you from building the
wrong thing. Everything past that lives in `deadwax/docs/plan.md`.

Populate the test library with a few hundred albums if you can — it makes
pagination and scroll assumptions realistic rather than flattering, and it gives
`lint.py` something real to chew on too.

**d) Write `lint.py` (§6.6)**

Pure Python over a directory tree, no server dependency. Run it against the current messy library — it will immediately tell you how much cleanup Phase 1 involves.

**e) Scaffold `librariand` against fake data**

The dashboard, quarantine review, and violations view all work off JSON. Only `/eject` and live rip progress need real hardware.

**f) Do the entire backup flow end to end**

Backblaze account, restic repo, back up a small folder, **and do a restore test**. Practising restore at 2GB is the right order of operations; practising at 300GB is not.

**g) Housekeeping**

- Install Tailscale on phone and laptop, get comfortable with it
- Download the Pi OS Lite 64-bit image
- Git repos initialised, `.gitignore` in place, licence chosen — **`deadwax` is GPL-3.0**; `lathe` stays unlicensed, since it's personal config with your paths in it and isn't for publishing
- Settle the §13 open questions

**Done when:** the Pi arrives and Phase 0–1 is a single evening — plug in, `docker compose up`, rsync the collection into `/srv/inbox/` and let beets file it.

**Blocked until hardware:** NVMe boot, and anything that actually touches
`/dev/sr0` — abcde's real output layout, the MusicBrainz disc-ID lookup, the
read-error patterns, eject, and the udev rule firing on media insertion.

`autorip.sh`, `abcde.conf`, `autorip@.service` and `99-autorip.rules` are
written, and `autorip-test.sh` covers everything downstream of the rip against
a temporary tree: album location, destination naming, collisions, awkward
characters, the atomic-move guard, the JSON log, and the failure paths. The rip
step is stubbed. That is the half where the bugs live and it does not need a
drive; the half that does is small and mostly config.

`inbox-import-test.sh` does the same for the consumer, with beets stubbed and a
local server standing in for both ntfy and Navidrome: the quarantine sweep's
counts, the import summary and its name cap, the rescan request and its
Subsonic token, and the MusicBrainz-outage abort — which cannot be reached in a
live test without taking musicbrainz.org away. It also pins that a broken
notifier never fails an import that already succeeded. What it cannot cover is
beets matching anything, the settle loop against a genuinely in-flight copy, a
real Navidrome accepting `startScan`, and running as `music` at real `/srv`
paths with setgid inboxes — all of which are Phase 1.

### Phase 0 — Base
- Flash Pi OS Lite 64-bit to microSD, boot, update
- Move root filesystem to NVMe, verify boot from NVMe, retire the SD card
- Create `music` user (uid 1001), mount the library drive **at `/srv`** by UUID in `/etc/fstab` (§4), then create the `/srv` tree on it
- **Add your own user to the `music` group, and make `/srv/staging/incoming` and `/srv/inbox` setgid** (`chgrp music`, `chmod 2775`). Uploads arrive owned by you but must be movable and deletable by beets, which runs as `music`. Skipping this makes every upload fail on permissions at import time rather than at copy time, which is a confusing place to find out.
- Install Docker + Compose, Tailscale
- **Done when:** you can SSH in over Tailscale from your phone's hotspot

### Phase 1 — Serving music
- `docker compose up` with Navidrome
- **Migrate the existing collection through `/srv/inbox/`, not into `/srv/music`.** rsync it to `/srv/inbox/`, then run the beets import over it. Beets is what places files in `/srv/music` — see §4. This is also the first real test of the §6.3 config at volume, so expect a meaningful quarantine pile on the first pass and budget an evening for working through it — `librariand/quarantine.py` (§6.5a) is the tool for that evening, and it needs neither `librariand` nor the optical drive.
- Create account, configure transcoding, connect ListenBrainz, then turn `ND_ENABLETRANSCODINGCONFIG` back off
- **Done when:** music plays in a desktop browser and in a stock Subsonic client on your phone over Tailscale

> At this point the system is genuinely useful. Everything after is upgrade.

### Phase 2 — Ripping, manually
- Install `abcde`, `flac`, `cdparanoia`, `beets` and plugins
- Write `/etc/abcde.conf` and beets config
- Rip one CD by hand, import by hand, confirm it lands correctly and appears in Navidrome
- **Done when:** one album has gone disc → library with correct tags and art

### Phase 3 — Automation
- `/srv/inbox/` path unit + `inbox-import.sh` **first** — it is the consumer everything else feeds (settle wait, quarantine sweep, ntfy, Navidrome rescan poke)
- `autorip.sh`, the systemd template unit, the udev rule
- Per-disc logging, error detection, atomic hand-off into `/srv/inbox/`, auto-eject
- `install.sh` — **written**. Copies the repo into the system paths, reloads systemd and udev. From here on it is the only way anything gets deployed; see the copy table in 11.
- Verify the read-error grep patterns in `autorip.sh` against a **deliberately scratched disc**. `autorip-test.sh` stubs the rip, so a pattern that never matches is indistinguishable from a clean rip until a real bad disc proves otherwise.
- `lint.py` (§6.6) + nightly timer
- Rip a real multi-disc set one disc at a time, confirm both discs quarantine, and put them back together with `quarantine.py groups` → `merge` (§6.5a). This is the one path with no automated cover, and it is the path a box set takes every time.
- **Done when:** insert disc, walk away, get a phone notification, album is in the library — and the linter reports zero violations

### Phase 4 — Backups
- restic to Backblaze B2, systemd timer, upload rate capped, scheduled overnight
- Retention policy (`forget --prune`), monthly `check`
- **Done when:** a restore test has actually succeeded — and the first full upload didn't ruin anyone's week

### Phase 5 — Android app
Tracked in the `deadwax` repo, not here. Nothing in this repo blocks it and
nothing in it blocks this repo — it needs only a reachable OpenSubsonic endpoint,
which Phase 1 already provides.
- **Done when:** it's the app you reach for instead of the stock client

### Phase 6 — librariand
- FastAPI service, endpoints above
- Web dashboard: quarantine review, lint violations, rip history
- **Done when:** you can resolve a bad match from your phone

### Phase 7 — v2 features
- `/releases/merge` in `librariand` (§10), if merging box sets by hand gets tiring
- Whatever you actually miss by then
- App-side v2 — offline downloads, Android Auto — is tracked in `deadwax`

---

## 12. Gotchas

- **udev `RUN+=` kills long processes.** Dispatch to systemd. Non-negotiable.
- **Mount the library drive by UUID**, never `/dev/sda1`. Device order changes when you plug in the optical drive.
- **First Navidrome scan of a large library is slow** on a Pi. Let it finish before judging performance.
- **abcde with `-Z` won't tell you loudly about read errors.** That's why per-disc logging is in Phase 3, not optional.
- **Set `ND_SESSIONTIMEOUT` long.** Default logs you out inconveniently often on mobile.
- **beets `incremental: yes` uses a state file** — if you move directories around manually, it gets confused. Let beets own `/srv/music`.
- **HDD spin-down** can cause a 5–10s stall on first play. Either disable it (`hdparm -S 0`) or accept it. For an always-on server, disabling is fine and probably better for drive life than constant spin cycles.
- **Verify the `inline` plugin's `multidisc` expression** before importing a box set, or you'll refile a lot of files twice.
- **`strong_rec_thresh` is a distance, not a confidence.** Raising it loosens matching. Default 0.04, lower is stricter.
- **Never rsync music directly into `/srv/music`.** It bypasses beets, so those albums are invisible to `library.db` and `incremental: yes` will never revisit them. Everything enters via `/srv/inbox/`.
- **Never edit a deployed copy.** `/usr/local/bin/autorip.sh`, `/etc/abcde.conf` and the systemd units are all copies of files in this repo. Editing them in place works, which is the problem: the repo silently stops describing the running system, and the next deploy reverts the fix without warning. Edit here, deploy from here — see §11.
- **Never let `autorip.sh` run beets itself.** The disc ID makes the match easy and inlining the import is tempting, but it duplicates `inbox-import.sh`'s settle wait, quarantine sweep and cleanup, and leaves two beets invocations to drift apart. Rip, move into `/srv/inbox/`, stop.
- **The hand-off into `/srv/inbox/` must be a rename, not a copy.** It only is one while `/srv/staging` and `/srv/inbox` are on the same filesystem. Mount either separately and `mv` silently becomes copy-then-delete, the path unit fires partway through, and albums get imported half-written — the exact failure the atomic move exists to prevent.
- **Never rsync directly into `/srv/inbox/` either.** The path unit fires on the first change, so a long copy gets imported half-finished. Stage in `/srv/staging/incoming/` and move — that's what `push-music.sh` does.
- **`find -newermt "-120 seconds"` is a GNU extension.** Other `find` implementations reject it, and if the error is suppressed the result reads as "nothing changed recently" — so a settle-check built on it silently concludes the copy has finished and imports mid-write. Use a reference file with POSIX `-newer`, and don't suppress the error.

---

## 13. Still open

- **Classical music tagging.** Composer-vs-performer is genuinely hard and beets' defaults handle it poorly. Only worth solving if a meaningful part of the collection is classical.
- **Family access.** Currently single-user. Adding people means either Tailscale invites (easy, requires them to install it) or a public reverse proxy (harder, real threat model change).
- **A VPN on this box, if you ever run one.** Only relevant if you add a torrent client here. Keep any VPN scoped to that client's own container — a full-tunnel VPN on the Pi fights Tailscale for the default route, so a tripped killswitch would cost you access to your own library. `farfetchd`'s repo covers the how; the only thing `lathe` cares about is that Tailscale keeps the default route.
- **UPS.** Whether an unclean shutdown risk to the SQLite DBs justifies $30–60.

---

## 14. Components, repositories, and naming

### There is only one actual service

Worth being precise about this, because it prevents over-splitting:

| Component | What it actually is |
|---|---|
| Ripper | Event-triggered batch job (udev → systemd → script). A producer: it writes files and a log, and nothing else |
| Ingest pipeline | Path-triggered batch job (`inbox.path` → `inbox-import.sh`). The only thing that runs beets |
| Linter | Scheduled batch job |
| `librariand` API | The only long-running HTTP service in this repo |
| Dashboard | A frontend served by `librariand` |
| Deadwax | An Android client |
| Navidrome | Third-party — you write config, not code |

The first four **do not talk over HTTP**. They integrate through the filesystem contract in `/srv`: the ripper writes FLACs into `/srv/inbox/` and a JSON log per disc, the ingest pipeline consumes whatever appears in the inbox, the linter writes `lint.json`, and `librariand` reads all of it. They share a machine, a language, a user account, and a directory layout.

Splitting them into separate repos would make every change to that contract a coordinated multi-repo commit, in exchange for nothing.

### Why the ripper is not its own repo

Asked and settled. The concern worth separating is already separated:
`autorip.sh` cannot reach `library.db`, Navidrome, or `/srv/music` — it writes
to a directory and stops (§6.2). That boundary is enforced by what the script
touches, not by where its source lives, and a repo split would buy exactly the
same isolation while additionally requiring a `rip-contract.md` in the style of
`fetch-contract.md`, a second clone on the Pi, and a two-commit dance every
time the disc-log schema changes.

Nor is a split needed to make ripping optional. A machine with no optical drive
simply doesn't install the udev rule and `abcde.conf`; the other two entry
points are unaffected. An absent file is the cheapest feature flag available.

`farfetchd` is separate for a different reason entirely — it is not part of
this system at all. It is a general-purpose downloader that behaves
identically pointed at a Downloads folder, and it knows nothing about beets,
Navidrome or `/srv`. That is a real boundary by the test in the next
paragraph: a different tool with no requirement to be deployed here.

Revisit if the ripper ever needs to run on a **different machine** than the
library — ripping on a laptop with a better drive, say. A different deployment
target is a real repo boundary; a different subdirectory is not.

### Repositories

**`lathe`** — everything that runs on the Pi.

```
lathe/
  compose/          docker-compose.yml, Navidrome env
  ingest/           autorip.sh, abcde.conf, beets config
  lint/             lint.py
  librariand/        FastAPI service
    quarantine.py   quarantine review + multi-disc merge — CLI and library
    dashboard/      web UI for quarantine + violations
  systemd/          units, timers, udev rules
  docs/             this plan
```

All Python, one deployment target, versioned together.

> **The server is deliberately not called `deadwax-server`.** If Deadwax is published, a matching "server" repo implies the app needs a specific backend — the opposite of the pitch. Deadwax works with any OpenSubsonic server (Navidrome, Gonic, Ampache, LMS); a decoupled name protects that.
>
> `lathe` is the cutting lathe that carves a master lacquer — including the run-out groove the app is named after. It reads as machinery rather than product, which is the right signal for a repo that is mostly config, systemd units, and personal paths rather than anything installable by a stranger.

**`deadwax`** — the album-first Android client. Different language, different toolchain, different release cadence, and the only thing here that might ever be published.

It earns its split for the mirror-image reason to `farfetchd`: not because it is permanently private, but because it is the one part that might not be. It also integrates at the greatest distance of anything in this project — over the OpenSubsonic API, exactly as a third-party client would — so neither repo can constrain the other, and the app stays useful to someone who has never heard of `lathe`.

Its own plan and product constraints live beside it: `docs/plan.md` and `PHILOSOPHY.md`.

**`farfetchd`** — a standalone CLI that downloads a release from a URL into a directory you name. **Private, permanently.**

Not a component of this system, which is the strongest reason for a separate repo in this section. Pointed at `~/Downloads` it is a complete and sensible tool; `output_dir = /srv/staging/fetched` is the only thing that connects it to anything here. It reads no database, serves no HTTP, and would survive this project being deleted.

**How it works is documented in its own repo, and deliberately not here** — what it downloads from, how it is invoked, how it handles torrents, and what it needs from the network are all its business. `lathe`'s side of the boundary is one directory and one sidecar file: `docs/fetch-contract.md`, and nothing more.

It is also the one place a thematic name is affordable, per the conventions below — you type it by hand, and it never appears in a `systemctl status` you are reading at 11pm.

**`opensubsonic-client`** — extracted from `deadwax` **later**, once it stops changing daily, under a generic name rather than a Deadwax-branded one so it's useful to others. Timing and rationale are that repo's business.

The real justification for splitting server from app isn't technical — it's that they have **different publication futures**. The app is the thing you might open-source; the server repo has your paths and your setup in it. Separate repos means "should I publish this?" is answered per-repo rather than per-directory.

A monorepo is also defensible for a solo project and gives you atomic cross-cutting commits. The split is recommended for the publication reason, not a technical one.

### Naming conventions

**Server side: boring and functional.** `autorip`, `lint`, `librariand`. You will be SSH'd in at 11pm reading `systemctl status autorip` — the name should tell you what broke, not require recalling which metaphor maps to which job. Thematic names for infrastructure are a tax paid forever for a joke enjoyed once.

*(This service has had three names, and the reasons are worth keeping because
each rejection sharpened the next one.*

*`ripd` was first, and was wrong for being too narrow: the service covers lint,
library operations and stats as well as rips, so a name built on one of its
jobs would have gone stale the moment it grew.*

*`libraryd` replaced it and was right about scope but wrong about the noun.
Navidrome is the thing that serves the library; this one does operations around
it — quarantine review, lint, rip history, eject. The two sit side by side in
`docker ps`, and `library` was already doing duty for `/srv/music` (§4) and for
beets' `library.db`, so the word was carrying three jobs at once.*

***`librariand` is the name — settled 2026-09-20.** A librarian tends a library
rather than being one, which is exactly the distinction the previous name lost.
It is still boring and functional, which is the rule above; it is just precise
about which boring thing it does. Used consistently throughout this document,
in `docker-compose.yml`, and as the directory in the repo.)*

**App side: Deadwax.** Public-facing, and the name that has to do work. It locks in the Android package ID (permanent once published), the store listing names, and the Subsonic `c=` client identifier — which is the only one of the three that shows up on this side, in Navidrome's logs. The collision check and the runners-up are recorded in the `deadwax` repo.
