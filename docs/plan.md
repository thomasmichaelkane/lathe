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
| Scrobbling | **ListenBrainz** | Open, no account lock-in; Navidrome supports it natively |
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
  quarantine/       # beets could not confidently match these
  inbox/            # manual drops: Bandcamp, purchases, existing collection
  config/
    navidrome/      # SQLite DB, cache
    beets/          # config.yaml, library.db
    ripd/           # custom service config
  logs/
    rips/           # one log per disc, named by MusicBrainz disc ID
    beets-import.log
```

**Rule: nothing writes to `/srv/music` except beets.** This is what keeps the library clean. Everything else stages.

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

  ripd:
    build: ./ripd
    container_name: ripd
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
  quiet_fallback: skip     # <-- the safety valve
  incremental: yes
  log: /srv/logs/beets-import.log

match:
  strong_rec_thresh: 0.10   # only auto-accept high-confidence matches
  max_rec:
    missing_tracks: low
    unmatched_tracks: low

plugins: fetchart replaygain scrub lastgenre missing edit inline

# Used below to split multi-disc sets into one release per disc.
item_fields:
  multidisc: 1 if disctotal > 1 else 0

paths:
  default: $albumartist/$album%aunique{}%if{$multidisc, (Disc $disc)}/$track $title
  comp: Various Artists/$album%aunique{}%if{$multidisc, (Disc $disc)}/$track $title
  singleton: $artist/$title/01 $title

fetchart:
  auto: yes
  cautious: yes
  sources: filesystem coverart itunes albumart
  filename: cover        # always cover.jpg — one image, one name

replaygain:
  auto: yes
  backend: ffmpeg

scrub:
  auto: yes
```

**`quiet_fallback: skip` is the critical line.** Anything beets isn't confident about is left where it is rather than guessed at. `autorip.sh` then sweeps leftovers from `/srv/staging/rips/` into `/srv/quarantine/` for later review.

### The library rules these paths enforce

1. **One release = one folder.** Never nested, never split.
2. **A folder contains audio tracks and exactly one `cover.jpg`.** Nothing else.
3. **No embedded artwork.** `embedart` is deliberately absent from the plugin list. The image lives once, on disk, and Navidrome serves it via `getCoverArt`.
4. **Multi-disc sets become one release per disc** — `Album (Disc 1)`, `Album (Disc 2)`. This preserves rule 1 at the cost of splitting a conceptual release; `ripd` gets a merge endpoint later (§10) to stitch them back together at the presentation layer.
5. **Singles are one-track releases**, foldered like everything else.

The `multidisc` field comes from the `inline` plugin — verify the expression evaluates correctly on your beets version before ripping a box set.

**Deliberately not using the `chroma` (AcoustID fingerprinting) plugin.** It's slow on ARM and CDs have a reliable disc ID already. Add it later only for the `/srv/inbox/` path where files arrive without disc IDs.

### 6.4 Notify

At the end of `autorip.sh`:

1. Eject the disc (physical signal that it's done).
2. POST to Navidrome's rescan endpoint so the album appears immediately.
3. Push via **ntfy** — self-hosted or ntfy.sh with a random topic. Message: album name, track count, and whether it went to library or quarantine.

### 6.5 The non-CD path

`/srv/inbox/` is watched by a systemd path unit. Anything dropped there (Bandcamp downloads, existing collection, purchases) gets the same beets import with the same quarantine behaviour. One ingest pipeline, two entry points.

### 6.6 Library hygiene

The rules in §6.3 are only real if something checks them. `lint.py` runs nightly via systemd timer and on demand via `ripd`.

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

Output as JSON to `/srv/logs/lint.json`, served by `ripd` at `GET /library/violations` and rendered in the dashboard.

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
| Scrobble | `scrobble` (`submission=false` on start, `true` past 50%) |

**Deliberately unused:** `getPlaylists`, `getPlaylist`, `createPlaylist`, `updatePlaylist`, `deletePlaylist`, `getRandomSongs`.

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

## 10. Custom service (`ripd`)

FastAPI. Reachable only over Tailscale. Simple bearer token on top of that.

| Method | Path | Does |
|---|---|---|
| GET | `/health` | Disk free, drive presence, last successful rip |
| GET | `/rips` | Rip history with status and error flags |
| GET | `/rips/current` | Live progress of an in-flight rip |
| GET | `/events` | SSE stream of rip progress |
| GET | `/quarantine` | Albums beets couldn't match, with candidate matches |
| POST | `/quarantine/{id}/resolve` | Apply a chosen MusicBrainz release ID, re-run beets import |
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

**Set up a laptop mirror of the server.** Run Navidrome in Docker locally, pointed at a folder of existing music. Two minutes of work, and it becomes the development target for everything else. Because the app is built against the OpenSubsonic spec rather than Navidrome specifics, developing against a laptop instance is functionally identical to developing against the Pi.

**a) Tune beets — highest value, do this first**

The fiddliest config in the plan and the one most likely to bite. Install beets locally, point it at a **copy** of existing music (never the original), and iterate until:

- Path templates produce exactly the folder structure in §6.3
- The `inline` plugin's `multidisc` expression actually evaluates — verify before trusting it
- `quiet_fallback: skip` leaves unmatched albums where you expect
- `fetchart` writes a single `cover.jpg` and nothing is embedded
- ReplayGain via ffmpeg completes without errors

Discovering a broken template now costs an afternoon. Discovering it after 200 CDs costs a re-file of the entire library.

**b) Validate the app concept before building it**

Run the stock clients — Symfonium, Tempo, Substreamer — against local Navidrome for half an hour. Either this confirms the album-only instinct or it saves you from building the wrong thing. Then study Longplay properly and sketch the seven screens.

**c) Start the Android app (Phase 5 work, fully unblocked)**

The largest single chunk in the plan, and it needs no Pi:

- Expo dev build scaffold, RNTP wired up, audio playing at all
- The Subsonic client module: salted-token auth, `js-md5`, capability detection via `getOpenSubsonicExtensions`
- SQLite schema + Drizzle, sync logic
- Shelf and Release screens against local Navidrome

Populate the test library with a few hundred albums if you can, so pagination and scroll performance assumptions are realistic rather than flattering.

**d) Write `lint.py` (§6.6)**

Pure Python over a directory tree, no server dependency. Run it against the current messy library — it will immediately tell you how much cleanup Phase 1 involves.

**e) Scaffold `ripd` against fake data**

The dashboard, quarantine review, and violations view all work off JSON. Only `/eject` and live rip progress need real hardware.

**f) Do the entire backup flow end to end**

Backblaze account, restic repo, back up a small folder, **and do a restore test**. Practising restore at 2GB is the right order of operations; practising at 300GB is not.

**g) Housekeeping**

- Install Tailscale on phone and laptop, get comfortable with it
- Download the Pi OS Lite 64-bit image
- Git repos initialised, `.gitignore` in place, licence chosen
- Settle the §13 open questions — especially offline v1-vs-v2, since it shapes the app you're starting in (c)

**Done when:** the Pi arrives and Phase 0–1 is a single evening — plug in, `docker compose up`, rsync the library across.

**Blocked until hardware:** NVMe boot, the udev rule, `autorip.sh`, `/etc/abcde.conf`, anything touching `/dev/sr0`.

### Phase 0 — Base
- Flash Pi OS Lite 64-bit to microSD, boot, update
- Move root filesystem to NVMe, verify boot from NVMe, retire the SD card
- Create `music` user (uid 1001), create `/srv` tree, mount library drive by UUID in `/etc/fstab`
- Install Docker + Compose, Tailscale
- **Done when:** you can SSH in over Tailscale from your phone's hotspot

### Phase 1 — Serving music
- `docker compose up` with Navidrome
- Copy existing music into `/srv/music`
- Create account, configure transcoding, connect ListenBrainz
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
- `/srv/inbox/` path unit for non-CD ingest
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

### Phase 6 — ripd
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

---

## 13. Still open

- **Offline downloads: v1 or v2?** Planned as v2. Moving it to v1 roughly doubles app scope but makes the app usable on planes and subways from the start.
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
| `libraryd` API | The only long-running HTTP service |
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

**`opensubsonic-client`** — extracted from the app **later**, once it stops changing daily. Give it a generic name rather than a Deadwax-branded one so it's useful to others.

> **Don't extract the client library early.** Live with `src/subsonic/` inside the app repo, enforce the no-UI-imports rule from day one, and pull it out when it's stable. Premature extraction means npm-linking and a version bump for every fix, during exactly the phase when you're changing it constantly.

The real justification for splitting server from app isn't technical — it's that they have **different publication futures**. The app is the thing you might open-source; the server repo has your paths and your setup in it. Separate repos means "should I publish this?" is answered per-repo rather than per-directory.

A monorepo is also defensible for a solo project and gives you atomic cross-cutting commits. The split is recommended for the publication reason, not a technical one.

### Naming conventions

**Server side: boring and functional.** `autorip`, `lint`, `libraryd`. You will be SSH'd in at 11pm reading `systemctl status autorip` — the name should tell you what broke, not require recalling which metaphor maps to which job. Thematic names for infrastructure are a tax paid forever for a joke enjoyed once.

*(§10 originally called the API service `ripd`. Since it now covers lint, library operations and stats as well as rips, `libraryd` is the more accurate name. Either is fine — pick one and be consistent.)*

**App side: Deadwax.** Public-facing, and the name that has to do work.

Three things it locks in:

- **Android package ID** — `io.github.<username>.deadwax` (free, no domain needed). Effectively permanent once published.
- **Subsonic `c=` parameter** — `Deadwax`. This is the client identifier on every API call, so it appears in Navidrome's logs and in the logs of any other server if you release it.
- **Repo, F-Droid, and Play listing names.**

**Collision check — partial.** Clear on GitHub, npm, F-Droid, and Google Play. **Not clear conceptually:** at least two vinyl-collection apps named Deadwax exist on iOS (Discogs collection managers / pressing identification), and `deadwax.app`, `deadwax.io` and `deadwaxhq.com` are all taken. Also adjacent: **DeaDBeeF**, an open-source audio player since 2009.

Irrelevant for a personal Android project. If this is ever published, expect to be the third or fourth Deadwax in the music space and to spend effort distinguishing yourself. Runners-up that avoid the collector-app space entirely: **Gatefold**, **Spindle**, **Lacquer**.

**Lock in early:** register the GitHub repos. For the Android package ID, use `io.github.<username>.deadwax` — free, conventional, maps to a namespace you control, and preferred by F-Droid. The package ID cannot be changed after publishing — decide it deliberately rather than typing something provisional into `app.json`.
