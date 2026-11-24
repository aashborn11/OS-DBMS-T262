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


# ---------- public reads ----------

def shop_state(db):
    return {
        "price": SHIRT_PRICE,
        "share": DESIGNER_SHARE,
        "designs": rows(db, """
            SELECT d.id, d.title, s.name AS designer
            FROM designs d JOIN designers s ON s.id = d.designer_id
            WHERE d.status = 'approved' ORDER BY d.id DESC"""),
    }


def order_status(db, order_id):
    row = db.execute("""
        SELECT o.id, o.created_at, d.title, j.status
        FROM orders o JOIN designs d ON d.id = o.design_id
        JOIN print_jobs j ON j.order_id = o.id WHERE o.id = ?""", (order_id,)).fetchone()
    if not row:
        raise ApiError("We couldn't find that order number.", 404)
    return dict(row)


# ---------- admin reads ----------

def admin_state(db):
    return {
        "now": db.execute("SELECT unixepoch()").fetchone()[0],
        "price": SHIRT_PRICE,
        "designers": rows(db, "SELECT id, name FROM designers ORDER BY id"),
        "reviewers": rows(db, "SELECT id, name FROM reviewers ORDER BY id"),
        "designs": rows(db, """
            SELECT d.id, d.title, d.status, d.designer_id, s.name AS designer
            FROM designs d JOIN designers s ON s.id = d.designer_id
            ORDER BY d.id DESC"""),
        "reviews": rows(db, """
            SELECT h.id, d.title, r.name AS reviewer, h.decision, h.note, h.reviewed_at
            FROM review_history h
            JOIN designs d ON d.id = h.design_id
            JOIN reviewers r ON r.id = h.reviewer_id
            ORDER BY h.id DESC"""),
        "orders": rows(db, """
            SELECT o.id, o.design_id, o.customer_name AS customer, o.amount AS sale, o.created_at,
                   d.title, p.amount AS payout, p.paid, j.status AS job_status
            FROM orders o
            JOIN designs d ON d.id = o.design_id
            JOIN payouts p ON p.order_id = o.id
            JOIN print_jobs j ON j.order_id = o.id
            ORDER BY o.id DESC"""),
        "jobs": rows(db, """
            SELECT j.id, j.order_id, j.priority, j.status, j.worker, j.lease_until,
                   j.created_at, d.title, s.name AS designer
            FROM print_jobs j
            JOIN orders o ON o.id = j.order_id
            JOIN designs d ON d.id = o.design_id
            JOIN designers s ON s.id = j.designer_id
            ORDER BY CASE j.status WHEN 'claimed' THEN 0 WHEN 'queued' THEN 1 ELSE 2 END,
                     j.id DESC"""),
    }


# ---------- writes ----------

def add_person(db, table, body):
    name = need_text(body, "name", "Name", 60)
    try:
        cur = db.execute(f"INSERT INTO {table}(name) VALUES(?)", (name,))
    except sqlite3.IntegrityError:
        raise ApiError("That name is already used.")
    return {"message": f"Account created for {name}.", "id": cur.lastrowid}


def submit_design(db, body):
    designer_id = need_int(body, "designer_id", "designer")
    title = need_text(body, "title", "Design title", 60)
    try:
        cur = db.execute(
            "INSERT INTO designs(designer_id, title, status) VALUES(?, ?, 'pending')",
            (designer_id, title))
    except sqlite3.IntegrityError:
        raise ApiError("Could not submit the design.")
    return {"message": f"“{title}” submitted for review.", "id": cur.lastrowid}


def review_design(db, body):
    design_id = need_int(body, "design_id", "design")
    reviewer_id = need_int(body, "reviewer_id", "reviewer")
    decision = body.get("decision")
    if decision not in ("approved", "rejected"):
        raise ApiError("Decision must be approved or rejected.")
    note = str(body.get("note", "")).strip()[:300] or decision.capitalize()
    db.execute("BEGIN IMMEDIATE")
    try:
        cur = db.execute(
            "UPDATE designs SET status=? WHERE id=? AND status='pending'",
            (decision, design_id))
        if cur.rowcount != 1:
            raise ApiError("That design is no longer pending.", 409)
        db.execute(
            "INSERT INTO review_history(design_id, reviewer_id, decision, note, reviewed_at) "
            "VALUES(?, ?, ?, ?, unixepoch())", (design_id, reviewer_id, decision, note))
        db.execute("COMMIT")
    except Exception as exc:
        db.execute("ROLLBACK")
        if isinstance(exc, sqlite3.Error):
            raise ApiError("Review failed. The design status was not changed.")
        raise
    return {"message": f"Design {decision}."}
