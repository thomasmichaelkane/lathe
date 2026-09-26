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

    os.environ.update({
        "SRV": str(srv),
        "QUARANTINE": str(srv / "quarantine"),
        "INBOX": str(srv / "inbox"),
        "FETCHED": str(srv / "staging" / "fetched"),
        "RIP_LOGS": str(srv / "logs" / "rips"),
        "MATCHES": str(srv / "logs" / "matches"),
        "RIPS": str(srv / "staging" / "rips"),
        "MUSIC": str(srv / "music"),
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
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("\n-----------------------------------------")
    print(f"librariand-test: {passed} passed, {failed} failed")
    return 1 if failed else 0


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

    section("the dashboard renders")
    for path, needle in [("/", "librariand"),
                         ("/ui/quarantine", "Quarantine"),
                         # The page title, not a button: by this point the
                         # earlier checks have approved one entry and rejected
                         # another, so which buttons remain depends on state.
                         ("/ui/fetched", "Fetched"),
                         ("/ui/inbox", "Inbox"),
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
    truthy("with tiles named after the tabs", ">Fetched<" in over.text and ">Ripped<" in over.text)
    truthy("and no top-artists table", "Most albums" not in over.text)
    truthy("the inbox tab is present", '/ui/inbox' in over.text)
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
    for path in ("/ui/quarantine", "/ui/fetched", "/ui/inbox", "/ui/rips"):
        truthy(f"but {path} does not repeat it",
               "No token set" not in open_client.get(path).text)
    os.environ["LIBRARIAND_TOKEN"] = TOKEN


if __name__ == "__main__":
    sys.exit(main())
