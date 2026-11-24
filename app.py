"""Guild Press. Run: python app.py

  http://localhost:8000        customer store
  http://localhost:8000/admin  admin console (password protected)

Admin password: set the ADMIN_PASSWORD environment variable, or use the default
printed at startup. All admin data and actions live under /api/admin/* and need
a signed-in session; the public store can only browse approved designs, place
orders and look up an order's print status.
"""
import hmac
import json
import os
import secrets
import sqlite3
import time
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.path.join(HERE, "guild_press.db")
SHIRT_PRICE = 500.0
DESIGNER_SHARE = 0.20
LEASE_SECONDS = 30
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "guildpress")
SESSIONS = set()

STATIC = {
    "/static/base.css": ("base.css", "text/css; charset=utf-8"),
    "/static/shared.js": ("shared.js", "application/javascript; charset=utf-8"),
}


class ApiError(Exception):
    def __init__(self, message, status=400):
        super().__init__(message)
        self.status = status


def connect():
    db = sqlite3.connect(DB_PATH, timeout=5, isolation_level=None)  # manual transactions
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys = ON")
    return db


def init_db():
    with open(os.path.join(HERE, "schema.sql"), encoding="utf-8") as f:
        schema = f.read()
    db = connect()
    db.executescript(schema)
    db.close()


def rows(db, sql, *args):
    return [dict(r) for r in db.execute(sql, args).fetchall()]


def need_text(body, key, label, limit=80):
    value = str(body.get(key, "")).strip()
    if not value:
        raise ApiError(f"{label} cannot be empty.")
    if len(value) > limit:
        raise ApiError(f"{label} is too long (max {limit} characters).")
    return value


def need_int(body, key, label):
    try:
        return int(body.get(key))
    except (TypeError, ValueError):
        raise ApiError(f"Choose a valid {label}.")
