#!/usr/bin/env python3
"""librariand — the one long-running service in this repo (§10, §14).

Everything else here is a batch job: the ripper fires on a udev event, the
importer on a path unit, the linter on a timer. This serves the views and the
actions those jobs cannot: what is stuck in quarantine and why, what a
downloader fetched that you have not looked at yet, and what happened to each
disc you put in the drive.

It is a thin skin. The quarantine logic lives in `quarantine.py`, which is a
working CLI in its own right and is imported here rather than shelled out to —
§10 is explicit about that, because the merge's atomic-rename and rollback
behaviour must not exist in two places. Every route below is a few lines of
translation between HTTP and a function that already worked before this file
existed.

**Runs as a systemd service on the host, not in a container.** §5 originally
had it in compose. It moved because `/quarantine/{id}/resolve` re-runs a beets
import, and beets is installed per-user with `uv` on the host; a container
would have had to either ship its own beets (two installs to keep in step, one
of which writes to the library) or drop the endpoint. Running on the host also
means `install.sh` deploys it like everything else, with no image to rebuild.
"""

from __future__ import annotations

import os
import secrets
from dataclasses import asdict
from pathlib import Path

from fastapi import Cookie, Depends, FastAPI, Form, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel

import fetched
import quarantine
import resolve as resolve_mod
import rips
import system

HERE = Path(__file__).resolve().parent

# Set in /etc/default/lathe. Empty means no auth, which is a defensible choice
# on a tailnet with no exposed ports — but it is a choice, so the dashboard
# says so on every page rather than letting you forget.
TOKEN = os.environ.get("LIBRARIAND_TOKEN", "").strip()
COOKIE = "librariand"

app = FastAPI(
    title="librariand",
    description="Quarantine review, fetched-download approval, and rip history.",
    version="1.0.0",
)
app.mount("/static", StaticFiles(directory=HERE / "static"), name="static")
templates = Jinja2Templates(directory=str(HERE / "templates"))


# --------------------------------------------------------------------- auth

def _authorised(header: str | None, cookie: str | None) -> bool:
    if not TOKEN:
        return True
    if header and header.startswith("Bearer "):
        # Constant-time: a token compared with == leaks its prefix through
        # timing, and this one sits behind nothing but Tailscale.
        if secrets.compare_digest(header[7:].strip(), TOKEN):
            return True
    return bool(cookie and secrets.compare_digest(cookie, TOKEN))


def require_api(authorization: str | None = Header(default=None),
                librariand: str | None = Cookie(default=None)) -> None:
    """For JSON routes: 401 with a header a client can act on."""
    if not _authorised(authorization, librariand):
        raise HTTPException(status_code=401, detail="bad or missing token",
                            headers={"WWW-Authenticate": "Bearer"})


def require_page(authorization: str | None = Header(default=None),
                 librariand: str | None = Cookie(default=None)) -> None:
    """For dashboard routes: bounce to the login form instead of a 401 body."""
    if not _authorised(authorization, librariand):
        raise HTTPException(status_code=307, detail="login required",
                            headers={"Location": "/login"})


@app.exception_handler(HTTPException)
async def _redirect_307(request: Request, exc: HTTPException):
    if exc.status_code == 307 and "Location" in (exc.headers or {}):
        return RedirectResponse(exc.headers["Location"], status_code=307)
    return JSONResponse({"detail": exc.detail}, status_code=exc.status_code,
                        headers=exc.headers)


@app.get("/login", response_class=HTMLResponse, include_in_schema=False)
async def login_form(request: Request):
    if not TOKEN:
        return RedirectResponse("/", status_code=303)
    return templates.TemplateResponse(request, "login.html", {"bad": False})


@app.post("/login", include_in_schema=False)
async def login(request: Request, token: str = Form(...)):
    if not (TOKEN and secrets.compare_digest(token.strip(), TOKEN)):
        return templates.TemplateResponse(request, "login.html", {"bad": True},
                                          status_code=401)
    r = RedirectResponse("/", status_code=303)
    # No Secure flag: this is plain HTTP over a tailnet, and setting it would
    # mean the cookie is never stored and login silently fails forever.
    r.set_cookie(COOKIE, TOKEN, httponly=True, samesite="lax", max_age=60 * 60 * 24 * 365)
    return r


@app.post("/logout", include_in_schema=False)
async def logout():
    r = RedirectResponse("/login", status_code=303)
    r.delete_cookie(COOKIE)
    return r


# ------------------------------------------------------------------ helpers

def _fail(exc: Exception, status: int = 400):
    return JSONResponse({"ok": False, "detail": str(exc)}, status_code=status)


class MergeBody(BaseModel):
    entries: list[str]
    album: str | None = None
    dry_run: bool = False


class ResolveBody(BaseModel):
    identifier: str
    dry_run: bool = False


class EjectBody(BaseModel):
    device: str = "sr0"


# ---------------------------------------------------------------- JSON API

@app.get("/health", dependencies=[Depends(require_api)])
async def api_health():
    return system.health()


@app.get("/stats", dependencies=[Depends(require_api)])
async def api_stats(force: bool = False):
    return system.stats(force=force)


@app.get("/quarantine", dependencies=[Depends(require_api)])
async def api_quarantine():
    return {"entries": [asdict(e) for e in quarantine.entries()]}


@app.get("/quarantine/groups", dependencies=[Depends(require_api)])
async def api_groups(online: bool = False):
    # `online` hits the MusicBrainz disc-ID lookup, which is rate limited to
    # roughly one request a second and is therefore never the default.
    gs = quarantine.groups(online=online)
    return {"groups": [{**asdict(g), "complete": g.complete} for g in gs]}


@app.post("/quarantine/merge", dependencies=[Depends(require_api)])
async def api_merge(body: MergeBody):
    try:
        return {"ok": True, "detail": quarantine.merge(
            body.entries, album=body.album, dry_run=body.dry_run)}
    except quarantine.QuarantineError as exc:
        return _fail(exc)


@app.post("/quarantine/{name}/retry", dependencies=[Depends(require_api)])
async def api_retry(name: str, dry_run: bool = False):
    try:
        return {"ok": True, "detail": quarantine.retry([name], dry_run=dry_run)}
    except quarantine.QuarantineError as exc:
        return _fail(exc)


@app.post("/quarantine/{name}/resolve", dependencies=[Depends(require_api)])
async def api_resolve(name: str, body: ResolveBody):
    try:
        result = resolve_mod.resolve(name, body.identifier, dry_run=body.dry_run)
    except quarantine.QuarantineError as exc:
        return _fail(exc)
    return result if result.get("ok") else JSONResponse(result, status_code=409)


@app.delete("/quarantine/{name}", dependencies=[Depends(require_api)])
async def api_drop(name: str):
    # No dry_run: quarantine.drop() has no such flag, and inventing one here
    # would mean a second deletion path. The confirmation lives in the UI,
    # which is where a human is; `yes=True` is this layer asserting that a
    # DELETE request is already the confirmation.
    try:
        return {"ok": True, "detail": quarantine.drop([name], yes=True)}
    except quarantine.QuarantineError as exc:
        return _fail(exc)


@app.get("/fetched", dependencies=[Depends(require_api)])
async def api_fetched():
    return {"entries": [asdict(e) | {"clean": e.clean} for e in fetched.entries()]}


@app.post("/fetched/{fetch_id}/approve", dependencies=[Depends(require_api)])
async def api_approve(fetch_id: str, dry_run: bool = False):
    try:
        return {"ok": True, "detail": fetched.approve(fetch_id, dry_run=dry_run)}
    except fetched.FetchedError as exc:
        return _fail(exc)


@app.post("/fetched/{fetch_id}/reject", dependencies=[Depends(require_api)])
async def api_reject(fetch_id: str, dry_run: bool = False):
    try:
        return {"ok": True, "detail": fetched.reject(fetch_id, dry_run=dry_run)}
    except fetched.FetchedError as exc:
        return _fail(exc)


@app.get("/rips", dependencies=[Depends(require_api)])
async def api_rips():
    return {"current": rips.current(),
            "entries": [asdict(r) | {"needs_attention": r.needs_attention}
                        for r in rips.entries()]}


@app.post("/eject", dependencies=[Depends(require_api)])
async def api_eject(body: EjectBody | None = None):
    try:
        return {"ok": True, "detail": rips.eject((body or EjectBody()).device)}
    except rips.RipError as exc:
        return _fail(exc)


# --------------------------------------------------------------- dashboard

def _page(request: Request, name: str, **ctx) -> HTMLResponse:
    # `counts` is on every page because the nav badges are on every page.
    # system.pending_counts() is the cheap directory count, not the full scan.
    return templates.TemplateResponse(
        request, name,
        {"no_auth": not TOKEN, "human": quarantine._human,
         "counts": system.pending_counts(), **ctx},
    )


@app.get("/", response_class=HTMLResponse, include_in_schema=False,
         dependencies=[Depends(require_page)])
async def ui_index(request: Request):
    return _page(request, "index.html",
                 health=system.health(), stats=system.stats(),
                 nav="overview")


@app.get("/ui/quarantine", response_class=HTMLResponse, include_in_schema=False,
         dependencies=[Depends(require_page)])
async def ui_quarantine(request: Request):
    return _page(request, "quarantine.html",
                 entries=quarantine.entries(),
                 groups=quarantine.groups(online=False),
                 nav="quarantine")


@app.get("/ui/fetched", response_class=HTMLResponse, include_in_schema=False,
         dependencies=[Depends(require_page)])
async def ui_fetched(request: Request):
    return _page(request, "fetched.html", entries=fetched.entries(), nav="fetched")


@app.get("/ui/rips", response_class=HTMLResponse, include_in_schema=False,
         dependencies=[Depends(require_page)])
async def ui_rips(request: Request):
    return _page(request, "rips.html", entries=rips.entries(),
                 current=rips.current(), nav="rips")


def main() -> None:
    import uvicorn
    uvicorn.run(app,
                host=os.environ.get("LIBRARIAND_HOST", "0.0.0.0"),
                port=int(os.environ.get("LIBRARIAND_PORT", "8080")),
                log_level=os.environ.get("LIBRARIAND_LOG", "info"),
                access_log=False)


if __name__ == "__main__":
    main()
