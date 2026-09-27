#!/usr/bin/env python3
"""Exercise librariand against a fabricated /srv tree.

Driven by librariand-test.sh, which finds an interpreter with FastAPI in it.

Everything here runs against a real temporary /srv: real FLACs with real tags
(so the tag reading is exercised rather than mocked), real fetch.json sidecars,
real rip logs. The only things stubbed are the two that need hardware or a
package manager — `systemctl` and `eject`.

What this deliberately does NOT cover: /quarantine/{id}/resolve actually
importing. That shells out to beets, which would reach MusicBrainz over the
network and rewrite a library. Its argument construction is tested; the import
itself is verified the first time you resolve something real.
"""

from __future__ import annotations

import importlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TOKEN = "test-token-1948"

passed = 0
failed = 0


def ok(msg):
    global passed
    print(f"  \033[32mok\033[0m   {msg}")
    passed += 1


def bad(msg):
    global failed
    print(f"  \033[31mFAIL\033[0m {msg}")
    failed += 1


def check(msg, got, want):
    if got == want:
        ok(msg)
    else:
        bad(f"{msg} (expected {want!r}, got {got!r})")


def truthy(msg, value):
    ok(msg) if value else bad(msg)


def section(name):
    print(f"\n{name}")


# ----------------------------------------------------------------- fixtures

def mkflac(path: Path, album, artist, title, track, disc, disctotal, tracktotal=3):
    path.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi",
           "-i", "anullsrc=r=44100:cl=mono", "-t", "1"]
    for k, v in [("ALBUM", album), ("ARTIST", artist), ("ALBUMARTIST", artist),
                 ("TITLE", title), ("TRACKNUMBER", track), ("DISCNUMBER", disc),
                 ("DISCTOTAL", disctotal), ("TRACKTOTAL", tracktotal)]:
        if v not in (None, ""):
            cmd += ["-metadata", f"{k}={v}"]
    cmd.append(str(path))
    subprocess.run(cmd, check=True, capture_output=True)


def build_srv(srv: Path) -> None:
    q = srv / "quarantine"
    inbox = srv / "inbox"
    fetched_dir = srv / "staging" / "fetched"
    logs = srv / "logs" / "rips"
    music = srv / "music"
    for d in (q, inbox, fetched_dir, logs, music):
        d.mkdir(parents=True, exist_ok=True)

    # A two-disc set, ripped one disc at a time — the case merge exists for.
    for disc in (1, 2):
        for t in (1, 2, 3):
            mkflac(q / f"The Wall (Disc {disc})" / f"0{t} Track {t}.flac",
                   "The Wall", "Pink Floyd", f"Track {t}", t, disc, 2)

    # A Bandcamp single-track download: bare file, no ALBUM tag.
    mkflac(q / "Thornley - Easy.flac", "", "", "Easy", 1, "", "", tracktotal="")

    # A rip that quarantined, referenced by a rip log below.
    for t in (1, 2):
        mkflac(q / "Some Ripped Album" / f"0{t} Track.flac",
               "Some Ripped Album", "Someone", f"Track {t}", t, 1, 1, tracktotal=2)

    # Something already sitting in the inbox, not yet imported.
    (inbox / "Waiting Album").mkdir(parents=True, exist_ok=True)
    mkflac(inbox / "Waiting Album" / "01 Track.flac",
           "Waiting Album", "Someone", "Track 1", 1, 1, 1, tracktotal=1)

    # A beets config and a stub beet, so resolve() reaches its dry-run path
    # instead of failing the environment checks that correctly precede it.
    cfg = srv / "config" / "beets"
    cfg.mkdir(parents=True, exist_ok=True)
    (cfg / "config.yaml").write_text("directory: /srv/music\n", encoding="utf-8")

    # The library, for stats.
    for artist, albums in [("Pink Floyd", ["Animals", "Meddle"]), ("Karenn", ["Grapefruit Regret"])]:
        for alb in albums:
            (music / artist / alb).mkdir(parents=True, exist_ok=True)
            (music / artist / alb / "01 Track.flac").write_bytes(b"x" * 64)

    # --- fetched: one clean, one with failed checks, one unknown schema,
    #     and one still being written (no sidecar at all).
    def drop(fid, sidecar):
        d = fetched_dir / fid
        d.mkdir(parents=True, exist_ok=True)
        (d / "01 Track.flac").write_bytes(b"x" * 1024)
        if sidecar is not None:
            (d / "fetch.json").write_text(json.dumps(sidecar), encoding="utf-8")

    drop("20260819T142305Z-clean", {
        "schema": 2, "id": "20260819T142305Z-clean", "state": "pending_review",
        "source": {"site": "example.bandcamp.com", "adapter": "bandcamp",
                   "url": "https://example.bandcamp.com/album/name"},
        "release": {"artist": "Artist Name", "album": "Good Album",
                    "year": 2024, "track_count": 9, "format": "flac"},
        "files": [{"path": "01 Track.flac", "bytes": 1024}],
        "checks": {"audio_verified": True, "mixed_formats": False,
                   "cover_present": True, "zero_byte_files": []},
        "notes": [],
    })
    drop("20260819T150000Z-dodgy", {
        "schema": 2, "id": "20260819T150000Z-dodgy", "state": "pending_review",
        "source": {"site": "elsewhere", "adapter": "url", "url": "https://x/y"},
        "release": {"artist": "VA", "album": "Suspicious Rip", "format": "mp3"},
        "files": [], "checks": {"audio_verified": False, "mixed_formats": True,
                                "cover_present": False,
                                "zero_byte_files": ["03 Broken.flac"]},
        "notes": ["fell back to mp3 — flac was not offered"],
    })
    drop("20260819T160000Z-future", {"schema": 99, "id": "x", "release": {}})
    drop("20260819T170000Z-inflight", None)

    # --- rip logs, one per outcome the module has to derive.
    def riplog(disc_id, status, handoff, album, detail=None, errors=False):
        (logs / f"{disc_id}.json").write_text(json.dumps({
            "schema": 1, "disc_id": disc_id, "device": "/dev/sr0",
            "finished_at": f"2026-09-1{disc_id[-1]}T10:00:00Z",
            "status": status, "detail": detail, "handoff_path": handoff,
            "artist": "Someone", "album": album, "track_count": 2,
            "read_errors": errors, "raw_log": "/srv/logs/rips/x.log",
        }), encoding="utf-8")

    riplog("discid1", "ok", "/srv/inbox/Gone Album", "Gone Album")
    riplog("discid2", "ok", "/srv/inbox/Some Ripped Album", "Some Ripped Album")
    riplog("discid3", "failed", None, None, detail="abcde exited 1")
    riplog("discid4", "ok", "/srv/inbox/Waiting Album", "Waiting Album")
    riplog("discid5", "ok", "/srv/inbox/Scratchy", "Scratchy", errors=True)

    # --- match records, as the quarantine_match beets plugin writes them.
    # Both passes judged the rip; MusicBrainz came closer. The Bandcamp file
    # was tried and found nothing anywhere. The Wall has no record at all —
    # quarantined before the plugin existed.
    matches = srv / "logs" / "matches"
    matches.mkdir(parents=True, exist_ok=True)
    slot = {"at": "2026-09-26T18:00:00+0100", "candidates": 3,
            "recommendation": "low", "artist": "Someone",
            "album": "Some Ripped Album", "year": 2019, "label": None,
            "id": "cc531207-6efd-4e7d-a9cf-3a196aea64bf",
            "url": "https://musicbrainz.org/release/cc531207-6efd-4e7d-a9cf-3a196aea64bf",
            "tracks": 3, "matched_tracks": 2, "extra_items": 0,
            "missing_tracks": 1, "penalties": ["missing tracks"]}
    (matches / "Some Ripped Album.json").write_text(json.dumps({"sources": {
        "musicbrainz": {**slot, "similarity": 91.3},
        "bandcamp": {**slot, "similarity": 62.0,
                     "url": "https://someone.bandcamp.com/album/x"},
    }}), encoding="utf-8")
    none = {"at": "2026-09-26T18:00:00+0100", "candidates": 0,
            "recommendation": "none"}
    (matches / "Thornley - Easy.flac.json").write_text(json.dumps(
        {"sources": {"musicbrainz": none, "bandcamp": none}}), encoding="utf-8")


# ------------------------------------------------------------- fake aria2

class FakeAria2:
    """Just enough of aria2's JSON-RPC to drive torrents.py, advanced by hand.

    Shaped on a real aria2 1.37 run (2026-09-26): a magnet is a metadata
    download with no `bittorrent.info`, which completes and is `followedBy`
    the real one; the payload lands in <dir>/<info.name>/ with a `.aria2`
    control file beside it until the download completes.
    """

    SECRET = "test-secret"

    def __init__(self):
        import http.server
        import threading
        self.rows: dict[str, dict] = {}
        self.n = 0
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                params = req["params"]
                if params[:1] != [f"token:{fake.SECRET}"]:
                    body, code = {"error": {"code": 1, "message": "Unauthorized"}}, 400
                else:
                    try:
                        body = {"result": getattr(fake, req["method"].split(".")[1])(*params[1:])}
                        code = 200
                    except KeyError:
                        body, code = {"error": {"code": 1, "message": "GID not found"}}, 400
                data = json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}/jsonrpc"

    def _gid(self):
        self.n += 1
        return f"{self.n:016x}"

    # --- RPC methods
    def getVersion(self):
        return {"version": "fake"}

    def addUri(self, uris, opts):
        gid = self._gid()
        self.rows[gid] = {"gid": gid, "status": "active", "dir": opts["dir"],
                          "totalLength": "0", "completedLength": "0",
                          "downloadSpeed": "0", "connections": "2",
                          "magnet": uris[0], "seed": opts.get("seed-time"),
                          "follow": opts.get("follow-torrent")}
        return gid

    def _tell(self, statuses):
        return [{k: v for k, v in r.items() if k != "magnet"}
                for r in self.rows.values() if r["status"] in statuses]

    def tellActive(self, keys):
        return self._tell({"active"})

    def tellWaiting(self, offset, num, keys):
        return self._tell({"waiting", "paused"})

    def tellStopped(self, offset, num, keys):
        return self._tell({"complete", "error", "removed"})

    def forceRemove(self, gid):
        self.rows[gid]["status"] = "removed"
        return gid

    def removeDownloadResult(self, gid):
        del self.rows[gid]
        return "OK"

    # --- test controls
    def tick(self):
        """Advance every download one step: metadata -> 50% -> complete."""
        for r in list(self.rows.values()):
            if r["status"] != "active":
                continue
            if "bittorrent" not in r:
                r["status"] = "complete"
                gid = self._gid()
                r["followedBy"] = [gid]
                self.rows[gid] = {"gid": gid, "status": "active", "dir": r["dir"],
                                  "totalLength": "1000", "completedLength": "500",
                                  "downloadSpeed": "100", "connections": "3",
                                  "bittorrent": {"info": {"name": "Tick Album"}}}
                album = Path(r["dir"]) / "Tick Album"
                album.mkdir(parents=True, exist_ok=True)
                mkflac(album / "01 Tick.flac", "Tick Album", "Ticker", "Tick", 1, 1, 1)
                (album / "01 Tick.flac.aria2").write_bytes(b"ctl")
            else:
                r["status"], r["completedLength"] = "complete", r["totalLength"]
                for ctl in Path(r["dir"]).rglob("*.aria2"):
                    ctl.unlink()

    def fail(self):
        for r in self.rows.values():
            if r["status"] == "active":
                r["status"], r["errorMessage"] = "error", "No peers found"


class FakeGluetun:
    """gluetun's two public control-server routes, with a switchable state."""

    def __init__(self):
        import http.server
        import threading
        self.status = "running"
        fake = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                body = ({"status": fake.status} if self.path == "/v1/vpn/status"
                        else {"public_ip": "185.107.56.1"})
                data = json.dumps(body).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"


MAGNET = ("magnet:?xt=urn:btih:40b43013f9d149afa64f59239bf9688eb938b193"
          "&dn=Test+Album&tr=http%3A%2F%2Ftracker.example%2Fannounce")
MAGNET2 = MAGNET.replace("40b43013", "50b43013").replace("Test+Album", "Second")


# --------------------------------------------------------------------- main

def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="librariand-test-"))
    srv = tmp / "srv"
    bin_dir = tmp / "bin"
    bin_dir.mkdir(parents=True)

    # Stubs for the two things that need hardware or root.
    (bin_dir / "systemctl").write_text(
        "#!/bin/sh\n"
        "case \"$*\" in *is-active*inbox.path*) echo active;; "
        "*list-units*) : ;; esac\nexit 0\n")
    (bin_dir / "eject").write_text("#!/bin/sh\necho ejected \"$@\"\nexit 0\n")
    # Never actually invoked: every resolve test below is a dry run, and the
    # stub exists only so shutil.which() finds something.
    (bin_dir / "beet").write_text("#!/bin/sh\necho 'stub beet' >&2\nexit 0\n")
    for f in bin_dir.iterdir():
        f.chmod(0o755)

    build_srv(srv)
    aria2 = FakeAria2()
    gluetun = FakeGluetun()

    os.environ.update({
        "SRV": str(srv),
        "QUARANTINE": str(srv / "quarantine"),
        "INBOX": str(srv / "inbox"),
        "FETCHED": str(srv / "staging" / "fetched"),
        "RIP_LOGS": str(srv / "logs" / "rips"),
        "MATCHES": str(srv / "logs" / "matches"),
        "TORRENTS": str(srv / "staging" / "torrents"),
        "ARIA2_RPC": aria2.url,
        "ARIA2_SECRET": FakeAria2.SECRET,
        "GLUETUN_URL": gluetun.url,
        "RIPS": str(srv / "staging" / "rips"),
        "MUSIC": str(srv / "music"),
        "LATHE_RELEASE": str(tmp / "lathe-release"),
        "BEETS_CONFIG": str(srv / "config" / "beets" / "config.yaml"),
        "BEET_CMD": str(bin_dir / "beet"),
        "LIBRARIAND_TOKEN": TOKEN,
        "SYSTEMCTL": str(bin_dir / "systemctl"),
        "EJECT_CMD": str(bin_dir / "eject"),
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
    })

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import app as app_mod
    importlib.reload(app_mod)
    from fastapi.testclient import TestClient

    client = TestClient(app_mod.app)
    auth = {"Authorization": f"Bearer {TOKEN}"}

    try:
        run_checks(client, auth, srv)
        run_torrent_checks(client, auth, srv, aria2)
        run_vpn_checks(client, auth, srv, gluetun)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\n-----------------------------------------")
    print(f"librariand-test: {passed} passed, {failed} failed")
    return 1 if failed else 0


def run_torrent_checks(client, auth, srv: Path, aria2: FakeAria2):
    import torrents as torrents_mod
    torrents_dir = srv / "staging" / "torrents"
    listed = lambda: client.get("/torrents", headers=auth).json()  # noqa: E731

    section("fetch — adding")
    check("junk is refused", client.post("/torrents", headers=auth,
          json={"link": "not a link"}).status_code, 400)
    check("as is a non-web URL", client.post("/torrents", headers=auth,
          json={"link": "ftp://example.com/x.torrent"}).status_code, 400)
    check("a magnet with no info hash is refused", client.post(
          "/torrents", headers=auth, json={"link": "magnet:?dn=x"}).status_code, 400)
    r = client.post("/torrents", headers=auth, json={"link": MAGNET}).json()
    truthy("a magnet is accepted", r["ok"])
    tid = r["id"]
    row = next(iter(aria2.rows.values()))
    check("into its own directory", row["dir"], str(torrents_dir / tid))
    check("with seeding off", row["seed"], "0")
    r = client.post("/torrents", headers=auth, json={"link": MAGNET}).json()
    check("adding the same magnet again returns the same download", r["id"], tid)
    check("without a second aria2 job", len(aria2.rows), 1)
    check("following a .torrent from memory, never onto disk", row["follow"], "mem")

    section("fetch — progress")
    l = listed()
    truthy("aria2 is reported reachable", l["aria2"])
    t = l["torrents"][0]
    check("a new magnet is finding metadata", t["state"], "metadata")
    check("named from the magnet meanwhile", t["name"], "Test Album")
    page = client.get("/ui/fetch", headers=auth).text
    truthy("the page offers the + button", 'data-action="add-open"' in page)
    truthy("and polls while it is active", 'data-active="1"' in page)
    truthy("and says what it is doing", "Finding the torrent" in page)

    aria2.tick()
    t = listed()["torrents"][0]
    check("then downloads, as the real torrent", t["state"], "downloading")
    check("named from the torrent itself", t["name"], "Tick Album")
    check("at 50%", t["progress"], 50.0)
    check("with an ETA", t["eta_seconds"], 5)
    check("nothing is ready to move yet", torrents_mod.ready_count(), 0)
    r = client.post(f"/torrents/{tid}/move", headers=auth)
    check("moving it early is refused", r.status_code, 409)
    truthy("and moves nothing", (torrents_dir / tid).is_dir())

    aria2.tick()
    t = listed()["torrents"][0]
    check("then completes", t["state"], "complete")
    check("counting its audio", t["audio_files"], 1)
    page = client.get("/ui/fetch", headers=auth).text
    truthy("the finished card offers the move", 'data-action="move"' in page)
    truthy("and stops polling", 'data-active="1"' not in page)
    check("it counts as ready to move", torrents_mod.ready_count(), 1)
    truthy("in the Fetch nav badge", re.search(
        r'href="/ui/fetch"[^>]*>Fetch\s*<span class="count ?">(\d+)', page) is not None)

    section("fetch — moving")
    r = client.post(f"/torrents/{tid}/move", headers=auth).json()
    truthy("a finished download moves", r["ok"])
    truthy("into the inbox under the torrent's name",
           (srv / "inbox" / "Tick Album" / "01 Tick.flac").is_file())
    check("leaving nothing behind in staging", (torrents_dir / tid).exists(), False)
    check("and clearing aria2's record of it", len(aria2.rows), 0)
    r = client.post(f"/torrents/{tid}/move", headers=auth).json()
    truthy("pressing it again is harmless", r["ok"] and "already" in r["detail"])

    section("fetch — .torrent links")
    url = "https://archive.org/download/some-album/Some%20Album_archive.torrent"
    r = client.post("/torrents", headers=auth, json={"link": url}).json()
    truthy("a .torrent URL is accepted", r["ok"])
    turl = r["id"]
    row = next(r for r in aria2.rows.values() if r["dir"].endswith(turl))
    check("and handed to aria2 as-is, not fetched here", row["magnet"], url)
    t = listed()["torrents"][0]
    check("named from the file meanwhile", t["name"], "Some Album_archive")
    check("waiting on the .torrent like a magnet's metadata", t["state"], "metadata")
    r = client.post("/torrents", headers=auth, json={"link": url}).json()
    check("the same URL twice is one download", r["id"], turl)
    aria2.tick()
    t = listed()["torrents"][0]
    check("then downloads as the torrent it named", (t["state"], t["name"]),
          ("downloading", "Tick Album"))
    client.delete(f"/torrents/{turl}", headers=auth)
    check("and cancels like any other", listed()["torrents"], [])

    section("fetch — failure, resume, cancel")
    tid2 = client.post("/torrents", headers=auth, json={"link": MAGNET2}).json()["id"]
    aria2.fail()
    t = listed()["torrents"][0]
    check("a failed download says so", t["state"], "error")
    check("with aria2's reason", t["error"], "No peers found")
    r = client.post(f"/torrents/{tid2}/resume", headers=auth).json()
    truthy("it can be resumed", r["ok"])
    check("which re-submits it", listed()["torrents"][0]["state"], "metadata")
    r = client.post(f"/torrents/{tid2}/resume", headers=auth).json()
    check("resuming a live download is a no-op", r["detail"], "already downloading")

    aria2.rows.clear()  # aria2 restarted with no session
    check("a download aria2 forgot is interrupted",
          listed()["torrents"][0]["state"], "interrupted")

    r = client.delete(f"/torrents/{tid2}", headers=auth).json()
    truthy("cancel deletes it", r["ok"] and not (torrents_dir / tid2).exists())
    r = client.delete(f"/torrents/{tid2}", headers=auth).json()
    truthy("cancelling again is harmless", r["ok"])
    truthy("a traversal id is refused",
           client.delete("/torrents/..%2F..%2Fetc", headers=auth).status_code >= 400)
    check("as is any id that is not one of ours",
          client.post("/torrents/inbox/move", headers=auth).status_code, 400)

    section("fetch — aria2 down")
    good = os.environ["ARIA2_RPC"]
    torrents_mod.ARIA2_RPC = "http://127.0.0.1:9/jsonrpc"
    try:
        check("the list says aria2 is down", listed()["aria2"], False)
        r = client.post("/torrents", headers=auth, json={"link": MAGNET})
        check("adding fails", r.status_code, 400)
        truthy("saying where it looked", "127.0.0.1:9" in r.json()["detail"])
        truthy("and leaves no directory behind", not any(torrents_dir.iterdir()))
        page = client.get("/ui/fetch", headers=auth).text
        truthy("the page shows a banner", "aria2 is not reachable" in page)
    finally:
        torrents_mod.ARIA2_RPC = good


def run_vpn_checks(client, auth, srv: Path, gluetun: FakeGluetun):
    import torrents as torrents_mod

    section("fetch — secret from file")
    secret_file = srv.parent / "aria2_rpc_secret"
    secret_file.write_text(FakeAria2.SECRET + "\n")
    env_secret = os.environ.pop("ARIA2_SECRET")
    torrents_mod.ARIA2_SECRET_FILE = secret_file
    try:
        truthy("the secret is read from its file", client.get(
            "/torrents", headers=auth).json()["aria2"])
        secret_file.write_text("wrong")
        truthy("and a wrong one is refused by aria2", not client.get(
            "/torrents", headers=auth).json()["aria2"])
    finally:
        os.environ["ARIA2_SECRET"] = env_secret

    section("fetch — VPN")
    v = client.get("/torrents", headers=auth).json()["vpn"]
    truthy("a running VPN is up", v["up"])
    check("with its exit IP", v["ip"], "185.107.56.1")
    page = client.get("/ui/fetch", headers=auth).text
    truthy("the Fetch page says it is connected", "VPN connected" in page)
    truthy("and the overview stays quiet",
           "VPN down" not in client.get("/", headers=auth).text)

    gluetun.status = "stopped"
    v = client.get("/torrents", headers=auth).json()["vpn"]
    check("a stopped VPN is down", v["up"], False)
    truthy("the Fetch page says so", "VPN down" in client.get("/ui/fetch", headers=auth).text)
    truthy("and so does the overview", "VPN down" in client.get("/", headers=auth).text)

    good = torrents_mod.GLUETUN_URL
    torrents_mod.GLUETUN_URL = "http://127.0.0.1:9"
    try:
        v = client.get("/torrents", headers=auth).json()["vpn"]
        check("gluetun not answering counts as down", v["up"], False)
        torrents_mod.GLUETUN_URL = ""
        check("with no VPN configured, nothing is claimed",
              client.get("/torrents", headers=auth).json()["vpn"], None)
        truthy("and no VPN line is shown",
               "VPN" not in client.get("/ui/fetch", headers=auth).text)
    finally:
        torrents_mod.GLUETUN_URL = good
        gluetun.status = "running"


def run_checks(client, auth, srv: Path):
    section("auth")
    check("an unauthenticated API call is refused", client.get("/health").status_code, 401)
    check("a bad token is refused",
          client.get("/health", headers={"Authorization": "Bearer wrong"}).status_code, 401)
    check("a good token is accepted", client.get("/health", headers=auth).status_code, 200)
    r = client.get("/", follow_redirects=False)
    check("an unauthenticated page redirects to the login form", r.status_code, 307)
    check("and points at /login", r.headers.get("location"), "/login")
    check("the login form renders", client.get("/login").status_code, 200)
    r = client.post("/login", data={"token": TOKEN}, follow_redirects=False)
    check("a correct token logs in", r.status_code, 303)
    truthy("and sets the cookie", "librariand" in r.cookies or
           any("librariand=" in v for v in r.headers.get_list("set-cookie")))
    check("a wrong token does not", client.post("/login", data={"token": "no"},
                                                follow_redirects=False).status_code, 401)

    section("health")
    h = client.get("/health", headers=auth).json()
    check("reports /srv is not a mount point", h["srv_mounted"], False)
    truthy("reports disk usage", "total" in h["disk"])
    check("counts quarantine entries", h["pending"]["quarantine"], 4)
    check("counts fetched awaiting review", h["pending"]["fetched"], 3)
    check("counts the inbox", h["pending"]["inbox"], 1)
    # The failed rip and the one with read errors. A rip that quarantined
    # is no longer counted here — that is Quarantine's business now.
    check("counts rips needing attention", h["rips_needing_attention"], 2)
    truthy("names the last successful rip", h["last_successful_rip"] is not None)

    section("release")
    rel_file = Path(os.environ["LATHE_RELEASE"])
    r = client.get("/health", headers=auth).json()["release"]
    check("with no stamp, no version is claimed", r["version"], None)
    over = client.get("/", headers=auth).text
    truthy("and the overview says it was not deployed by install.sh",
           "not deployed by install.sh" in over)

    # Exactly what install.sh writes.
    rel_file.write_text("VERSION=0.1.0\nCOMMIT=abc1234\n", encoding="utf-8")
    r = client.get("/health", headers=auth).json()["release"]
    check("the stamp's version is reported", r["version"], "0.1.0")
    check("with its commit", r["commit"], "abc1234")
    truthy("and when it was deployed", r["deployed_at"] is not None)
    truthy("the overview shows it", "lathe 0.1.0" in client.get("/", headers=auth).text)

    # Past a tag, the version already contains the commit; don't print it twice.
    rel_file.write_text("VERSION=0.1.0-3-gdef5678\nCOMMIT=def5678\n", encoding="utf-8")
    over = client.get("/", headers=auth).text
    truthy("an untagged deploy says so", "lathe 0.1.0-3-gdef5678" in over)
    truthy("without repeating the commit", "· def5678" not in over)

    section("stats")
    s = client.get("/stats", headers=auth).json()
    check("counts albums from the library layout", s["albums"], 3)
    check("counts artists", s["artists"], 2)
    check("counts rips", s["rips_total"], 5)
    check("ranks artists by album count", s["top_artists"][0]["artist"], "Pink Floyd")

    section("quarantine")
    q = client.get("/quarantine", headers=auth).json()["entries"]
    check("lists everything quarantined", len(q), 4)
    names = {e["name"] for e in q}
    truthy("including the loose Bandcamp file", "Thornley - Easy.flac" in names)
    disc1 = next(e for e in q if e["name"] == "The Wall (Disc 1)")
    check("reads album tags", disc1["tags"]["album"], "The Wall")
    check("reads disc numbers", disc1["tags"]["disc"], 1)
    truthy("explains why each entry is stuck", any(e["notes"] for e in q))

    ripped = next(e for e in q if e["name"] == "Some Ripped Album")
    check("carries beets' best candidate", ripped["match"]["best"]["source"], "musicbrainz")
    check("the closer of the two passes", ripped["match"]["best"]["similarity"], 91.3)
    loose = next(e for e in q if e["name"] == "Thornley - Easy.flac")
    truthy("a record with no candidates is still a record", loose["match"] is not None)
    check("but has no best candidate", loose["match"]["best"], None)
    check("an entry with no record has no match", disc1["match"], None)

    import quarantine as quarantine_mod
    (srv / "logs" / "matches" / "Renamed.json").write_text(
        json.dumps({"sources": {"musicbrainz": {"similarity": 50.0}}}))
    truthy("a collision-suffixed entry finds its record",
           quarantine_mod.read_match("Renamed.20260926120000") is not None)

    page = client.get("/ui/quarantine", headers=auth).text
    truthy("a card is titled by its album tag", "<h3>Some Ripped Album</h3>" in page)
    truthy("and an untagged one by a stand-in", "<h3>Import " in page)
    truthy("the similarity is shown", "91%" in page)
    truthy("coloured by beets' thresholds", 'class="score warn"' in page)
    truthy("the missing label is marked missing", 'class="missing">missing<' in page)
    truthy("and missing tracks are called out", "1 missing" in page)
    truthy("a record with no candidates says so", "no candidates found" in page)
    truthy("an entry with no record says so", "no match recorded" in page)

    truthy("tracks are counted from the files' side",
           "2 of your 2 files fit" in page and "release has 3" in page)

    # #38: a box set beets matched to the standard edition. The old card led
    # with "4 of 4", which read as a strong match wrongly refused.
    big = srv / "quarantine" / "Box Set"
    for t in range(1, 11):
        mkflac(big / ("CD 1" if t <= 4 else "CD 2") / f"{t:02d} T.flac",
               "Box Set", "Someone", f"T{t}", t, 1 if t <= 4 else 2, 2, tracktotal=10)
    (srv / "logs" / "matches" / "Box Set.json").write_text(json.dumps({"sources": {
        "musicbrainz": {"similarity": 71.0, "artist": "Someone", "album": "Box Set",
                        "tracks": 4, "matched_tracks": 4, "extra_items": 6,
                        "missing_tracks": 0, "penalties": ["unmatched tracks"]}}}))
    page = client.get("/ui/quarantine", headers=auth).text
    at = page.index("<h3>Box Set</h3>")
    card = page[at:]
    card = card[:card.index('<div class="card')] if '<div class="card' in card else card
    truthy("an oversized folder says how few of its files fit",
           "4 of your 10 files fit" in card and "release has 4" in card)
    truthy("and explains that a plain retry will not help",
           "plain retry will land here again" in card)
    shutil.rmtree(big)
    (srv / "logs" / "matches" / "Box Set.json").unlink()

    g = client.get("/quarantine/groups", headers=auth).json()["groups"]
    check("groups the two discs into one release", len(g), 1)
    check("with both members", len(g[0]["members"]), 2)
    truthy("and marks the set complete", g[0]["complete"])

    r = client.post("/quarantine/merge", headers=auth,
                    json={"entries": g[0]["members"], "dry_run": True}).json()
    truthy("a dry-run merge reports a plan", r["ok"])
    check("and moves nothing", len(list((srv / "quarantine").iterdir())), 4)

    section("quarantine — actions")
    r = client.post("/quarantine/Thornley - Easy.flac/retry", headers=auth).json()
    truthy("retry hands an entry back to the inbox", r["ok"])
    truthy("the file really moved", (srv / "inbox" / "Thornley - Easy.flac").exists())
    check("and left quarantine", (srv / "quarantine" / "Thornley - Easy.flac").exists(), False)

    r = client.delete("/quarantine/Some Ripped Album", headers=auth).json()
    truthy("delete removes an entry", r["ok"])
    check("from disk", (srv / "quarantine" / "Some Ripped Album").exists(), False)
    check("along with its match record",
          (srv / "logs" / "matches" / "Some Ripped Album.json").exists(), False)

    r = client.post("/quarantine/..%2F..%2Fetc/retry", headers=auth)
    truthy("a path-traversal name is refused", r.status_code >= 400 or
           r.json().get("ok") is False)

    # The one that mattered: a bare "..", percent-encoded so no client
    # normalises it away. It used to resolve to /srv itself, and DELETE would
    # have removed the library.
    for label, call in (
        ("DELETE", lambda: client.delete("/quarantine/%2E%2E", headers=auth)),
        ("retry", lambda: client.post("/quarantine/%2E%2E/retry?dry_run=true",
                                      headers=auth)),
        ("resolve", lambda: client.post(
            "/quarantine/%2E%2E/resolve", headers=auth,
            json={"identifier": "1a2b3c4d-1a2b-1a2b-1a2b-1a2b3c4d5e6f",
                  "dry_run": True})),
    ):
        r = call()
        truthy(f"{label} of '..' is refused", r.status_code >= 400 and
               r.json().get("ok") is False)
    truthy("and /srv is still all there", (srv / "quarantine").is_dir()
           and (srv / "inbox").is_dir())

    section("quarantine — resolve")
    r = client.post("/quarantine/The Wall (Disc 1)/resolve", headers=auth,
                    json={"identifier": "not-an-id"})
    check("a junk identifier is rejected", r.status_code, 400)
    r = client.post("/quarantine/The Wall (Disc 1)/resolve", headers=auth,
                    json={"identifier": "https://example.com/album",
                          "dry_run": True})
    check("a non-Bandcamp URL is rejected", r.status_code, 400)
    r = client.post("/quarantine/The Wall (Disc 1)/resolve", headers=auth,
                    json={"identifier": "c9b6b2e0-1111-2222-3333-444455556666",
                          "dry_run": True}).json()
    check("a MusicBrainz UUID selects the MusicBrainz source", r["source"], "musicbrainz")
    truthy("and disables bandcamp for that pass", "-P bandcamp" in r["command"])
    r = client.post("/quarantine/The Wall (Disc 1)/resolve", headers=auth,
                    json={"identifier": "https://x.bandcamp.com/album/y",
                          "dry_run": True}).json()
    check("a Bandcamp URL selects the Bandcamp source", r["source"], "bandcamp")
    truthy("and disables musicbrainz for that pass", "-P musicbrainz" in r["command"])

    # #40: the whole address from musicbrainz.org, as it is actually copied.
    r = client.post("/quarantine/The Wall (Disc 1)/resolve", headers=auth,
                    json={"identifier": "https://musicbrainz.org/release/"
                          "C9B6B2E0-1111-2222-3333-444455556666?tab=tracks",
                          "dry_run": True}).json()
    check("a musicbrainz.org release link is accepted", r.get("source"), "musicbrainz")
    truthy("and beets is given just the ID",
           "--search-id c9b6b2e0-1111-2222-3333-444455556666 " in r.get("command", ""))
    r = client.post("/quarantine/The Wall (Disc 1)/resolve", headers=auth,
                    json={"identifier": "https://musicbrainz.org/release-group/"
                          "c9b6b2e0-1111-2222-3333-444455556666", "dry_run": True})
    check("a release-group link is refused", r.status_code, 400)
    truthy("saying it is the album, not an edition",
           "release group" in r.json()["detail"] and "/release/" in r.json()["detail"])
    r = client.post("/quarantine/The Wall (Disc 1)/resolve", headers=auth,
                    json={"identifier": "https://musicbrainz.org/artist/"
                          "c9b6b2e0-1111-2222-3333-444455556666", "dry_run": True})
    check("as is an artist link", r.status_code, 400)

    # A real run, against a stub beet that does what beets does on a match:
    # moves the AUDIO out and leaves everything else. The entry holding only
    # an Edition Info.txt and a folder.jpg afterwards used to be reported as
    # "did not match" (#41).
    import resolve as resolve_mod
    bin_dir = srv.parent / "bin"
    moving = bin_dir / "beet-moves-audio"
    moving.write_text(
        "#!/bin/sh\n"
        "for last; do :; done\n"
        f"mkdir -p '{srv}/music/Imported'\n"
        f"find \"$last\" -name '*.flac' -exec mv {{}} '{srv}/music/Imported/' \\;\n")
    silent = bin_dir / "beet-matches-nothing"
    silent.write_text("#!/bin/sh\nexit 0\n")
    offline = bin_dir / "beet-offline"
    offline.write_text("#!/bin/sh\necho 'musicbrainz: Error: Max retries exceeded'\n")
    for f in (moving, silent, offline):
        f.chmod(0o755)

    def entry(name):
        d = srv / "quarantine" / name
        mkflac(d / "01 One.flac", name, "Someone", "One", 1, 1, 1, tracktotal=1)
        (d / "Edition Info.txt").write_text("ripped by someone")
        (d / "folder.jpg").write_bytes(b"\xff\xd8")
        return d

    real_beet = resolve_mod.BEET
    uuid = {"identifier": "c9b6b2e0-1111-2222-3333-444455556666"}
    try:
        resolve_mod.BEET = str(moving)
        d = entry("Leftovers Album")
        r = client.post("/quarantine/Leftovers Album/resolve", headers=auth, json=uuid)
        check("an import that leaves clutter behind is a success", r.status_code, 200)
        truthy("reported as imported", r.json().get("ok") is True)
        truthy("naming what it cleared", "Edition Info.txt" in r.json()["detail"])
        check("and the leftover entry is gone, not a blank card", d.exists(), False)

        resolve_mod.BEET = str(silent)
        d = entry("Unmatched Album")
        r = client.post("/quarantine/Unmatched Album/resolve", headers=auth, json=uuid)
        check("a real non-match is still a 409", r.status_code, 409)
        truthy("and says to check it is a release, not a release group",
               "not the release group" in r.json()["detail"])
        truthy("and leaves the entry exactly as it was",
               (d / "01 One.flac").exists() and (d / "folder.jpg").exists())

        resolve_mod.BEET = str(offline)
        r = client.post("/quarantine/Unmatched Album/resolve", headers=auth, json=uuid)
        truthy("an unreachable MusicBrainz is reported as such",
               r.status_code == 400 and "could not reach" in r.json()["detail"])
        shutil.rmtree(d)
    finally:
        resolve_mod.BEET = real_beet

    section("fetched")
    f = client.get("/fetched", headers=auth).json()["entries"]
    check("lists only finished downloads", len(f), 3)
    ids = {e["id"] for e in f}
    check("ignoring one with no fetch.json yet",
          "20260819T170000Z-inflight" in ids, False)
    clean = next(e for e in f if e["id"].endswith("clean"))
    truthy("a clean download is marked clean", clean["clean"])
    check("and carries the claimed release", clean["release"]["album"], "Good Album")
    dodgy = next(e for e in f if e["id"].endswith("dodgy"))
    truthy("failed checks become readable warnings", len(dodgy["warnings"]) >= 3)
    truthy("including unverified audio",
           any("did not verify" in w for w in dodgy["warnings"]))
    future = next(e for e in f if e["id"].endswith("future"))
    check("an unknown sidecar schema is refused, not guessed at",
          future["readable"], False)
    truthy("and says why", "schema" in (future["problem"] or ""))

    section("fetched — actions")
    r = client.post("/fetched/20260819T142305Z-clean/approve", headers=auth).json()
    truthy("approve reports success", r["ok"])
    truthy("and the directory is now in the inbox",
           (srv / "inbox" / "20260819T142305Z-clean").is_dir())
    check("and gone from fetched",
          (srv / "staging" / "fetched" / "20260819T142305Z-clean").exists(), False)
    truthy("with the sidecar carried along",
           (srv / "inbox" / "20260819T142305Z-clean" / "fetch.json").is_file())

    r = client.post("/fetched/20260819T150000Z-dodgy/reject", headers=auth).json()
    truthy("reject reports success", r["ok"])
    check("and deletes the download",
          (srv / "staging" / "fetched" / "20260819T150000Z-dodgy").exists(), False)

    check("approving something that does not exist fails",
          client.post("/fetched/nope/approve", headers=auth).json()["ok"], False)

    section("rips")
    data = client.get("/rips", headers=auth).json()
    rs = {r["disc_id"]: r for r in data["entries"]}
    check("history is complete", len(rs), 5)

    # A rip log reports the rip and nothing else. Where the album ended up is
    # Quarantine's question, and an inference from absence here degraded over
    # time — see the rips.py docstring.
    truthy("a clean rip reports passed", rs["discid1"]["passed"])
    check("and nothing about where the album went",
          "outcome" in rs["discid1"], False)
    check("a failed rip reports failed", rs["discid3"]["passed"], False)
    truthy("with the reason", "abcde exited" in (rs["discid3"]["detail"] or ""))
    truthy("read errors are flagged", rs["discid5"]["read_errors"])
    truthy("and count as needing attention even on a rip that passed",
           rs["discid5"]["passed"] and rs["discid5"]["needs_attention"])
    check("a clean rip needs no attention", rs["discid1"]["needs_attention"], False)
    check("no rip is in progress", data["current"], None)

    # autorip.sh works in $RIPS/.work/<disc id>.<pid>; the old lookup read
    # the top of $RIPS and so only ever reported ".work".
    busy = srv.parent / "bin" / "systemctl-ripping"
    busy.write_text("#!/bin/sh\n"
                    "echo 'autorip@sr0.service loaded active running Auto-rip'\n")
    busy.chmod(0o755)
    work = srv / "staging" / "rips" / ".work" / "abcDEF-123_.4242"
    work.mkdir(parents=True)
    import rips as rips_mod   # SYSTEMCTL is read once, at import
    real = rips_mod.SYSTEMCTL
    rips_mod.SYSTEMCTL = str(busy)
    try:
        cur = client.get("/rips", headers=auth).json()["current"]
    finally:
        rips_mod.SYSTEMCTL = real
    shutil.rmtree(work.parent)
    check("a running rip names its device", cur and cur["device"], "sr0")
    check("and the work directory under .work", cur and cur["working_dir"],
          "abcDEF-123_.4242")
    check("and the disc it is reading", cur and cur["disc_id"], "abcDEF-123_")

    page = client.get("/ui/rips", headers=auth)
    truthy("the log shows pass/fail", "passed" in page.text and "failed" in page.text)
    truthy("and no inbox/quarantine state", "in the inbox" not in page.text.lower())

    # The API keeps /eject — it is in §10, and a POST with a token is a
    # deliberate act. The dashboard deliberately does NOT offer a button: a
    # tray opened by a mis-tap on a phone stays open, with the disc exposed,
    # until someone walks over to it.
    r = client.post("/eject", headers=auth, json={"device": "sr0"}).json()
    truthy("the eject endpoint still works", r["ok"])
    for path in ("/", "/ui/rips"):
        truthy(f"but {path} offers no eject button",
               'data-action="eject"' not in client.get(path, headers=auth).text)
    check("an invalid device is refused",
          client.post("/eject", headers=auth,
                      json={"device": "../sda"}).json()["ok"], False)

    section("inbox")
    # Three by now, and not by accident: the fixture's own "Waiting Album",
    # plus the entry retry() put back and the download approve() moved in.
    # That those two actions really land here is the point.
    items = client.get("/inbox", headers=auth).json()["entries"]
    names = {i["name"] for i in items}
    check("lists everything waiting to import", len(items), 3)
    truthy("including the fixture's own", "Waiting Album" in names)
    truthy("the entry retry() handed back", "Thornley - Easy.flac" in names)
    truthy("and the download approve() moved in",
           "20260819T142305Z-clean" in names)
    truthy("nothing just-arrived counts as stuck",
           not any(i["stale"] for i in items))
    # Everything arrives by rename, which keeps the files' old mtimes. An
    # album last touched in 2019 has still only just arrived.
    old = srv / "inbox" / "Waiting Album"
    os.utime(old, (1546300800, 1546300800))
    item = next(i for i in client.get("/inbox", headers=auth).json()["entries"]
                if i["name"] == "Waiting Album")
    truthy("an old album moved in just now is not stuck", not item["stale"])

    before = sorted(p.name for p in (srv / "inbox").iterdir())
    r = client.post("/inbox/nudge", headers=auth).json()
    truthy("a nudge starts the import", r["ok"])
    r = client.post("/inbox/nudge", headers=auth).json()
    truthy("and pressing it again is harmless", r["ok"])
    check("leaving the inbox exactly as it was",
          sorted(p.name for p in (srv / "inbox").iterdir()), before)

    down = srv.parent / "bin" / "systemctl-down"
    down.write_text("#!/bin/sh\necho inactive\nexit 3\n")
    down.chmod(0o755)
    real = os.environ["SYSTEMCTL"]
    os.environ["SYSTEMCTL"] = str(down)
    r = client.post("/inbox/nudge", headers=auth)
    os.environ["SYSTEMCTL"] = real
    check("with the watcher down, a nudge is refused", r.status_code, 409)
    truthy("and says how to fix it", "enable --now inbox.path" in r.json()["detail"])

    section("the dashboard renders")
    for path, needle in [("/", "librariand"),
                         ("/ui/quarantine", "Quarantine"),
                         # The page title, not a button: by this point the
                         # earlier checks have approved one entry and rejected
                         # another, so which buttons remain depends on state.
                         ("/ui/fetch", "Fetch"),
                         ("/ui/rips", "Result")]:
        resp = client.get(path, headers=auth)
        check(f"{path} returns 200", resp.status_code, 200)
        truthy(f"{path} contains its content", needle.lower() in resp.text.lower())

    resp = client.get("/ui/quarantine", headers=auth)
    truthy("quarantine page offers an ID field", "data-resolve-for" in resp.text)
    truthy("beside a single retry button", 'data-action="retry"' in resp.text
           and 'data-action="resolve"' not in resp.text)
    truthy("and the nav carries live counts", 'class="count' in resp.text)
    # One flat list: no group section heading, and the merge action rides on
    # the member cards instead.
    truthy("the list is flat, with no group subsection",
           "Looks like one release" not in resp.text)
    truthy("a mergeable set still offers merge", 'data-action="merge"' in resp.text)
    truthy("issues are colour-coded", 'class="card live"' in resp.text
           or 'class="card warn"' in resp.text)

    over = client.get("/", headers=auth)
    truthy("the overview calls the section Pipeline", ">Pipeline<" in over.text)
    truthy("and the drive section Optical drive", "Optical drive" in over.text)
    truthy("with tiles named after the tabs", ">Fetch<" in over.text and ">Ripped<" in over.text)
    truthy("and no top-artists table", "Most albums" not in over.text)
    truthy("there is no inbox tab", '/ui/inbox' not in over.text)
    check("or inbox page", client.get("/ui/inbox", headers=auth).status_code, 404)
    truthy("a non-empty inbox turns its tile", 'class="tile stuck"' in over.text)
    truthy("which offers the nudge", 'data-action="nudge"' in over.text)
    truthy("and says how long the oldest has waited", "oldest" in over.text)
    truthy("static assets are served", client.get("/static/style.css").status_code == 200)

    section("no-token mode")
    os.environ["LIBRARIAND_TOKEN"] = ""
    import app as app_mod
    importlib.reload(app_mod)
    from fastapi.testclient import TestClient as TC
    open_client = TC(app_mod.app)
    check("with no token set, the API is open", open_client.get("/health").status_code, 200)
    page = open_client.get("/")
    check("and pages load without logging in", page.status_code, 200)
    truthy("the overview says so", "No token set" in page.text)
    # Banners are overview-only. Repeated on every tab, a warning stops being
    # read by the third page.
    for path in ("/ui/quarantine", "/ui/fetch", "/ui/rips"):
        truthy(f"but {path} does not repeat it",
               "No token set" not in open_client.get(path).text)
    os.environ["LIBRARIAND_TOKEN"] = TOKEN


if __name__ == "__main__":
    sys.exit(main())
