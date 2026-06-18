"""URL shortener API (FastAPI).

Phase 2: storage is in-memory only — restarting the container forgets all links.
Phase 4 swaps this for a real Postgres database. Keeping it in-memory now lets us
prove the container + load balancer path first, without a database in the way.
"""

from __future__ import annotations

import secrets
import string
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, HttpUrl

app = FastAPI(title="URL Shortener")

# In-memory store: code -> {"long_url": str, "created_at": str, "clicks": [..]}
# Replaced by Postgres in Phase 4.
_LINKS: dict[str, dict] = {}

# Characters used to build short codes (a-z, A-Z, 0-9).
_ALPHABET = string.ascii_letters + string.digits


def _new_code(length: int = 6) -> str:
    """Generate a random, unused short code."""
    while True:
        code = "".join(secrets.choice(_ALPHABET) for _ in range(length))
        if code not in _LINKS:
            return code


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


class CreateLink(BaseModel):
    """Request body for creating a short link."""

    url: HttpUrl


@app.get("/healthz")
def healthz():
    """Liveness probe. The load balancer hits this to check the app is alive."""
    return {"status": "ok"}


@app.post("/api/links", status_code=201)
def create_link(body: CreateLink):
    """Create a short link for a long URL."""
    code = _new_code()
    _LINKS[code] = {"long_url": str(body.url), "created_at": _now(), "clicks": []}
    return {"code": code, "short_url": f"/{code}", "long_url": str(body.url)}


@app.get("/api/links/{code}/stats")
def link_stats(code: str):
    """Return click stats for a short link."""
    link = _LINKS.get(code)
    if link is None:
        raise HTTPException(status_code=404, detail="code not found")
    return {
        "code": code,
        "long_url": link["long_url"],
        "created_at": link["created_at"],
        "click_count": len(link["clicks"]),
        "recent_clicks": link["clicks"][-5:],
    }


@app.get("/{code}")
def follow(code: str):
    """Redirect a short code to its long URL and record the click."""
    link = _LINKS.get(code)
    if link is None:
        raise HTTPException(status_code=404, detail="code not found")
    link["clicks"].append({"at": _now()})
    return RedirectResponse(url=link["long_url"], status_code=307)
