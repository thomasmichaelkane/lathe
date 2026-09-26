# Torrents: the Fetch tab, aria2 and the VPN

librariand's **Fetch** tab downloads torrents: press **+**, paste a magnet or a
`.torrent` link, watch it progress, and press **Move to inbox** when it is done.
The inbox imports it like anything else.

Behind the tab are two containers from `compose/docker-compose.yml`, both
opt-in under the `torrents` profile:

- **gluetun** holds a WireGuard tunnel to Proton VPN, pinned to Proton's P2P
  servers.
- **aria2** does the downloading. It has no network of its own: it lives
  inside gluetun's. If the tunnel drops, gluetun's firewall stops aria2's
  traffic instead of letting it fall back to your home connection.

The VPN covers these two containers and nothing else (plan §13). The Pi's own
routing, Tailscale and Navidrome are untouched, so a VPN problem cannot cut you
off from your library. Nothing here can stop the Pi booting.

Decisions, and why (2026-09-26):

- **Proton VPN** (via Proton Unlimited). Torrenting is only allowed on paid
  plans, and only on Proton's P2P servers.
- **No seeding.** A download stops the moment its data verifies (`seed-time=0`
  in `compose/aria2/run.sh`, and on every download librariand submits).
- **aria2**, because farfetchd already speaks it and it is light on 4GB.

## Setting it up

You need the code on the Pi first: this lives in `install.sh` and compose, so
pull a release that includes it.

1. **Run the installer once.**

       sudo ./install.sh

   It creates `/etc/lathe/secrets/` and generates aria2's RPC secret there.
   It reports `absent  WireGuard key`, which is expected at this point.

2. **Get your WireGuard key from Proton.**
   - Sign in at [account.protonvpn.com](https://account.protonvpn.com).
   - **Downloads → WireGuard configuration.**
   - Platform **Linux**. Leave **NAT-PMP (port forwarding) off**, since it
     only matters for seeding. Pick any server marked **P2P**. gluetun chooses
     its own server, so this choice only produces the key.
   - Proton shows a config file. You need one value from it: the
     `PrivateKey = …` line, which is about 44 characters ending in `=`.

   The key is a credential. It never goes in git, chat or a screenshot.

3. **Put the key on the Pi.** Use an editor, so the key does not land in your
   shell history:

       sudo nano /etc/lathe/secrets/wireguard_private_key

   Paste **only the key**: not `PrivateKey =`, and not the rest of the config.
   Save and exit. The file name is exactly `wireguard_private_key`, with no
   extension.

4. **Re-run the installer.**

       sudo ./install.sh

   It tightens the key to `0600 root` and now reports `present  WireGuard key`.

5. **Start the pair.**

       docker compose -f compose/docker-compose.yml --profile torrents up -d

   The first run builds the aria2 image, which takes a minute. aria2 waits
   until gluetun reports healthy before it starts.

6. **Check it.** Open librariand's **Fetch** tab. It should say
   **VPN connected · exit <an IP>**, and that IP should be Proton's, not
   yours. librariand turns the VPN line on by itself once the key file
   exists; there is nothing to configure.

## Using it

- **+** opens the link field. Paste a magnet or a `.torrent` URL and press
  Enter. Pasting the same link twice gives you the same card, not a second
  download.
- A `.torrent` URL is fetched by aria2 inside the VPN, never by librariand,
  so the site hosting it does not see your home IP.
- While a card is working it shows **%, size, speed, peers and time left**,
  and refreshes itself every few seconds.
- **"Finding the torrent's details"** means nobody has sent the torrent's
  metadata yet. Some magnets never get past this; their swarm has no one
  sharing it. Cancel, and try the `.torrent` link if the site offers one.
  The Internet Archive's magnets behave like this, and its `.torrent` links
  work.
- At 100% the card waits for **Move to inbox**. Moving is a single rename into
  `/srv/inbox`, so the importer sees the album appear all at once.
- If a finished download contains **no audio** (e.g. only a `.zip`), the card
  warns you before you move it. beets cannot import a zip, so it would land in
  quarantine.

## When something is wrong

| What you see | What it means |
|---|---|
| **VPN down** banner (Fetch and overview) | gluetun is not connected, or not running. Downloads are paused, not leaking. `docker logs gluetun` says why. |
| Downloads sit at **0%** with peers found | Almost always a non-P2P Proton server. `PORT_FORWARD_ONLY: "on"` in compose is what prevents this; check it is still there. |
| **aria2 is not reachable** banner | The aria2 container is down: `docker compose --profile torrents ps`, `docker logs aria2`. Finished downloads can still be moved meanwhile. |
| gluetun keeps restarting | Usually a wrong or incomplete key. Re-copy just the `PrivateKey` value into the file, then `docker compose --profile torrents up -d`. |
| A card says **Interrupted** | aria2 restarted and lost track of the download. **Resume** carries on from where it stopped. |

## How it fits together

- Downloads go to `/srv/staging/torrents/<id>/`, one directory per download,
  with a small `.librariand.json` record. The container mounts this at the
  **same path** it has on the host. librariand tells aria2 where to write by
  absolute path, so a different mountpoint would mean downloads librariand
  never sees.
- aria2's RPC (`127.0.0.1:6800`) and gluetun's status routes (`127.0.0.1:8000`)
  are published on the Pi's localhost only.
  - gluetun's control server opens exactly two read-only routes
    (`compose/gluetun/auth.toml`). The ones that change settings or stop the
    VPN stay locked.
  - aria2's RPC needs the secret in `/etc/lathe/secrets/aria2_rpc_secret`
    (`0640 root:music`). The container and librariand both read it.
- Both containers keep their state on the library drive, not the SD card:
  `/srv/config/gluetun` and `/srv/config/aria2`.
- To **rotate** a secret: delete the file, re-run `sudo ./install.sh` (for the
  aria2 one) or paste a new key (for WireGuard), then
  `docker compose --profile torrents up -d`.
- To **stop** torrents entirely:
  `docker compose --profile torrents down`. Navidrome is unaffected.
