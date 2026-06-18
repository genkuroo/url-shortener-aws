"""URL shortener API (FastAPI) — Phase 4: backed by Postgres.

Storage is now a real Postgres database (AWS RDS in the deployed stack). Links
and clicks survive container restarts, which they didn't in the in-memory Phase 2
version.

Where the database credentials come from:
  - In AWS: the container's IAM *task role* lets it read one Secrets Manager
    secret (its ARN is passed in via the DB_SECRET_ARN env var). The secret holds
    host/port/dbname/username/password as JSON. The password is never baked into
    the image or the task definition.
  - Locally: set DATABASE_URL (e.g. postgres://user:pass@localhost:5432/db) and
    no AWS calls are made.
"""

from __future__ import annotations

import json
import os
import secrets
import string

import psycopg2
import psycopg2.extras
from fastapi import FastAPI, HTTPException
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, HttpUrl

app = FastAPI(title="URL Shortener")

# Characters used to build short codes (a-z, A-Z, 0-9).
_ALPHABET = string.ascii_letters + string.digits


# ---------------------------------------------------------------------------
# Database connection
# ---------------------------------------------------------------------------
def _db_params() -> dict:
    """Resolve Postgres connection parameters.

    Prefers DATABASE_URL (local dev). Otherwise reads the Secrets Manager secret
    named by DB_SECRET_ARN, using the container's task role for permission.
    """
    url = os.environ.get("DATABASE_URL")
    if url:
        return {"dsn": url}

    secret_arn = os.environ.get("DB_SECRET_ARN")
    if not secret_arn:
        raise RuntimeError("Set DATABASE_URL (local) or DB_SECRET_ARN (AWS).")

    # Imported lazily so local dev doesn't need boto3 installed/configured.
    import boto3

    region = os.environ.get("AWS_REGION", "us-east-1")
    client = boto3.client("secretsmanager", region_name=region)
    secret = json.loads(client.get_secret_value(SecretId=secret_arn)["SecretString"])
    return {
        "host": secret["host"],
        "port": secret["port"],
        "dbname": secret["dbname"],
        "user": secret["username"],
        "password": secret["password"],
    }


# Resolve once at import time; reuse for every connection.
_DB_PARAMS = _db_params()


def _connect():
    """Open a fresh Postgres connection (one per request — simple and robust)."""
    return psycopg2.connect(**_DB_PARAMS)


def _init_db() -> None:
    """Create the tables if they don't exist yet.

    This is a tiny hand-rolled migration. A larger project would use a proper
    migration tool (e.g. Alembic); for two tables, idempotent CREATE TABLE IF NOT
    EXISTS run at startup is enough.
    """
    with _connect() as conn, conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS links (
                code       TEXT PRIMARY KEY,
                long_url   TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS clicks (
                id         BIGSERIAL PRIMARY KEY,
                code       TEXT NOT NULL REFERENCES links(code) ON DELETE CASCADE,
                clicked_at TIMESTAMPTZ NOT NULL DEFAULT now()
            );
            """
        )
        conn.commit()


@app.on_event("startup")
def _startup() -> None:
    _init_db()


def _new_code(cur, length: int = 6) -> str:
    """Generate a random short code that isn't already taken."""
    while True:
        code = "".join(secrets.choice(_ALPHABET) for _ in range(length))
        cur.execute("SELECT 1 FROM links WHERE code = %s", (code,))
        if cur.fetchone() is None:
            return code


class CreateLink(BaseModel):
    """Request body for creating a short link."""

    url: HttpUrl


@app.get("/healthz")
def healthz():
    """Liveness probe. The load balancer hits this to check the app is alive.

    Kept deliberately DB-free: it answers as long as the web process is up, so a
    brief database hiccup doesn't make the ALB kill an otherwise-healthy task.
    """
    return {"status": "ok"}


@app.post("/api/links", status_code=201)
def create_link(body: CreateLink):
    """Create a short link for a long URL."""
    with _connect() as conn, conn.cursor() as cur:
        code = _new_code(cur)
        cur.execute(
            "INSERT INTO links (code, long_url) VALUES (%s, %s)",
            (code, str(body.url)),
        )
        conn.commit()
    return {"code": code, "short_url": f"/{code}", "long_url": str(body.url)}


@app.get("/api/links/{code}/stats")
def link_stats(code: str):
    """Return click stats for a short link, read from Postgres."""
    with _connect() as conn, conn.cursor(
        cursor_factory=psycopg2.extras.RealDictCursor
    ) as cur:
        cur.execute(
            "SELECT code, long_url, created_at FROM links WHERE code = %s", (code,)
        )
        link = cur.fetchone()
        if link is None:
            raise HTTPException(status_code=404, detail="code not found")

        cur.execute("SELECT count(*) AS n FROM clicks WHERE code = %s", (code,))
        click_count = cur.fetchone()["n"]

        cur.execute(
            "SELECT clicked_at FROM clicks WHERE code = %s "
            "ORDER BY clicked_at DESC LIMIT 5",
            (code,),
        )
        recent = [{"at": r["clicked_at"].isoformat()} for r in cur.fetchall()]

    return {
        "code": link["code"],
        "long_url": link["long_url"],
        "created_at": link["created_at"].isoformat(),
        "click_count": click_count,
        "recent_clicks": recent,
    }


@app.get("/{code}")
def follow(code: str):
    """Redirect a short code to its long URL and record the click."""
    with _connect() as conn, conn.cursor() as cur:
        cur.execute("SELECT long_url FROM links WHERE code = %s", (code,))
        row = cur.fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="code not found")
        long_url = row[0]
        cur.execute("INSERT INTO clicks (code) VALUES (%s)", (code,))
        conn.commit()
    return RedirectResponse(url=long_url, status_code=307)
