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

def record_sale(db, design_id, customer, force_fail=False):
    """One transaction: order + designer payout + print job. Returns the order id."""
    db.execute("BEGIN")
    try:
        cur = db.execute(
            "INSERT INTO orders(design_id, customer_name, amount, created_at) "
            "SELECT ?, ?, ?, unixepoch() FROM designs WHERE id=? AND status='approved'",
            (design_id, customer, SHIRT_PRICE, design_id))
        if cur.rowcount == 0:
            raise ApiError("That design isn't available right now.", 409)
        order_id = cur.lastrowid
        db.execute(
            "INSERT INTO payouts(order_id, designer_id, amount) "
            "SELECT ?, designer_id, ? * ? FROM designs WHERE id=?",
            (order_id, SHIRT_PRICE, DESIGNER_SHARE, design_id))
        db.execute(
            "INSERT INTO print_jobs(order_id, designer_id, priority, created_at) "
            "SELECT ?, designer_id, ?, unixepoch() FROM designs WHERE id=?",
            (order_id, 9 if force_fail else 3, design_id))  # priority 9 breaks the CHECK
        db.execute("COMMIT")
    except sqlite3.Error:
        db.execute("ROLLBACK")
        raise ApiError("Transaction rolled back; no sale records were saved.", 409)
    except Exception:
        db.execute("ROLLBACK")
        raise
    return order_id


def customer_order(db, body):
    design_id = need_int(body, "design_id", "design")
    customer = str(body.get("customer", "")).strip()[:60] or "Guest"
    order_id = record_sale(db, design_id, customer)       # customers can never force a failure
    return {"order_id": order_id, "message": f"Order #{order_id} placed."}


def admin_sale(db, body):
    design_id = need_int(body, "design_id", "design")
    customer = str(body.get("customer", "")).strip()[:60] or "Guest"
    order_id = record_sale(db, design_id, customer, bool(body.get("force_fail")))
    payout = SHIRT_PRICE * DESIGNER_SHARE
    return {"order_id": order_id,
            "message": f"Order #{order_id} saved: ₹{SHIRT_PRICE:g} sale, ₹{payout:g} payout, print job queued."}

REQUEUE_SQL = ("UPDATE print_jobs SET status='queued', worker=NULL, lease_until=0 "
               "WHERE status='claimed' AND lease_until <= unixepoch()")


def claim_next_job(db, worker):
    """Requeue expired leases, then claim the best queued job. Returns job id or 0."""
    db.execute("BEGIN IMMEDIATE")
    try:
        db.execute(REQUEUE_SQL)
        row = db.execute(
            "SELECT id FROM print_jobs WHERE status='queued' "
            "ORDER BY priority - (SELECT COUNT(*) FROM print_jobs recent "
            "WHERE recent.designer_id=print_jobs.designer_id "
            "AND recent.status='completed' AND recent.created_at >= unixepoch()-60) DESC, "
            "created_at ASC LIMIT 1").fetchone()
        job_id = row[0] if row else 0
        if job_id:
            db.execute(
                "UPDATE print_jobs SET status='claimed', worker=?, "
                "lease_until=unixepoch()+? WHERE id=? AND status='queued'",
                (worker, LEASE_SECONDS, job_id))
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise
    return job_id


def process_next_job(db, body):
    worker = str(body.get("worker", "")).strip()[:40] or "worker-1"
    job_id = claim_next_job(db, worker)
    if not job_id:
        raise ApiError("No queued print jobs.", 409)
    cur = db.execute(
        "UPDATE print_jobs SET status='completed', worker=NULL, lease_until=0 "
        "WHERE id=? AND status='claimed' AND worker=?", (job_id, worker))
    if cur.rowcount != 1:
        raise ApiError("Could not complete the job; its lease will allow a retry.", 409)
    return {"message": f"{worker} printed job #{job_id}."}


def simulate_crash(db, body):
    job_id = claim_next_job(db, "crashed-worker")
    if not job_id:
        raise ApiError("No queued print jobs.", 409)
    db.execute("UPDATE print_jobs SET lease_until=unixepoch()-1 WHERE id=? AND status='claimed'",
               (job_id,))
    return {"message": f"Worker stopped on job #{job_id}. Its lease has expired; recover to requeue it."}


def recover_jobs(db, body):
    db.execute("BEGIN IMMEDIATE")
    try:
        count = db.execute(REQUEUE_SQL).rowcount
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise
    return {"message": f"{count} expired job{'s' if count != 1 else ''} returned to the queue."}


PUBLIC_POST = {"/api/order": customer_order}

ADMIN_POST = {
    "/api/admin/designer": lambda db, b: add_person(db, "designers", b),
    "/api/admin/reviewer": lambda db, b: add_person(db, "reviewers", b),
    "/api/admin/design": submit_design,
    "/api/admin/review": review_design,
    "/api/admin/sale": admin_sale,
    "/api/admin/jobs/next": process_next_job,
    "/api/admin/jobs/crash": simulate_crash,
    "/api/admin/jobs/recover": recover_jobs,
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    # -- helpers --
    def send_bytes(self, data, ctype, status=200, headers=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, payload, status=200, headers=None):
        self.send_bytes(json.dumps(payload).encode(), "application/json", status, headers)

    def send_file(self, name, ctype):
        with open(os.path.join(HERE, name), "rb") as f:
            self.send_bytes(f.read(), ctype)

    def is_admin(self):
        jar = SimpleCookie(self.headers.get("Cookie", ""))
        morsel = jar.get("gp_admin")
        return bool(morsel and morsel.value in SESSIONS)

    def with_db(self, fn):
        db = connect()
        try:
            return fn(db)
        finally:
            db.close()

    # -- GET --
    def do_GET(self):
        url = urlparse(self.path)
        path = url.path
        if path in ("/", "/index.html"):
            return self.send_file("index.html", "text/html; charset=utf-8")
        if path in ("/admin", "/admin/", "/admin.html"):
            return self.send_file("admin.html", "text/html; charset=utf-8")
        if path in STATIC:
            return self.send_file(*STATIC[path])
        try:
            if path == "/api/shop":
                return self.send_json(self.with_db(shop_state))
            if path == "/api/order":
                oid = int((parse_qs(url.query).get("id") or [""])[0])
                return self.send_json(self.with_db(lambda db: order_status(db, oid)))
            if path == "/api/admin/me":
                return self.send_json({"admin": self.is_admin()})
            if path == "/api/admin/state":
                if not self.is_admin():
                    return self.send_json({"error": "Please sign in."}, 401)
                return self.send_json(self.with_db(admin_state))
        except ValueError:
            return self.send_json({"error": "Enter a valid order number."}, 400)
        except ApiError as exc:
            return self.send_json({"error": str(exc)}, exc.status)
        self.send_json({"error": "Not found"}, 404)

    # -- POST --
    def do_POST(self):
        path = urlparse(self.path).path
        try:
            length = min(int(self.headers.get("Content-Length") or 0), 64_000)
            body = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(body, dict):
                raise ValueError
        except ValueError:
            return self.send_json({"error": "Invalid request."}, 400)

        if path == "/api/admin/login":
            time.sleep(0.4)  # slow down guessing
            given = str(body.get("password", "")).encode()
            if hmac.compare_digest(given, ADMIN_PASSWORD.encode()):
                token = secrets.token_urlsafe(32)
                SESSIONS.add(token)
                cookie = f"gp_admin={token}; HttpOnly; SameSite=Strict; Path=/"
                return self.send_json({"ok": True}, headers={"Set-Cookie": cookie})
            return self.send_json({"error": "That password isn't right."}, 401)

        if path == "/api/admin/logout":
            jar = SimpleCookie(self.headers.get("Cookie", ""))
            if "gp_admin" in jar:
                SESSIONS.discard(jar["gp_admin"].value)
            return self.send_json({"ok": True},
                                  headers={"Set-Cookie": "gp_admin=; Max-Age=0; Path=/; HttpOnly; SameSite=Strict"})

        handler = PUBLIC_POST.get(path)
        if handler is None:
            handler = ADMIN_POST.get(path)
            if handler is None:
                return self.send_json({"error": "Not found"}, 404)
            if not self.is_admin():
                return self.send_json({"error": "Please sign in."}, 401)
        try:
            self.send_json(self.with_db(lambda db: handler(db, body)))
        except ApiError as exc:
            self.send_json({"error": str(exc)}, exc.status)
        except sqlite3.OperationalError:
            self.send_json({"error": "Database is busy. Try again."}, 503)


if __name__ == "__main__":
    init_db()
    port = int(os.environ.get("PORT", "8000"))
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"Guild Press store:  http://localhost:{port}")
    print(f"Admin console:      http://localhost:{port}/admin")
    shown = ADMIN_PASSWORD if "ADMIN_PASSWORD" not in os.environ else "(from ADMIN_PASSWORD)"
    print(f"Admin password:     {shown}")
    print("Ctrl+C to stop")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
