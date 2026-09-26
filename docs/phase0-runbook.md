# Phase 0 runbook — base system on the Pi

The command-level version of §11 Phase 0. The plan says *what* and *why*; this
says *what to type*, in an order where nothing depends on a step that has not
happened yet.

Read §11 Phase 0 first if you want the reasoning. It is not repeated here.

**Before starting:** `badblocks` must have finished with
`Pass completed, 0 bad blocks found. (0/0/0 errors)`. Anything else and the
drive goes back to CEX on the warranty instead — do not partition it.

Run through this in one sitting if you can. Steps 1–4 are the ones that are
awkward to undo; everything after is repeatable.

---

## 0. Confirm the scan actually finished clean

```sh
tmux capture-pane -p -t badblocks | tail -5
cat ~/badblocks-sda.txt        # must be empty
```

An empty output file means no bad blocks were found. The summary line is what
decides it — a count of zero partway through is not a result.

---

## 1. Identify the drive

**This is the step that matters.** Everything in §2 destroys whatever it is
pointed at, and there is no undo.

```sh
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS
```

You are looking for the **3.6T Seagate on `TRAN=usb`**. For reference, on this
machine:

| Device | What it is |
|---|---|
| `mmcblk0` | the microSD you are booted from — **never this one** |
| `nvme0n1` | the NVMe in the Argon case, if fitted — not this one either |
| `sda` | the library drive, 3.6T, USB |

It still carries the previous owner's 128M Windows reserved partition and an
NTFS `sda2`. Seeing those is confirmation you have the right disk.

Pin it to a variable and check it twice:

```sh
DISK=/dev/sda

lsblk -dno SIZE,MODEL,TRAN "$DISK"     # expect: 3.6T  Expansion Desktop  usb
lsblk -no MOUNTPOINTS "$DISK"          # expect: nothing. If anything is
                                       # mounted, stop and unmount it first.
```

If the size or the transport is not what you expect, stop. `/dev/sd*` ordering
is not stable — this is the same reason §12 insists on mounting by UUID.

---

## 2. Wipe and partition

```sh
sudo apt install -y gdisk

sudo wipefs -a "$DISK"                 # clears the NTFS/Windows signatures
sudo sgdisk --zap-all "$DISK"          # clears both GPT and the legacy MBR
sudo sgdisk --new=1:0:0 --typecode=1:8300 --change-name=1:music "$DISK"
sudo partprobe "$DISK"

lsblk "$DISK"                          # expect a single partition, 3.6T
```

One partition spanning the disk. There is no reason to split it — `/srv` is one
filesystem on purpose (§4).

---

## 3. Format

```sh
sudo mkfs.ext4 -m 0 -L music "${DISK}1"
```

`-m 0` is worth understanding rather than copying. ext4 reserves 5% of the
filesystem for root by default, which stops a full disk from locking out system
daemons. On a 3.6TB drive that is **about 180GB set aside for a root process
that will never write here** — nothing on this drive is system-critical, so the
reserve is pure loss. `-m 0` reclaims it.

---

## 4. Mount it at `/srv`, by UUID

```sh
UUID=$(sudo blkid -s UUID -o value "${DISK}1")
echo "$UUID"                           # sanity check — should not be empty

sudo mkdir -p /srv

echo "UUID=$UUID  /srv  ext4  defaults,noatime,nofail,x-systemd.device-timeout=30  0  2" \
  | sudo tee -a /etc/fstab
```

Two options here are not decoration:

- **`nofail`** — without it, a drive that fails to enumerate at boot drops the
  Pi to an emergency console **with no network**. On a headless machine that
  means finding a monitor and keyboard. With it, the Pi boots fine and `/srv`
  is simply missing, which you can diagnose over SSH.
- **`x-systemd.device-timeout=30`** — caps how long boot waits for a USB drive
  that is not coming back. The default is 90 seconds of hanging.

**Verify before you trust it:**

```sh
sudo findmnt --verify --verbose        # parses fstab, reports errors
sudo systemctl daemon-reload
sudo mount -a
findmnt /srv                           # expect /dev/sda1 mounted at /srv
df -h /srv                             # expect ~3.6T, nearly all free
```

**Then reboot once, deliberately, while you are still sitting next to it:**

```sh
sudo reboot
# ... wait, then from your laptop:
ssh tom@lathe 'findmnt /srv && df -h /srv'
```

Finding out that an fstab entry is wrong is much better now than in a month.

---

## 5. Create the `music` user

```sh
sudo groupadd -g 1948 music
sudo useradd -u 1948 -g 1948 --system --no-create-home \
     --home-dir /srv --shell /usr/sbin/nologin music

id music                               # expect uid=1948(music) gid=1948(music)
```

**The numbers are load-bearing.** `compose/docker-compose.yml` runs Navidrome as
`user: "1948:1948"` and the systemd units run as `music`. If the uid or gid
comes out different, the container writes files the services cannot read.

---

## 6. Add yourself to the `music` group

```sh
sudo usermod -aG music tom

# log out and back in, then:
id -nG                                 # must include: music
```

**Why you need it.** You upload as `tom`; beets runs as `music` and has to
**move and delete** those files, not merely read them. The matching half — the
setgid bits on `inbox/` and `staging/incoming/`, which make an uploaded file
group-owned by `music` in the first place — is applied by `install.sh` in step 9,
along with the directories themselves.

This is the one piece of Phase 0 `install.sh` deliberately does not do: which
groups a human account belongs to is your business, not a deploy script's.

**You must log out and back in.** Group membership is baked into your session at
login; until you reconnect, your shell still has the old list and any test you
run will fail confusingly.

---

## 7. Docker

```sh
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker tom

# log out and back in, then:
docker compose version
```

---

## 8. Tailscale

```sh
curl -fsSL https://tailscale.com/install.sh | sudo sh
sudo tailscale up
tailscale ip -4
```

`tailscale up` prints a URL to authenticate with. The Pi is headless, so open
it on a laptop.

**Then disable key expiry for this node** — admin console, Machines, `lathe`,
the `...` menu. Tailscale node keys expire after 180 days by default. On a
laptop that is a re-login; on a headless server it means the library silently
drops off the tailnet six months from now, and fixing it needs local access to
the machine you have just lost remote access to. It is a two-click setting and
there is no good reason to leave it on for a server.

---

## 9. Clone and deploy

```sh
sudo apt install -y git python3-venv ffmpeg
git clone https://github.com/thomasmichaelkane/lathe.git ~/lathe
cd ~/lathe
git checkout 0.1.0                     # a release, not main — see "Upgrading" below

sudo ./install.sh --dry-run            # read this before running it for real
sudo ./install.sh

cat /etc/lathe-release                 # VERSION=0.1.0
sudo -u music beets-check.sh           # beets 2.13.1: all 11 plugins loaded
```

**Do not install beets yourself** — not from apt, not with `uv tool install`.
`install.sh` installs it, pinned, into `/usr/local/lib/beets` with `beet` on
the default PATH, so the importer (which runs as `music`) and librariand both
find the same one. A per-user install lands in your home directory, which the
`music` user can neither see on its PATH nor, on Debian, enter at all.

- `python3-venv` is for the two venvs `install.sh` builds, beets and
  librariand — the only steps that need the network.
- `ffmpeg` is for beets' ReplayGain, which runs on **every** import, not just
  rips. Without it the replaygain plugin silently fails to load.

`install.sh` finishes by running `beets-check.sh` as `music`, and exits non-zero
if any plugin the config asks for did not load. That check exists because beets
itself does not fail: it drops the plugin, prints a traceback, and imports
anyway with exit status 0.

**This also builds the `/srv` tree** — the §4 directories, owned by `music`,
with setgid on `inbox/` and `staging/incoming/`. It is idempotent, so re-running
it later is free.

**It will refuse to run if `/srv` is not a mount point.** That is deliberate:
`nofail` in your fstab means "booted fine, drive absent" is an ordinary state,
and deploying in it would write the beets config onto the microSD underneath
the mountpoint, where the drive hides it the moment it returns.

From here on, **`install.sh` is the only thing that writes to a system path**
(§11, §12). Never edit a deployed copy — edit here and re-run.

### Upgrading, later

Releases are tags in `0.1.0` form, cut from `main` on the laptop:

```sh
git tag 0.2.0 && git push origin 0.2.0
```

GitHub Actions runs every test suite on that tag and publishes the release only
if they pass. Then, on the Pi:

```sh
cd ~/lathe
git fetch --tags
git checkout 0.2.0                     # detached HEAD, on purpose: the Pi runs exactly a release
sudo ./install.sh --dry-run
sudo ./install.sh
docker compose -f compose/docker-compose.yml up -d   # only matters if compose changed; a no-op otherwise
cat /etc/lathe-release
```

**Rolling back is the same with an older tag** — `git checkout 0.1.0 && sudo
./install.sh`. It works because a deploy only ever replaces code: `/srv`, the
databases and `/etc/default/lathe` are never touched, so going back loses
nothing.

What `install.sh` takes care of on an upgrade, so you don't have to:

- **librariand's dependencies.** Rebuilt whenever `librariand/requirements.txt`
  changed, and retried on the next run if the install fails.
- **New settings.** Your `/etc/default/lathe` is never overwritten, so it
  names any setting the new release has that your file lacks. Add those by hand.
- **Local edits.** It refuses to deploy a checkout with local changes — the
  deploy globs directories, so a stray file would ship as part of the release.
  `--allow-dirty` overrides it if you really mean it.

**What version is running?** `cat /etc/lathe-release`, or the bottom of
librariand's overview. That file is written only after a deploy finishes, so it
records what is deployed — `git describe` in `~/lathe` only tells you what is
checked out, which differs if you checked out a tag and never ran `install.sh`.

---

## 10. Fill in `/etc/default/lathe`

`install.sh` just created it, empty, 0600, root-owned.

```sh
sudo nano /etc/default/lathe
```

Set `NTFY_URL` to a long random ntfy topic if you want phone pushes. Leave the
`NAVIDROME_*` values until Phase 1 has created the account. Everything in there
is optional — unset means that step is skipped and logged, never that an import
fails.

---

## 11. Done when

```sh
findmnt /srv                           # mounted, from the UUID entry
id music                               # 1948:1948
ls -ld /srv/inbox                      # drwxrwsr-x, music:music (set by install.sh)
systemctl is-enabled inbox.path        # enabled
sudo ./install.sh --dry-run            # "0 file(s) would change"
```

and you can SSH in over Tailscale from your phone's hotspot.

Then Phase 1: `docker compose -f compose/docker-compose.yml up -d`, and push the
collection in with `ingest/push-music.sh` — **not** rsync straight into
`/srv/inbox/`, for the reason in §12.

---

## If it goes wrong

Until Phase 1 puts music on it, this drive holds nothing. Steps 2–4 can be
repeated from scratch at any point with no loss. The only genuinely risky
mistake is pointing §2 at the wrong device, which is why §1 checks twice.

And the standing rule, which does not change until Phase 4:
**do not delete any original copy of your music until a restore test has
actually succeeded.** That is what made accepting an unreadable SMART status
reasonable in the first place.
