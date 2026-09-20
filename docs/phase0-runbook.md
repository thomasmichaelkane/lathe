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
sudo groupadd -g 1001 music
sudo useradd -u 1001 -g 1001 --system --no-create-home \
     --home-dir /srv --shell /usr/sbin/nologin music

id music                               # expect uid=1001(music) gid=1001(music)
```

**The numbers are load-bearing.** `compose/docker-compose.yml` runs Navidrome as
`user: "1001:1001"` and the systemd units run as `music`. If the uid or gid
comes out different, the container writes files the services cannot read.

---

## 6. Create the `/srv` tree — *after* mounting, not before

```sh
findmnt /srv || echo "STOP: /srv is not mounted"

sudo mkdir -p /srv/music /srv/quarantine /srv/inbox
sudo mkdir -p /srv/staging/rips /srv/staging/fetched /srv/staging/incoming
sudo mkdir -p /srv/config/navidrome /srv/config/beets /srv/config/librariand
sudo mkdir -p /srv/logs/rips
```

Order matters and the failure is silent. Build the tree first and mount over it
and the directories are still *there* — on the microSD, hidden underneath the
mount, invisible and slowly filling the boot media. Everything looks correct
until the SD card runs out of space.

---

## 7. Ownership and the setgid bits

```sh
sudo chown -R music:music /srv
sudo chmod 755 /srv

sudo usermod -aG music tom
sudo chmod 2775 /srv/inbox /srv/staging/incoming

ls -ld /srv/inbox /srv/staging/incoming    # expect drwxrwsr-x ... music music
```

The `s` in `drwxrwsr-x` is the setgid bit, and it is the whole point: you upload
as `tom`, beets runs as `music` and has to **move and delete** those files, not
just read them. Without this, every upload fails at import time rather than at
copy time — a confusing place to find out.

**Log out and back in** before testing, or your shell still has the old group
list. `id -nG` should include `music`.

---

## 8. Docker

```sh
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker tom

# log out and back in, then:
docker compose version
```

---

## 9. Tailscale

```sh
curl -fsSL https://tailscale.com/install.sh | sudo sh
sudo tailscale up
tailscale ip -4
```

---

## 10. Clone and deploy

```sh
sudo apt install -y git
git clone https://github.com/thomasmichaelkane/lathe.git ~/lathe
cd ~/lathe

sudo ./install.sh --dry-run            # read this before running it for real
sudo ./install.sh
```

From here on, **`install.sh` is the only thing that writes to a system path**
(§11, §12). Never edit a deployed copy — edit here and re-run.

An update later is:

```sh
cd ~/lathe && git pull && sudo ./install.sh
```

---

## 11. Fill in `/etc/default/lathe`

`install.sh` just created it, empty, 0600, root-owned.

```sh
sudo nano /etc/default/lathe
```

Set `NTFY_URL` to a long random ntfy topic if you want phone pushes. Leave the
`NAVIDROME_*` values until Phase 1 has created the account. Everything in there
is optional — unset means that step is skipped and logged, never that an import
fails.

---

## 12. Done when

```sh
findmnt /srv                           # mounted, from the UUID entry
id music                               # 1001:1001
ls -ld /srv/inbox                      # drwxrwsr-x, music:music
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
