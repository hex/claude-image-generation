#!/usr/bin/env python3
# ABOUTME: The image gallery: a page on 127.0.0.1 that every Claude Code session's image runs show
# ABOUTME: on as they generate, and the commands display.sh uses to start, reuse and query it.
"""Image gallery server and its client commands. Python 3.9 standard library only.

    gallery-server.py serve   --root DIR [--version V]  detach and serve the runs under DIR/runs
    gallery-server.py ensure  --root DIR                 make sure a server of this version runs
    gallery-server.py clients --root DIR                 print how many pages are connected

Each run is a directory DIR/runs/<run-id> written by display.sh in the tmux pane's layout:
meta.json, the status log, errors/<provider>.txt, active/<name>.<pid> tokens, .done and the
retry-offer / .retry pair.
"""

import argparse
import fcntl
import hmac
import http.client
import http.server
import json
import os
import re
import secrets
import select
import shutil
import socket
import socketserver
import statistics
import subprocess
import sys
import threading
import time
import urllib.parse
from pathlib import Path

PLUGIN_ROOT = Path(__file__).resolve().parent.parent
PAGE_DIR = Path(__file__).resolve().parent / "gallery"
IDLE_SECONDS = 30 * 60
SCAN_SECONDS = 0.25
PING_SECONDS = 15
KEEP_RUNS = 200
STALE_STAGING_SECONDS = 3600
OPEN_INTERVAL_SECONDS = 10
START_WAIT_SECONDS = 5
LOCK_WAIT_SECONDS = 5
ERROR_TEXT_LIMIT = 8192
USUAL_SAMPLES = 5
IN_FLIGHT = ("waiting", "querying", "retrying")
COOKIE = "gallery_token"
RUN_ID = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{10}$")
PROVIDER = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
PAGE_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/app.css": ("app.css", "text/css; charset=utf-8"),
}
SECURITY_HEADERS = {
    "Content-Security-Policy": "default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
}


def plugin_version():
    with open(PLUGIN_ROOT / ".claude-plugin" / "plugin.json", encoding="utf-8") as f:
        return json.load(f)["version"]


def write_private(path, text):
    """Writes text to path through a temp file and a rename, readable by this user only."""
    tmp = path.with_name(".%s.%s" % (path.name, secrets.token_hex(4)))
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(str(tmp), str(path))


# ── Runs ──────────────────────────────────────────────────────────────


def unescape_field(value):
    """Reverses display.sh's __pane_escape_field: \\\\, \\t and \\n back to their characters."""
    out = []
    i = 0
    while i < len(value):
        if value[i] == "\\" and i + 1 < len(value) and value[i + 1] in "\\tn":
            out.append({"\\": "\\", "t": "\t", "n": "\n"}[value[i + 1]])
            i += 2
        else:
            out.append(value[i])
            i += 1
    return "".join(out)


def new_provider(name):
    return {"name": name, "state": "waiting", "model": "", "ms": "", "attempt": "", "round": 0, "images": []}


def on_querying(p, ms, path):
    # A querying record after a provider finished starts a retry round. A querying record while
    # it is still at work is the model fallback announcing its second model: the same attempt.
    if p["state"] in ("complete", "error"):
        p["round"] += 1
    p["state"] = "querying"
    p["attempt"] = ""


def on_retrying(p, ms, path):
    p["state"] = "retrying"
    p["attempt"] = ms


def on_complete(p, ms, path):
    p["state"] = "complete"
    p["ms"] = ms
    if path:
        p["images"].append(path)


def on_error(p, ms, path):
    p["state"] = "error"


# What each status record does to its provider. The record's model, when it names one, always
# becomes the provider's model.
TRANSITIONS = {
    "querying": on_querying,
    "retrying": on_retrying,
    "complete": on_complete,
    "error": on_error,
}


def reduce_status(text, providers):
    """Folds the status log into providers (name -> provider dict). Only lines a newline ends are
    read: a record still being appended is picked up on the next scan."""
    lines = text.split("\n")[:-1]
    for number, line in enumerate(lines, 1):
        fields = line.split("\t", 4)
        if len(fields) != 5:
            raise ValueError("status line %d has %d fields, not 5" % (number, len(fields)))
        name, state, ms, model, path = fields
        if state not in TRANSITIONS:
            raise ValueError("status line %d has unknown state %r" % (number, state))
        p = providers.setdefault(name, new_provider(name))
        TRANSITIONS[state](p, ms, unescape_field(path))
        if model:
            p["model"] = unescape_field(model)


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def run_is_held(run_dir):
    """True while any process holding a token on the run is still alive."""
    try:
        tokens = os.listdir(str(run_dir / "active"))
    except FileNotFoundError:
        return False
    for token in tokens:
        pid = token.rsplit(".", 1)[-1]
        if pid.isdigit() and pid_alive(int(pid)):
            return True
    return False


def read_text(path, limit=None):
    with open(str(path), encoding="utf-8", errors="replace") as f:
        return f.read() if limit is None else f.read(limit)


class RunRejected(Exception):
    """A run directory that cannot be read as a run; the message says why."""


def read_meta(run_dir):
    """meta.json parsed into the fields display.sh writes, or RunRejected naming the field."""
    try:
        meta = json.loads(read_text(run_dir / "meta.json"))
    except ValueError as e:
        raise RunRejected("meta.json is not JSON: %s" % e)
    if not isinstance(meta, dict):
        raise RunRejected("meta.json holds %s, not an object" % json.dumps(meta)[:80])
    for key in ("prompt", "cwd", "started_at"):
        if not isinstance(meta.get(key), str):
            raise RunRejected("meta.json's %s is %s, not a string" % (key, json.dumps(meta.get(key))[:80]))
    names = meta.get("providers")
    if not isinstance(names, list) or not all(isinstance(name, str) for name in names):
        raise RunRejected("meta.json's providers is %s, not a list of names" % json.dumps(names)[:80])
    return meta


def read_run(run_dir):
    """The page's view of one run. Raises RunRejected or OSError when the directory is not one."""
    meta = read_meta(run_dir)
    providers = {name: new_provider(name) for name in meta["providers"]}
    problem = None
    try:
        reduce_status(read_text(run_dir / "status"), providers)
    except FileNotFoundError:
        pass
    except ValueError as e:
        problem = "unreadable status log: %s" % e

    if (run_dir / ".done").exists():
        status = "done"
    elif run_is_held(run_dir):
        status = "live"
    else:
        status = "interrupted"

    retry = None
    retry_seconds = None
    retry_ends_ms = None
    updated_ms = None
    if status == "live":
        # When the run last moved: its status log's last record, or its start before the first one.
        mtime = (run_dir / "meta.json").stat().st_mtime
        try:
            mtime = max(mtime, (run_dir / "status").stat().st_mtime)
        except FileNotFoundError:
            pass
        updated_ms = int(mtime * 1000)
        try:
            offer_path = run_dir / "retry-offer"
            offer = read_text(offer_path).split("\n")
            retry = [n for n in offer[1:] if n]
            # The offer stays open the seconds its first line names, from when run-all wrote it.
            if re.fullmatch(r"[0-9]+", offer[0]):
                retry_seconds = int(offer[0])
                retry_ends_ms = int((offer_path.stat().st_mtime + retry_seconds) * 1000)
        except FileNotFoundError:
            pass

    cards = []
    for p in providers.values():
        state = p["state"]
        if status != "live" and state in ("waiting", "querying", "retrying"):
            state = "interrupted"
        error = None
        if state == "error":
            try:
                error = read_text(run_dir / "errors" / ("%s.txt" % p["name"]), ERROR_TEXT_LIMIT)
            except FileNotFoundError:
                error = ""
        image = None
        if state == "complete" and p["images"]:
            n = len(p["images"]) - 1
            image = {"n": n, "path": p["images"][n]}
        cards.append({
            "name": p["name"], "state": state, "model": p["model"], "ms": p["ms"],
            "attempt": p["attempt"], "round": p["round"], "error": error, "image": image,
        })
    return {
        "id": run_dir.name,
        "prompt": meta["prompt"],
        "cwd": meta["cwd"],
        "session": os.path.basename(meta["cwd"]),
        "started_at": meta["started_at"],
        "status": status,
        "retry": retry,
        "retry_seconds": retry_seconds,
        "retry_ends_ms": retry_ends_ms,
        "updated_ms": updated_ms,
        "problem": problem,
        "providers": cards,
    }


def add_usual_times(runs):
    """Gives each provider still at work usual_ms: the median time of the last USUAL_SAMPLES frames
    the same provider and model completed, runs being newest first. A provider whose model has
    never completed a frame gets none."""
    samples = {}
    for run in runs:
        for card in run["providers"]:
            if card["state"] == "complete" and card["model"] and re.fullmatch(r"[0-9]+", card["ms"]):
                times = samples.setdefault((card["name"], card["model"]), [])
                if len(times) < USUAL_SAMPLES:
                    times.append(int(card["ms"]))
    for run in runs:
        for card in run["providers"]:
            times = samples.get((card["name"], card["model"]))
            if card["state"] in IN_FLIGHT and times:
                card["usual_ms"] = int(statistics.median(times))


def image_path(runs_dir, run_id, provider, n):
    """The file of a provider's n-th image in a run, read from the run's status log, or None."""
    if not RUN_ID.match(run_id) or not PROVIDER.match(provider):
        return None
    run_dir = runs_dir / run_id
    providers = {}
    try:
        reduce_status(read_text(run_dir / "status"), providers)
    except (FileNotFoundError, ValueError):
        return None
    p = providers.get(provider)
    if p is None or n >= len(p["images"]):
        return None
    return p["images"][n]


def image_type(head):
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if head.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if head.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp"
    return None


# ── Server ────────────────────────────────────────────────────────────


class Gallery:
    """What the request threads share with the scanning loop."""

    def __init__(self, root, version, token, port):
        self.root = root
        self.runs_dir = root / "runs"
        self.version = version
        self.token = token
        self.port = port
        self.instance = secrets.token_hex(8)
        self.origin = "http://127.0.0.1:%d" % port
        self.url = "%s/?t=%s" % (self.origin, token)
        self.changed = threading.Condition()
        self.snapshot = json.dumps({"instance": self.instance, "runs": []})
        self.clients = 0
        self.stop = threading.Event()
        self.last_open = 0.0
        self.rejected = {}
        self.page = {}
        for route, (name, ctype) in PAGE_FILES.items():
            self.page[route] = ((PAGE_DIR / name).read_bytes(), ctype)

    def scan(self):
        """Reads every run, newest first, prunes beyond KEEP_RUNS and publishes a change."""
        names = []
        now = time.time()
        for entry in os.scandir(str(self.runs_dir)):
            if RUN_ID.match(entry.name):
                names.append(entry.name)
            elif entry.name.startswith(".") and RUN_ID.match(entry.name[1:]):
                # A run that never finished being assembled: its creator died before the rename.
                # It can also be renamed into place between the listing and the stat.
                try:
                    if now - entry.stat().st_mtime > STALE_STAGING_SECONDS:
                        shutil.rmtree(entry.path, ignore_errors=True)
                except FileNotFoundError:
                    pass
        names.sort(reverse=True)
        runs = []
        for index, name in enumerate(names):
            run_dir = self.runs_dir / name
            try:
                if index >= KEEP_RUNS and not run_is_held(run_dir):
                    shutil.rmtree(str(run_dir), ignore_errors=True)
                    continue
                runs.append(read_run(run_dir))
                self.rejected.pop(name, None)
            except RunRejected as e:
                self.reject(run_dir, str(e))
            except OSError as e:
                self.reject(run_dir, "%s: %s" % (os.path.basename(e.filename or name), e.strerror))
        for name in set(self.rejected) - set(names):
            del self.rejected[name]
        add_usual_times(runs)
        snapshot = json.dumps({"instance": self.instance, "runs": runs})
        if snapshot != self.snapshot:
            with self.changed:
                self.snapshot = snapshot
                self.changed.notify_all()
        return any(run["status"] == "live" for run in runs)

    def reject(self, run_dir, reason):
        """Leaves a run directory out of the snapshot, naming it in server.log once per reason."""
        if self.rejected.get(run_dir.name) != reason:
            self.rejected[run_dir.name] = reason
            print("image gallery: skipping run %s: %s" % (run_dir, reason), file=sys.stderr, flush=True)

    def open_page(self):
        """Opens the page in the browser at most once per OPEN_INTERVAL_SECONDS. True when a
        browser was opened now or a moment ago."""
        if time.time() - self.last_open < OPEN_INTERVAL_SECONDS:
            return True
        if sys.platform == "darwin":
            command = ["open", "-g", self.url]
        elif shutil.which("xdg-open") and (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
            command = ["xdg-open", self.url]
        else:
            return False
        try:
            opened = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL, timeout=10).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            return False
        if opened:
            self.last_open = time.time()
        return opened


class Handler(http.server.BaseHTTPRequestHandler):
    def version_string(self):
        return "image-gallery"

    @property
    def gallery(self):
        return self.server.gallery

    def log_message(self, format, *args):
        pass

    def send_json(self, code, body, extra=None):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def end_headers(self):
        for k, v in SECURITY_HEADERS.items():
            self.send_header(k, v)
        super().end_headers()

    def token_given(self):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        if query.get("t"):
            return query["t"][0]
        for part in self.headers.get("Cookie", "").split(";"):
            name, _, value = part.strip().partition("=")
            if name == COOKIE:
                return value
        return ""

    def allowed(self, post):
        """Answers 403 and returns False unless the request is for this server, from this user."""
        if self.headers.get("Host") != "127.0.0.1:%d" % self.gallery.port:
            self.send_json(403, {"error": "wrong Host header; open the page at %s" % self.gallery.origin})
            return False
        if not hmac.compare_digest(self.token_given().encode(), self.gallery.token.encode()):
            self.send_json(403, {"error": "missing or wrong token; open the address the image tool printed"})
            return False
        if post and self.headers.get("Origin") != self.gallery.origin:
            self.send_json(403, {"error": "wrong Origin header"})
            return False
        return True

    def do_GET(self):
        if not self.allowed(post=False):
            return
        parts = urllib.parse.urlsplit(self.path)
        route = parts.path
        if route == "/" and "t" in urllib.parse.parse_qs(parts.query):
            self.send_response(303)
            self.send_header("Location", "/")
            self.send_header("Set-Cookie", "%s=%s; Path=/; HttpOnly; SameSite=Strict" % (COOKIE, self.gallery.token))
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif route in self.gallery.page:
            body, ctype = self.gallery.page[route]
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif route == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
        elif route == "/health":
            self.send_json(200, {"instance": self.gallery.instance, "version": self.gallery.version,
                                 "clients": self.gallery.clients})
        elif route == "/events":
            self.events()
        elif route.startswith("/img/"):
            self.image(route)
        else:
            self.send_json(404, {"error": "no such page: %s" % route})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        if not self.allowed(post=True):
            return
        route = urllib.parse.urlsplit(self.path).path
        segments = route.strip("/").split("/")
        if segments[0] == "reveal" and len(segments) == 4:
            self.reveal(segments[1:])
        elif segments[0] == "retry" and len(segments) == 2:
            self.retry(segments[1])
        elif route == "/open":
            self.send_json(200, {"opened": self.gallery.open_page()})
        elif route == "/shutdown":
            self.send_json(200, {"stopping": True})
            self.gallery.stop.set()
        else:
            self.send_json(404, {"error": "no such action: %s" % route})

    def events(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        changed = self.gallery.changed
        with changed:
            self.gallery.clients += 1
        try:
            sent = None
            quiet = 0.0
            while not self.gallery.stop.is_set() and not self.page_closed():
                with changed:
                    if sent == self.gallery.snapshot:
                        changed.wait(1)
                    snapshot = self.gallery.snapshot
                if snapshot != sent:
                    self.wfile.write(b"data: " + snapshot.encode() + b"\n\n")
                    sent = snapshot
                    quiet = time.time()
                elif time.time() - quiet > PING_SECONDS:
                    self.wfile.write(b": ping\n\n")
                    quiet = time.time()
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with changed:
                self.gallery.clients -= 1

    def page_closed(self):
        """True once the page has hung up. A page sends nothing after its request, so the socket
        turning readable means end of file; checking each second keeps the count of connected
        pages, which decides whether a retry is offered, no more than a second out of date."""
        readable, _, _ = select.select([self.connection], [], [], 0)
        return bool(readable) and self.connection.recv(1, socket.MSG_PEEK) == b""

    def image_target(self, segments):
        """The image file the URL segments <run>/<provider>/<n> name, or None after a 404."""
        run_id, provider, n = segments
        path = image_path(self.gallery.runs_dir, run_id, provider, int(n)) if n.isdigit() else None
        if path is None:
            self.send_json(404, {"error": "no image %s/%s/%s" % (run_id, provider, n)})
            return None
        if not os.path.isfile(path):
            self.send_json(404, {"error": "file moved or deleted", "path": path})
            return None
        return path

    def image(self, route):
        segments = route[len("/img/"):].split("/")
        if len(segments) != 3:
            self.send_json(404, {"error": "no such image: %s" % route})
            return
        path = self.image_target(segments)
        if path is None:
            return
        with open(path, "rb") as f:
            body = f.read()
        ctype = image_type(body[:16])
        if ctype is None:
            self.send_json(415, {"error": "not a PNG, JPEG, GIF or WebP image", "path": path})
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "private, max-age=3600")
        self.end_headers()
        self.wfile.write(body)

    def reveal(self, segments):
        path = self.image_target(segments)
        if path is None:
            return
        if sys.platform == "darwin":
            command = ["open", "-R", path]
        elif shutil.which("xdg-open"):
            command = ["xdg-open", os.path.dirname(path)]
        else:
            self.send_json(501, {"error": "no file manager to reveal %s with (tried open, xdg-open)" % path})
            return
        try:
            result = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.PIPE, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as e:
            self.send_json(500, {"error": "%s failed: %s" % (command[0], e)})
            return
        if result.returncode != 0:
            self.send_json(500, {"error": "%s exited %d: %s" % (command[0], result.returncode,
                                                                 result.stderr.decode(errors="replace").strip())})
            return
        self.send_json(200, {"revealed": path})

    def retry(self, run_id):
        """Answers a run's retry offer the way the tmux pane's r key does: renames it to .retry."""
        if not RUN_ID.match(run_id) or not (self.gallery.runs_dir / run_id).is_dir():
            self.send_json(404, {"error": "no run %s" % run_id})
            return
        run_dir = self.gallery.runs_dir / run_id
        try:
            os.rename(str(run_dir / "retry-offer"), str(run_dir / ".retry"))
        except FileNotFoundError:
            self.send_json(409, {"error": "run %s has no retry offer open" % run_id})
            return
        self.send_json(200, {"retrying": run_id})


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

    def server_bind(self):
        # HTTPServer.server_bind looks the host name up, which can stall on a reverse lookup of
        # 127.0.0.1; the name is never used.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


def detach():
    """Leaves the caller behind: a session of its own, no terminal, none of the caller's files."""
    if os.fork() > 0:
        os._exit(0)
    os.setsid()
    if os.fork() > 0:
        os._exit(0)
    os.chdir("/")
    os.umask(0o077)
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    for name in os.listdir("/dev/fd"):
        fd = int(name)
        if fd > 2:
            try:
                os.close(fd)
            except OSError:
                pass


def take_lock(root):
    """Holds root/server.lock for the life of this process, or returns None when another server
    keeps it past LOCK_WAIT_SECONDS. The kernel drops the lock when the process dies."""
    fd = os.open(str(root / "server.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    deadline = time.time() + LOCK_WAIT_SECONDS
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.time() > deadline:
                os.close(fd)
                return None
            time.sleep(0.1)


def read_token(root):
    """The page token, kept across restarts so an open page keeps working after one."""
    path = root / "token"
    try:
        token = read_text(path).strip()
        if re.match(r"^[A-Za-z0-9_-]{43,}$", token):
            return token
    except FileNotFoundError:
        pass
    token = secrets.token_urlsafe(32)
    write_private(path, token)
    return token


def bind(root):
    """Binds the port of the last server when it is free, so an open page reconnects."""
    try:
        port = int(read_text(root / "last-port").strip())
        return Server(("127.0.0.1", port), Handler)
    except (FileNotFoundError, ValueError, OSError, OverflowError):
        return Server(("127.0.0.1", 0), Handler)


def serve(root, version):
    (root / "runs").mkdir(mode=0o700, parents=True, exist_ok=True)
    detach()
    if take_lock(root) is None:
        return
    log = os.open(str(root / "server.log"), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.dup2(log, 2)
    os.close(log)
    httpd = bind(root)
    port = httpd.server_address[1]
    gallery = Gallery(root, version, read_token(root), port)
    httpd.gallery = gallery
    gallery.scan()
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    write_private(root / "last-port", str(port))
    write_private(root / "server.json", json.dumps({
        "pid": os.getpid(), "port": port, "instance": gallery.instance, "version": version, "token": gallery.token,
    }))
    busy_at = time.time()
    while not gallery.stop.wait(SCAN_SECONDS):
        if gallery.scan() or gallery.clients > 0:
            busy_at = time.time()
        elif time.time() - busy_at > IDLE_SECONDS:
            # A run may have begun since the scan that found none live; look once more.
            if not gallery.scan() and gallery.clients == 0:
                break
    try:
        info = json.loads(read_text(root / "server.json"))
        if info.get("instance") == gallery.instance:
            os.unlink(str(root / "server.json"))
    except (FileNotFoundError, ValueError):
        pass
    httpd.server_close()
    os._exit(0)


# ── Client ────────────────────────────────────────────────────────────


def request(info, method, path, timeout=2):
    """Sends one request to the server server.json describes; returns (status, parsed JSON)."""
    conn = http.client.HTTPConnection("127.0.0.1", info["port"], timeout=timeout)
    try:
        headers = {"Cookie": "%s=%s" % (COOKIE, info["token"])}
        if method == "POST":
            headers["Origin"] = "http://127.0.0.1:%d" % info["port"]
        conn.request(method, path, headers=headers)
        response = conn.getresponse()
        return response.status, json.loads(response.read() or b"null")
    finally:
        conn.close()


def running_server(root):
    """server.json and /health of the server answering for root, or (None, None)."""
    try:
        info = json.loads(read_text(root / "server.json"))
        status, health = request(info, "GET", "/health")
    except (FileNotFoundError, ValueError, KeyError, TypeError, OSError, http.client.HTTPException):
        return None, None
    if status != 200 or not isinstance(health, dict) or health.get("instance") != info.get("instance"):
        return None, None
    return info, health


def wait_for_exit(pid, seconds):
    deadline = time.time() + seconds
    while pid_alive(pid) and time.time() < deadline:
        time.sleep(0.05)


def start_server(root, version):
    """Launches a server and waits for one to answer: this one, or a racing caller's."""
    subprocess.run([sys.executable, "-I", str(Path(__file__).resolve()), "serve", "--root", str(root),
                    "--version", version], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=True)
    deadline = time.time() + START_WAIT_SECONDS
    while time.time() < deadline:
        info, health = running_server(root)
        if info is not None:
            return info, health
        time.sleep(0.05)
    return None, None


def in_ssh_session():
    return bool(os.environ.get("SSH_CONNECTION") or os.environ.get("SSH_TTY"))


def ensure(root):
    version = plugin_version()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(str(root), 0o700)
    info, health = running_server(root)
    if info is not None and health.get("version") != version:
        request(info, "POST", "/shutdown")
        wait_for_exit(info["pid"], LOCK_WAIT_SECONDS)
        info = None
    if info is None:
        info, health = start_server(root, version)
        if info is None:
            print("image gallery: the server did not start within %d s; see %s" %
                  (START_WAIT_SECONDS, root / "server.log"), file=sys.stderr)
            return 1
    if health["clients"] == 0 and os.environ.get("IMAGE_GALLERY_NO_OPEN") != "1":
        url = "http://127.0.0.1:%d/?t=%s" % (info["port"], info["token"])
        opened = False
        if not in_ssh_session():
            status, answer = request(info, "POST", "/open", timeout=15)
            opened = status == 200 and answer.get("opened") is True
        if not opened:
            print("image gallery: open %s to watch the images" % url, file=sys.stderr)
    return 0


def clients(root):
    info, health = running_server(root)
    print(0 if health is None else health["clients"])
    return 0


def main():
    parser = argparse.ArgumentParser(description="The image gallery server and its client commands.")
    parser.add_argument("command", choices=["serve", "ensure", "clients"])
    parser.add_argument("--root", required=True, type=Path, help="the gallery's state directory")
    parser.add_argument("--version", help="the version serve reports (default: plugin.json's)")
    args = parser.parse_args()
    root = args.root.resolve()
    if args.command == "serve":
        serve(root, args.version or plugin_version())
        return 0
    if args.command == "ensure":
        try:
            return ensure(root)
        except (OSError, http.client.HTTPException, subprocess.CalledProcessError, ValueError) as e:
            print("image gallery: %s" % e, file=sys.stderr)
            return 1
    return clients(root)


if __name__ == "__main__":
    sys.exit(main())
