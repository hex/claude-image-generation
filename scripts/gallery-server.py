#!/usr/bin/env python3
# ABOUTME: The image gallery: a page on 127.0.0.1 that every Claude Code session's image runs show
# ABOUTME: on as they generate, and the commands display.sh uses to start, reuse and query it.
"""Image gallery server and its client commands. Python 3.9 standard library only.

    gallery-server.py serve   --root DIR [--version V]  detach and serve the runs under DIR/runs
    gallery-server.py ensure  --root DIR                 make sure a server of this version or newer runs
    gallery-server.py clients --root DIR                 print how many pages are connected

Each run is a directory DIR/runs/<run-id> written by display.sh in the tmux pane's layout:
meta.json, the status log, errors/<provider>.txt, active/<name>.<pid> tokens, .done and the
retry-offer / .retry pair.
"""

import argparse
import contextlib
import fcntl
import hmac
import http.server
import json
import os
import re
import secrets
import select
import shutil
import socket
import socketserver
import stat
import statistics
import subprocess
import sys
import threading
import time
import urllib.parse
from pathlib import Path

SCRIPT = Path(__file__).resolve()
PLUGIN_ROOT = SCRIPT.parent.parent
PAGE_DIR = SCRIPT.parent / "gallery"
# The control socket the client commands reach the server on, inside the gallery folder. It is
# named relative to that folder, from inside it, because a Unix socket's address holds at most
# 104 bytes on macOS and a gallery folder deep in a temp directory can be longer than that.
CONTROL_SOCKET = "server.sock"
IDLE_SECONDS = 30 * 60
SCAN_SECONDS = 0.25
PING_SECONDS = 15
KEEP_RUNS = 200
STALE_STAGING_SECONDS = 3600
OPEN_INTERVAL_SECONDS = 10
LAUNCH_SECONDS = 60
START_WAIT_SECONDS = 5
LOCK_WAIT_SECONDS = 5
ERROR_TEXT_LIMIT = 8192
USUAL_SAMPLES = 5
HOLDER_CHECK_SECONDS = 10
IN_FLIGHT = ("waiting", "querying", "retrying")
# The providers run-all.sh runs, which a resend may choose from.
RESEND_PROVIDERS = ("gemini", "openai", "xai", "openrouter")
# The generate tool's cap on a prompt (hooks/argv.ts), which a resend keeps to: a prompt travels as
# one program argument down to curl.
PROMPT_LIMIT_BYTES = 100000
# A resend's JSON body: a prompt at its limit, every character escaped to six bytes, fits.
RESEND_BODY_LIMIT = 6 * PROMPT_LIMIT_BYTES + 4096
# A delete's JSON body: every run the gallery keeps, each listing an image per resend provider at the
# longest path macOS allows with every byte escaped to six, fits.
DELETE_BODY_LIMIT = KEEP_RUNS * len(RESEND_PROVIDERS) * 6 * 1024 + 4096
BODY_READ_SECONDS = 10
# How long a resend waits for run-all.sh to make its run directory before it gives up waiting.
RESEND_START_SECONDS = 15
RESEND_LOGS_KEPT = 50
RESEND_ERROR_LINES = 8
# What a resent run-all.sh's environment drops from the server's: a tmux pane's, which it must not
# draw into, the run directory of the run-all that started the server, which it would write into
# instead of starting its own, and the switch that would keep it out of the gallery.
RESEND_DROPPED_ENV = ("DISPLAY_PANE_DIR", "TMUX", "TMUX_PANE", "SKIP_DISPLAY")
API_KEY_NAMES = ("GEMINI_API_KEY", "OPENAI_API_KEY", "XAI_API_KEY", "GROK_API_KEY", "OPENROUTER_API_KEY")
RUN_ID = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{10}$")
PROVIDER = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
# The endings of an image file the gallery may delete, after -<provider>.
IMAGE_EXTENSIONS = (".png", ".jpg", ".jpeg", ".webp", ".gif")
PAGE_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/app.css": ("app.css", "text/css; charset=utf-8"),
}
# The line of app.js that the server serving it rewrites to name its own version.
PAGE_VERSION_LINE = b"const PAGE_VERSION = '';\n"
SECURITY_HEADERS = {
    "Content-Security-Policy": "default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
}


def plugin_version():
    with open(PLUGIN_ROOT / ".claude-plugin" / "plugin.json", encoding="utf-8") as f:
        return json.load(f)["version"]


def version_order(version):
    """A calendar version, YYYY.M.PATCH, as the numbers its parts hold, for comparing versions: 2026.11.10
    comes after 2026.11.2. Any other string comes before every calendar version and ties with any
    other such string."""
    parts = re.fullmatch(r"([0-9]+)\.([0-9]+)\.([0-9]+)", version)
    return tuple(int(part) for part in parts.groups()) if parts else ()


def stamp_version(script, version):
    """app.js with its PAGE_VERSION line naming version, the version of the server that serves it."""
    if script.count(PAGE_VERSION_LINE) != 1:
        raise ValueError("app.js must hold the line %r exactly once" % PAGE_VERSION_LINE.decode())
    return script.replace(PAGE_VERSION_LINE, b"const PAGE_VERSION = %s;\n" % json.dumps(version).encode())


def write_private(path, text):
    """Writes text to path through a temp file and a rename, readable by this user only. A write that
    fails removes its temp file: a dot file left in a run's active/ would keep run-all from finishing
    the run."""
    tmp = path.with_name(".%s.%s" % (path.name, secrets.token_hex(4)))
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(str(tmp), str(path))
    except BaseException:
        os.unlink(str(tmp))
        raise


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


def on_deleted(p, ms, path):
    # The gallery deleted the frame: the run names its images no more.
    p["state"] = "deleted"
    p["images"] = []


# What each status record does to its provider. The record's model, when it names one, always
# becomes the provider's model.
TRANSITIONS = {
    "querying": on_querying,
    "retrying": on_retrying,
    "complete": on_complete,
    "error": on_error,
    "deleted": on_deleted,
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
    """True while a process of this user runs as pid. Another user's process there is not ours, and
    a pid too large for the system names no process."""
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError, OverflowError):
        return False
    return True


def process_started(pid):
    """When pid started, as ps -o lstart= prints it in the C locale and in UTC with its spaces
    collapsed, the way display.sh writes it into a token; None when ps knows no such process."""
    try:
        result = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], env=dict(os.environ, LC_ALL="C", TZ="UTC0"),
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=5)
    except (OSError, subprocess.TimeoutExpired) as e:
        print("image gallery: cannot run ps to check a run's holder: %s" % e, file=sys.stderr, flush=True)
        return None
    started = " ".join(result.stdout.decode(errors="replace").split())
    return started if result.returncode == 0 and started else None


# (pid, start time) of each token holder ps last confirmed, and when it did.
confirmed_holders = {}


def holder_alive(pid, started):
    """True while pid is still the process that wrote the token: this user's, and started when the
    token says. ps confirms the start time on first sight and every HOLDER_CHECK_SECONDS after."""
    key = (pid, started)
    if not started or not pid_alive(pid):
        confirmed_holders.pop(key, None)
        return False
    if time.monotonic() - confirmed_holders.get(key, -HOLDER_CHECK_SECONDS) < HOLDER_CHECK_SECONDS:
        return True
    if process_started(pid) == started:
        confirmed_holders[key] = time.monotonic()
        return True
    confirmed_holders.pop(key, None)
    return False


def forget_unchecked_holders():
    """Drops each holder no check has confirmed in HOLDER_CHECK_SECONDS. holder_alive asks ps again
    about those anyway, and a finished run's holders are never asked about again."""
    now = time.monotonic()
    for key, confirmed in list(confirmed_holders.items()):
        if now - confirmed >= HOLDER_CHECK_SECONDS:
            del confirmed_holders[key]


def hold_run(run_dir, pid):
    """Writes the token that run-all.sh, running as pid, writes for itself once it continues the run
    (gallery_resume_run, as owner run-all), so the run is held from the moment the server starts it. Any
    server reads it, as a server that replaces this one must: that one never learns what this one
    started. Raises OSError saying why when it writes no token: ps cannot say when pid started, or the
    token cannot be written."""
    started = process_started(pid)
    if started is None:
        raise OSError("ps could not say when the retry's run-all.sh started")
    active = run_dir / "active"
    active.mkdir(mode=0o700, exist_ok=True)
    write_private(active / ("run-all.%d" % pid), started + "\n")


def run_is_held(run_dir):
    """True while any process holding a token on the run is still alive. A token is named
    <name>.<pid> and holds its process's start time; a dot name is one still being written."""
    active = run_dir / "active"
    try:
        tokens = os.listdir(str(active))
    except (FileNotFoundError, NotADirectoryError):
        return False
    for token in tokens:
        pid = token.rsplit(".", 1)[-1]
        if token.startswith(".") or not pid.isdigit():
            continue
        # Only a regular file is a token. Anything else under the name is skipped before it is
        # opened: reading a directory raises, and reading a FIFO would block the scan for good.
        try:
            if not stat.S_ISREG(os.lstat(str(active / token)).st_mode):
                continue
            started = " ".join(read_text(active / token).split())
        except FileNotFoundError:
            continue
        if holder_alive(int(pid), started):
            return True
    return False


def fold_status(run_dir, providers):
    """Folds a run's status log into providers (reduce_status) as far as it parses. Returns why it does
    not parse past there, or None when it all does or the run has no status log yet."""
    try:
        reduce_status(read_status_log(run_dir), providers)
    except FileNotFoundError:
        pass
    except ValueError as e:
        return str(e)
    return None


def drop_cut_off_record(run_dir):
    """Drops a record cut off part way at the end of a run's status log, as a writer that died in the
    middle of one leaves it. No reader counts it and, its writer being gone, nothing will finish it, so
    a record appended after it would run on from it into one line that does not parse. Call it holding
    runs_lock before appending to a run no process works in: one no process holds, or one the server
    holds for a retry's run-all.sh that has not started yet. A provider that holds no
    token can still append to the log meanwhile, so a log that ends in a whole record is left as it is."""
    with open(str(run_dir / "status"), "r+b") as status:
        log = status.read()
        if log.endswith(b"\n") or not log:
            return
        # Bytes appended since the read have run on from the cut-off record and belong to another writer,
        # so they stay. A record can still land between this check and the truncate.
        if os.fstat(status.fileno()).st_size == len(log):
            status.truncate(log.rfind(b"\n") + 1)


def read_status_log(run_dir):
    """A run's status log as display.sh wrote it. A newline alone ends a record; a carriage return
    is part of a field, so line endings are not translated."""
    with open(str(run_dir / "status"), encoding="utf-8", errors="replace", newline="") as f:
        return f.read()


def status_size(run_dir):
    """How many bytes a run's status log holds: 0 before it exists. Only drop_cut_off_record shortens
    the log, under runs_lock: a frame's delete in a run no process holds, and a frame's retry once it
    holds the run, before it measures the log it then watches grow. A delete removes it only from a run
    neither held nor starting a retry."""
    try:
        return os.stat(str(run_dir / "status")).st_size
    except FileNotFoundError:
        return 0


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
    if "arguments" in meta:
        check_arguments(meta["arguments"])
    if "launch" in meta and not isinstance(meta["launch"], str):
        raise RunRejected("meta.json's launch is %s, not a string" % json.dumps(meta["launch"])[:80])
    return meta


def check_arguments(arguments):
    """Raises RunRejected naming the field unless arguments is what run-all.sh records of how it was
    started: its mode, its output base and input images as absolute paths, and a string of extra
    arguments for each provider. A run that recorded none has no arguments field at all."""
    def bad(field, value, wanted):
        return RunRejected("meta.json's arguments.%s is %s, not %s" % (field, json.dumps(value)[:80], wanted))
    if not isinstance(arguments, dict):
        raise RunRejected("meta.json's arguments is %s, not an object" % json.dumps(arguments)[:80])
    if arguments.get("mode") not in ("generate", "edit"):
        raise bad("mode", arguments.get("mode"), "generate or edit")
    base = arguments.get("output_base")
    if not isinstance(base, str) or not os.path.isabs(base):
        raise bad("output_base", base, "an absolute path")
    images = arguments.get("input_images")
    if not isinstance(images, list) or not all(isinstance(path, str) and os.path.isabs(path) for path in images):
        raise bad("input_images", images, "a list of absolute paths")
    if arguments["mode"] == "edit" and not images:
        raise bad("input_images", images, "at least one image for edit mode")
    extras = arguments.get("extras")
    if (not isinstance(extras, dict) or sorted(extras) != sorted(RESEND_PROVIDERS)
            or not all(isinstance(value, str) for value in extras.values())):
        raise bad("extras", extras, "a string for each of %s" % ", ".join(RESEND_PROVIDERS))


def retry_refusal(run_id, meta, providers, unreadable, held, name):
    """Why the failed frame of provider name cannot run again in its run, or None when it can: only once
    the run has ended, with no frame still at work when it did, only in a run run-all.sh started and
    recorded its arguments for, and only when the frame's last record is an error. providers and
    unreadable are what fold_status made of the run's status log; held, whether a process holds the run."""
    if unreadable is not None:
        return "run %s's status log is unreadable (%s), so how its frames ended is unknown" % (run_id, unreadable)
    if held:
        return "run %s is still generating" % run_id
    if name not in RESEND_PROVIDERS:
        return "%s is not a provider run-all.sh runs" % json.dumps(name)
    if "arguments" not in meta:
        return "run %s did not record the arguments it was started with, so its frames cannot be retried" % run_id
    at_work = [p["name"] for p in providers.values() if p["state"] in IN_FLIGHT]
    if at_work:
        return "run %s stopped while its %s frame was at work, so its frames cannot be retried" % (run_id, at_work[0])
    if providers[name]["state"] != "error":
        return "run %s's %s frame did not fail, so there is nothing to retry" % (run_id, name)
    return None


def read_run(run_dir, held):
    """The page's view of one run, held saying whether a process holds it. Raises RunRejected or OSError
    when the directory is not one."""
    meta = read_meta(run_dir)
    providers = {name: new_provider(name) for name in meta["providers"]}
    unreadable = fold_status(run_dir, providers)

    if (run_dir / ".done").exists():
        status = "done"
    elif held:
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
            # The offer stays open the seconds its first line names, from when run-all wrote it. A
            # wait of more than six digits is not one run-all writes, and would overflow a float.
            if re.fullmatch(r"[0-9]{1,6}", offer[0]):
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
            "retryable": retry_refusal(run_dir.name, meta, providers, unreadable, held, p["name"]) is None,
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
        "problem": None if unreadable is None else "unreadable status log: %s" % unreadable,
        "providers": cards,
        "files": [{"path": path, "provider": name} for name, path in unique_images(recorded_images(providers))],
        "input_images": meta["arguments"]["input_images"] if "arguments" in meta else [],
        "resendable": "arguments" in meta,
    }


# The files of a run whose change can change what the page shows of it.
RUN_FILES = ("", "meta.json", "status", "errors", "active", ".done", "retry-offer")


def run_files_state(run_dir):
    """What identifies the current contents of a run's files: unchanged until one of them is."""
    state = []
    base = str(run_dir)
    for name in RUN_FILES:
        try:
            st = os.stat(os.path.join(base, name))
            state.append((st.st_ino, st.st_mtime_ns, st.st_size))
        except OSError:
            state.append(None)
    return tuple(state)


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
            else:
                card.pop("usual_ms", None)


def image_path(runs_dir, run_id, provider, n):
    """The file of a provider's n-th image in a run, read from the run's status log, or None."""
    if not RUN_ID.match(run_id) or not PROVIDER.match(provider):
        return None
    run_dir = runs_dir / run_id
    providers = {}
    try:
        reduce_status(read_status_log(run_dir), providers)
    except (FileNotFoundError, ValueError):
        return None
    p = providers.get(provider)
    if p is None or n >= len(p["images"]):
        return None
    return p["images"][n]


def recorded_images(providers):
    """(provider, path) for each image a complete record names, in the order of the providers and
    of their records. A provider that completed again in a later round names each of its images."""
    return [(p["name"], path) for p in providers.values() for path in p["images"]]


def keep_reason(provider, path):
    """Why deleting the run whose complete record of provider names path as its image keeps the file
    there, or None when the file goes with the run. Only an absolute path whose file name ends in
    -<provider> and an image extension goes, and only while it is a file or a symlink, never a
    directory; a path already gone counts as gone with it."""
    if not PROVIDER.match(provider):
        return "its provider name %s is not one a run writes" % json.dumps(provider)
    if "\0" in path:
        return "its path holds a NUL character"
    if not os.path.isabs(path):
        return "not an absolute path"
    name = os.path.basename(path)
    if not any(name.endswith("-" + provider + extension) for extension in IMAGE_EXTENSIONS):
        return "its name does not end in -%s and .png, .jpg, .jpeg, .webp or .gif" % provider
    try:
        mode = os.lstat(path).st_mode
    except (FileNotFoundError, NotADirectoryError):
        return None
    except OSError as e:
        return e.strerror
    if not (stat.S_ISREG(mode) or stat.S_ISLNK(mode)):
        return "not a file"
    return None


def unique_images(images):
    """(provider, path) for each path images names, with the provider of its first record."""
    first = {}
    for name, path in images:
        first.setdefault(path, (name, path))
    return list(first.values())


def file_entry(path):
    """What tells the file at path from every other file, however its path is spelled: the device
    and inode os.stat finds there. A file named through a symlinked folder, with a doubled slash or
    through a symlink to it is one entry, so a run never deletes the file or link another run's
    image needs. A path that is relative, holds a NUL or has nothing there to stat is an entry of its
    own."""
    if "\0" in path or not os.path.isabs(path):
        return ("path", path)
    try:
        st = os.stat(path)
    except OSError:
        return ("path", path)
    return ("file", st.st_dev, st.st_ino)


def mark_files(runs):
    """Gives each file a run names kept: why deleting the run would keep it (keep_reason, or the newest
    other run of runs using it as an input image), or None; and entry: a number the files of runs
    share when they are one file on disk (file_entry), however their paths are spelled. Read on every
    scan, since a file can change while the runs' own files do not. runs are newest first."""
    inputs = {}
    for run in runs:
        for path in run["input_images"]:
            inputs.setdefault(file_entry(path), []).append(run["id"])
    entries = {}
    for run in runs:
        for f in run["files"]:
            entry = file_entry(f["path"])
            users = [name for name in inputs.get(entry, []) if name != run["id"]]
            f["kept"] = keep_reason(f["provider"], f["path"])
            if f["kept"] is None and users:
                f["kept"] = "run %s uses it as an input image" % users[0]
            f["entry"] = entries.setdefault(entry, len(entries))


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


class Refusal(Exception):
    """Why the gallery does not do what the page asked: the HTTP status, and the error the page shows."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def check_places(run_id, meta):
    """Raises Refusal naming what is gone when the working folder, the image folder or an input image
    of a run that recorded its arguments is no longer there, since run-all.sh cannot run again
    without them."""
    arguments = meta["arguments"]
    for path, what in ((meta["cwd"], "working folder"), (os.path.dirname(arguments["output_base"]), "image folder")):
        if not os.path.isdir(path):
            raise Refusal(409, "run %s's %s %s is gone" % (run_id, what, path))
    for path in arguments["input_images"]:
        if not os.path.isfile(path):
            raise Refusal(409, "run %s's input image %s is gone" % (run_id, path))


def run_all_argv(arguments, prompt, base, providers):
    """The command that runs run-all.sh with a run's recorded arguments, prompt and providers, saving
    under base."""
    argv = ["bash", str(SCRIPT.parent / "run-all.sh"), "--mode", arguments["mode"], "--prompt", prompt,
            "--output-base", base, "--providers", ",".join(providers)]
    for path in arguments["input_images"]:
        argv += ["--input-image", path]
    for name in providers:
        if arguments["extras"][name]:
            argv += ["--%s-extra" % name, arguments["extras"][name]]
    return argv


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
        self.changed = threading.Condition()
        self.snapshot = json.dumps({"instance": self.instance, "version": version, "runs": []})
        self.clients = 0
        self.stop = threading.Event()
        self.last_open = 0.0
        self.opening = threading.Lock()
        self.launch_codes = {}
        # Held while the runs folder is scanned or a run deleted, so neither sees the other's
        # half-done work and the request threads never touch read_runs during a scan.
        self.runs_lock = threading.Lock()
        self.read_runs = {}
        # The output base of each resent run-all.sh not yet reaped, mapped to its process. Held only
        # to check and claim a base, never while a child runs: the child's own ensure calls back.
        self.resend_lock = threading.Lock()
        self.resends = {}
        self.page = {}
        for route, (name, ctype) in PAGE_FILES.items():
            self.page[route] = ((PAGE_DIR / name).read_bytes(), ctype)
        script, ctype = self.page["/app.js"]
        self.page["/app.js"] = (stamp_version(script, version), ctype)

    def scan(self):
        """Reads every run whose files changed or whose holder went away, newest first, prunes
        beyond KEEP_RUNS and publishes a change."""
        with self.runs_lock:
            return self.scan_runs()

    def scan_runs(self):
        forget_unchecked_holders()
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
            if index >= KEEP_RUNS and not run_is_held(run_dir):
                shutil.rmtree(str(run_dir), ignore_errors=True)
                continue
            run = self.run(run_dir)
            if run is not None:
                runs.append(run)
        for name in set(self.read_runs) - set(names):
            del self.read_runs[name]
        add_usual_times(runs)
        mark_files(runs)
        snapshot = json.dumps({"instance": self.instance, "version": self.version, "runs": runs})
        if snapshot != self.snapshot:
            with self.changed:
                self.snapshot = snapshot
                self.changed.notify_all()
        return any(run["status"] == "live" for run in runs)

    def run(self, run_dir):
        """The page's view of a run, or None for a rejected one. A run is read again only once one
        of its files changed, or, when a process held it as it was read, once none does any more: a
        retry's run-all.sh that the server held a finished run for can exit before it continues it."""
        files = run_files_state(run_dir)
        known = self.read_runs.get(run_dir.name)
        if known is not None and known[0] == files:
            run, held = known[1], known[2]
            if run is None or not held or run_is_held(run_dir):
                return run
        self.read_runs[run_dir.name] = (files, None, False)
        held = run_is_held(run_dir)
        try:
            run = read_run(run_dir, held)
        except RunRejected as e:
            self.reject(run_dir, str(e))
            return None
        except OSError as e:
            self.reject(run_dir, "%s: %s" % (os.path.basename(e.filename or run_dir.name), e.strerror))
            return None
        self.read_runs[run_dir.name] = (files, run, held)
        return run

    def image_namers(self):
        """Each file a run in the gallery names as its image or uses as an input image, by its
        file_entry, mapped to the ids of those runs, oldest first, each with why deleting another run
        keeps the file for it. Raises RunRejected naming a run whose status log or meta.json does not
        parse, and OSError naming one that cannot be read: either way the files that run needs are
        unknown. Call it holding runs_lock."""
        namers = {}
        for name in sorted(os.listdir(str(self.runs_dir))):
            if not RUN_ID.match(name):
                continue
            run_dir = self.runs_dir / name
            providers = {}
            unreadable = fold_status(run_dir, providers)
            if unreadable is not None:
                raise RunRejected("run %s's status log is unreadable (%s), so which images it names is unknown"
                                  % (name, unreadable))
            try:
                meta = read_meta(run_dir)
            except RunRejected as e:
                raise RunRejected("run %s cannot be read: %s, so which images it uses is unknown" % (name, e))
            uses = [(path, "run %s names it too" % name) for provider, path in unique_images(recorded_images(providers))]
            if "arguments" in meta:
                uses += [(path, "run %s uses it as an input image" % name) for path in meta["arguments"]["input_images"]]
            for path, reason in uses:
                namers.setdefault(file_entry(path), {}).setdefault(name, reason)
        return namers

    def deletable(self, run_id):
        """The directory and folded status log (reduce_status) of a run whose images may be deleted
        now: one in the gallery that no process holds, no frame's retry is starting in, and whose
        status log parses. Raises Refusal saying why not."""
        run_dir = self.runs_dir / run_id
        if not RUN_ID.match(run_id) or not run_dir.is_dir():
            raise Refusal(404, "no run %s" % run_id)
        # A run's retry offer is open only while run-all holds the run, so this keeps an open offer
        # too; an offer a killed run-all left behind does not keep its run.
        if run_is_held(run_dir):
            raise Refusal(409, "run %s is still generating" % run_id)
        # A frame's retry also claims the run's output base as the server starts run-all.sh, which keeps
        # the run while that run-all.sh runs though its token does not: ps cannot confirm the token's
        # holder, or the token is gone.
        arguments = read_meta(run_dir).get("arguments")
        if arguments is not None and self.saving_to(arguments["output_base"]):
            raise Refusal(409, "run %s is starting a retry" % run_id)
        providers = {}
        unreadable = fold_status(run_dir, providers)
        if unreadable is not None:
            raise Refusal(409, "run %s's status log is unreadable (%s), so which images it saved is unknown; "
                               "nothing was deleted" % (run_id, unreadable))
        return run_dir, providers

    def remove_images(self, run_id, images, listed, namers):
        """Deletes each of images, (provider, path) pairs run run_id's complete records name, that the
        page listed in listed, keep_reason lets go and no other run in namers (image_namers) names or
        uses as an input image, by any path. Every other one stays, and so does every listed path that
        images does not name: the page's list only narrows what goes. Returns the paths removed, those
        already gone and those kept with why, and the error that stopped it part way, or None."""
        removed = []
        missing = []
        kept = []
        for provider, path in images:
            reason = keep_reason(provider, path)
            others = [why for name, why in namers.get(file_entry(path), {}).items() if name != run_id]
            if reason is None and others:
                reason = others[-1]
            if reason is None and path not in listed:
                reason = "the delete did not list it"
            if reason is not None:
                kept.append({"path": path, "reason": reason})
                continue
            try:
                os.unlink(path)
                removed.append(path)
            except (FileNotFoundError, NotADirectoryError):
                missing.append(path)
            except OSError as e:
                return {"removed": removed, "missing": missing, "kept_files": kept}, "could not delete %s: %s" % (path, e.strerror)
        named = {path for provider, path in images}
        for path in dict.fromkeys(listed):
            if path not in named:
                kept.append({"path": path, "reason": "run %s's records do not name it" % run_id})
        return {"removed": removed, "missing": missing, "kept_files": kept}, None

    def delete(self, run_id, listed, namers):
        """Deletes a run: the image files of its complete records that remove_images lets go, then its
        directory. Answers (HTTP status, outcome): 200 with the paths removed, those already gone and
        those kept with why, or the error that kept the run in place. A deleted run leaves namers.
        Call it holding runs_lock."""
        try:
            run_dir, providers = self.deletable(run_id)
        except Refusal as e:
            return e.code, {"id": run_id, "error": str(e)}
        outcome, error = self.remove_images(run_id, unique_images(recorded_images(providers)), listed, namers)
        if error is not None:
            return 500, {"id": run_id, "error": "%s; the run is kept" % error, **outcome}
        shutil.rmtree(str(run_dir), ignore_errors=True)
        if os.path.lexists(str(run_dir)):
            return 500, {"id": run_id, "error": "could not remove the run's folder %s" % run_dir, **outcome}
        for users in namers.values():
            users.pop(run_id, None)
        return 200, {"id": run_id, **outcome}

    def delete_frame(self, run_id, provider, listed, namers):
        """Deletes one frame of a run: the image files its provider's complete records name that
        remove_images lets go, then appends a deleted record for it to the run's status log. The run
        names those files no more, and the frame shows as deleted, after a restart too. Answers
        (HTTP status, outcome) as delete does, the outcome naming the provider as well. Call it
        holding runs_lock."""
        try:
            run_dir, providers = self.deletable(run_id)
            frame = providers.get(provider)
            if frame is None:
                raise Refusal(404, "run %s has no %s frame" % (run_id, provider))
            if not frame["images"]:
                raise Refusal(409, "run %s's %s frame has no image to delete" % (run_id, provider))
        except Refusal as e:
            return e.code, {"id": run_id, "provider": provider, "error": str(e)}
        outcome, error = self.remove_images(run_id, unique_images([(provider, path) for path in frame["images"]]), listed, namers)
        if error is not None:
            return 500, {"id": run_id, "provider": provider, "error": "%s; the frame is kept" % error, **outcome}
        try:
            drop_cut_off_record(run_dir)
            with open(str(run_dir / "status"), "ab") as status:
                status.write(("%s\tdeleted\t\t\t\n" % provider).encode())
        except OSError as e:
            return 500, {"id": run_id, "provider": provider,
                         "error": "could not record the %s frame as deleted in %s: %s" % (provider, run_dir / "status", e.strerror),
                         **outcome}
        return 200, {"id": run_id, "provider": provider, **outcome}

    def run_meta(self, run_id):
        """The directory and meta.json of a run in the gallery, or Refusal saying why there is none."""
        run_dir = self.runs_dir / run_id
        if not RUN_ID.match(run_id) or not run_dir.is_dir():
            raise Refusal(404, "no run %s" % run_id)
        try:
            return run_dir, read_meta(run_dir)
        except RunRejected as e:
            raise Refusal(409, "run %s cannot be read: %s" % (run_id, e))
        except OSError as e:
            raise Refusal(409, "run %s cannot be read: %s: %s" % (run_id, e.filename, e.strerror))

    def resend(self, run_id, prompt, providers):
        """Starts run-all.sh again for a run that recorded its arguments, with prompt and providers in
        place of its own, saving in the folder of the run's output base under a fresh image-<stamp>
        base. Answers (HTTP status, body) as await_run does, or with why none was started."""
        try:
            meta = self.run_meta(run_id)[1]
            arguments = meta.get("arguments")
            if arguments is None:
                raise Refusal(409, "run %s did not record the arguments it was started with, so it cannot be resent" % run_id)
            check_places(run_id, meta)
            base = os.path.join(os.path.dirname(arguments["output_base"]), "image-" + time.strftime("%Y%m%d-%H%M%S"))
            launch = secrets.token_hex(8)
            started = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(time.time() - 1))
            child, log_path = self.launch_run_all(run_all_argv(arguments, prompt, base, providers), meta["cwd"], base,
                                                  providers, launch)
        except Refusal as e:
            return e.code, {"error": str(e)}
        return self.await_run(child, log_path, lambda: self.resent_run(launch, started), {"pending": True, "launch": launch})

    def retry_frame(self, run_id, name):
        """Runs the failed frame of provider name again in its own run: run-all.sh with the run's own
        prompt and arguments, saving to <output base>-<name>.png, the file the run first meant to
        save, and adding its records to the run's status log, so the frame shows the retry as it
        goes. retry_refusal says which frames may. Answers (HTTP status, body) as await_run does, the
        run having started once its status log grows, or with why none was started."""
        try:
            # Held while the run is checked and run-all.sh claims its output base and holds the run, so a
            # delete either comes first, and there is no run to retry, or finds the run held and keeps it.
            with self.runs_lock:
                run_dir, meta = self.run_meta(run_id)
                if name not in meta["providers"]:
                    raise Refusal(404, "run %s has no %s frame" % (run_id, name))
                providers = {provider: new_provider(provider) for provider in meta["providers"]}
                unreadable = fold_status(run_dir, providers)
                refusal = retry_refusal(run_id, meta, providers, unreadable, run_is_held(run_dir), name)
                if refusal is not None:
                    raise Refusal(409, refusal)
                check_places(run_id, meta)
                arguments = meta["arguments"]
                base = arguments["output_base"]
                argv = run_all_argv(arguments, meta["prompt"], base, [name]) + ["--gallery-run", run_id]
                # run-all.sh waits behind a line on its stdin, which the server writes once the run is held
                # for it. The pipe closing with no line, when the run cannot be held or the server stops,
                # ends it before it calls the provider. exec keeps the pid the token names.
                gated = ["bash", "-c", 'read -r go && exec "$@" < /dev/null', "bash"] + argv
                child, log_path = self.launch_run_all(gated, meta["cwd"], base, [name], None, stdin=subprocess.PIPE)
                with child.stdin:
                    try:
                        hold_run(run_dir, child.pid)
                    except OSError as e:
                        raise Refusal(500, "could not hold run %s for its retry (%s), so the retry stopped before it "
                                           "called the provider" % (run_id, e))
                    # Only a retry that holds its run, and so starts, readies the log for its records: a refused
                    # one leaves the log as it was.
                    try:
                        drop_cut_off_record(run_dir)
                    except OSError as e:
                        raise Refusal(500, "could not ready run %s's status log %s for the retry: %s"
                                      % (run_id, run_dir / "status", e.strerror))
                    size = status_size(run_dir)
                    try:
                        os.write(child.stdin.fileno(), b"go\n")
                    except BrokenPipeError:
                        # run-all.sh has exited already; await_run answers with how it exited.
                        pass
        except Refusal as e:
            return e.code, {"error": str(e)}
        return self.await_run(child, log_path, lambda: run_id if status_size(run_dir) > size else None, {"pending": True})

    def saving_to(self, base):
        """True while a run-all.sh the server started saves under base."""
        with self.resend_lock:
            return base in self.resends

    def launch_run_all(self, argv, cwd, base, providers, launch, stdin=subprocess.DEVNULL):
        """Starts run-all.sh with argv in cwd, its stdin as given, saving each of providers to
        <base>-<provider>.png, and returns it with the file its output goes to. It runs as
        resend_environment makes it, in a session of its own, its images readable by this user only,
        and the server reaps it. Raises Refusal, starting nothing, while another run-all.sh the server
        started saves to base, or when any of those files already exists."""
        with self.resend_lock:
            outputs = ["%s-%s.png" % (base, name) for name in providers]
            if base in self.resends:
                raise Refusal(409, "a run saving to %s-<provider>.png is already starting; try again in a second" % base)
            taken = [path for path in outputs if os.path.lexists(path)]
            if taken:
                raise Refusal(409, "%s already exists, and nothing is overwritten" % taken[0])
            log_path = self.resend_log()
            try:
                # The server cannot know the umask of the run it resends, so the images are saved
                # readable by this user only, as the gallery's own files are.
                with open(str(log_path), "ab") as log:
                    child = subprocess.Popen(argv, cwd=cwd, env=self.resend_environment(cwd, launch), stdin=stdin,
                                             stdout=log, stderr=subprocess.STDOUT, start_new_session=True, umask=0o077)
            except OSError as e:
                raise Refusal(500, "could not start run-all.sh: %s" % e.strerror)
            self.resends[base] = child
        threading.Thread(target=self.reap, args=(base, child), daemon=True).start()
        return child, log_path

    def await_run(self, child, log_path, found, pending):
        """Waits for a run-all.sh launch_run_all started to start its run, which found() names once
        it has, or None before. Answers (HTTP status, body): 200 naming the run, 502 when run-all.sh
        exited before it started one, or 202 with pending when it is still starting after
        RESEND_START_SECONDS."""
        deadline = time.monotonic() + RESEND_START_SECONDS
        while True:
            # Whether it exited is read before the runs are, so a child that made its run and exited
            # in between is still found.
            code = child.returncode
            run_id = found()
            if run_id is not None:
                self.scan()
                return 200, {"run": run_id}
            if code is not None:
                return 502, {"error": "run-all.sh exited %d before it started a run: %s" % (code, self.log_tail(log_path))}
            if time.monotonic() > deadline:
                # Only a run-all.sh that exited has failed. One still starting may yet start its run,
                # which the page then shows; calling it failed would invite the page to pay again.
                return 202, pending
            time.sleep(0.05)

    def resend_environment(self, cwd, launch):
        """The server's environment, which holds the API keys of the run-all.sh that started it, as a
        run-all.sh the page starts gets it: in cwd, showing its run in this gallery and nowhere else,
        and, given a launch id, recording it in the new run's meta.json so the server can find it. A
        frame's retry starts no new run, so it gets none, not even one the server inherited."""
        env = {name: value for name, value in os.environ.items() if name not in RESEND_DROPPED_ENV}
        # Bash keeps an inherited PWD that names its working folder, so the new run records the
        # folder spelled as the run it resends did, symlinks and all, and lands in the same project.
        env.update(PWD=cwd, IMAGE_DISPLAY="gallery", IMAGE_GALLERY_DIR=str(self.root),
                   DISPLAY_IMAGE_TARGET="/dev/null", IMAGE_GALLERY_NO_OPEN="1")
        if launch is None:
            env.pop("IMAGE_GALLERY_LAUNCH_ID", None)
        else:
            env["IMAGE_GALLERY_LAUNCH_ID"] = launch
        return env

    def resend_log(self):
        """A fresh file in the gallery folder for one resent run-all.sh's output, keeping only the
        newest RESEND_LOGS_KEPT of them."""
        logs = self.root / "resend-logs"
        logs.mkdir(mode=0o700, exist_ok=True)
        path = logs / ("%s-%s.log" % (time.strftime("%Y%m%d-%H%M%S"), secrets.token_hex(4)))
        os.close(os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
        for old in sorted(os.listdir(str(logs)))[:-RESEND_LOGS_KEPT]:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(str(logs / old))
        return path

    def log_tail(self, path):
        """The last lines of a resend's output, with every API key the server holds hidden."""
        text = read_text(path)[-ERROR_TEXT_LIMIT:]
        for name in API_KEY_NAMES:
            key = os.environ.get(name, "")
            if key:
                text = text.replace(key, "[%s]" % name)
        lines = [line for line in text.splitlines() if line.strip()][-RESEND_ERROR_LINES:]
        return "\n".join(lines) if lines else "it printed nothing"

    def resent_run(self, launch, started):
        """The id of the run that recorded the launch id launch, looked for among the runs started
        since started, or None while there is none. Another run can record the same output base."""
        for name in sorted(os.listdir(str(self.runs_dir)), reverse=True):
            if not RUN_ID.match(name):
                continue
            if name[:16] < started:
                break
            try:
                meta = read_meta(self.runs_dir / name)
            except (RunRejected, OSError):
                continue
            if meta.get("launch") == launch:
                return name
        return None

    def reap(self, base, child):
        """Waits for a resent run-all.sh, so it leaves no zombie, and frees its output base."""
        child.wait()
        with self.resend_lock:
            del self.resends[base]

    def resending(self):
        with self.resend_lock:
            return bool(self.resends)

    def reject(self, run_dir, reason):
        """Leaves a run directory out of the snapshot, naming it in server.log."""
        print("image gallery: skipping run %s: %s" % (run_dir, reason), file=sys.stderr, flush=True)

    def launch_url(self):
        """A one-time address that sends a browser on to the page. The browser is opened with this
        instead of the page's own address, which carries the token, because a command's arguments
        are visible to every user of the machine. Whoever fetches the code first gets the page: a
        process that reads it from the arguments and beats the browser to it leaves the browser a
        403, which the user sees."""
        now = time.time()
        for code, expires in list(self.launch_codes.items()):
            if expires < now:
                self.launch_codes.pop(code, None)
        code = secrets.token_urlsafe(16)
        self.launch_codes[code] = now + LAUNCH_SECONDS
        return "%s/launch/%s" % (self.origin, code)

    def open_page(self):
        """Opens the page in the browser at most once per OPEN_INTERVAL_SECONDS. True when a
        browser was opened now or a moment ago. Runs that ask together take turns, so the second
        finds the page the first opened."""
        with self.opening:
            if time.time() - self.last_open < OPEN_INTERVAL_SECONDS:
                return True
            if sys.platform == "darwin":
                command = ["open", "-g", self.launch_url()]
            elif shutil.which("xdg-open") and (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
                command = ["xdg-open", self.launch_url()]
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

    def host_allowed(self):
        """Answers 403 and returns False unless the request is addressed to this server."""
        if self.headers.get("Host") != "127.0.0.1:%d" % self.gallery.port:
            self.send_json(403, {"error": "wrong Host header; open the page at %s" % self.gallery.origin})
            return False
        return True

    def route(self, post):
        """The path below /<token>/, or None after a 403 when the request does not come from this
        user's page: the path must start with the token, and a POST must carry the page's Origin."""
        given, slash, rest = urllib.parse.urlsplit(self.path).path[1:].partition("/")
        if not slash or not hmac.compare_digest(given.encode(), self.gallery.token.encode()):
            self.send_json(403, {"error": "missing or wrong token; open the address the image tool printed"})
            return None
        if post and self.headers.get("Origin") != self.gallery.origin:
            self.send_json(403, {"error": "wrong Origin header"})
            return None
        return "/" + rest

    def do_GET(self):
        if not self.host_allowed():
            return
        path = urllib.parse.urlsplit(self.path).path
        if path == "/favicon.ico":
            self.send_response(204)
            self.end_headers()
            return
        if path.startswith("/launch/"):
            self.launch(path[len("/launch/"):])
            return
        route = self.route(post=False)
        if route is None:
            return
        if route in self.gallery.page:
            body, ctype = self.gallery.page[route]
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif route == "/events":
            self.events()
        elif route.startswith("/img/"):
            self.image(route)
        else:
            self.send_json(404, {"error": "no such page: %s" % route})

    def do_POST(self):
        # Only a resend and a delete take a body, read once the request is known to come from the page.
        # Any other action's body is never read: one that is declared is refused at once, however large
        # it says it is or however slowly it arrives.
        if not self.host_allowed():
            return
        route = self.route(post=True)
        if route is None:
            return
        segments = route.strip("/").split("/")
        if segments[0] == "resend" and len(segments) == 2:
            self.resend(segments[1])
            return
        if segments == ["delete"]:
            self.delete()
            return
        if segments[0] == "delete" and len(segments) == 3:
            self.delete_frame(segments[1], segments[2])
            return
        if self.headers.get("Content-Length", "0") != "0" or "Transfer-Encoding" in self.headers:
            self.send_json(413, {"error": "these actions take no request body"})
            return
        if segments[0] == "reveal" and len(segments) == 4:
            self.reveal(segments[1:])
        elif segments[0] == "retry" and len(segments) == 2:
            self.retry(segments[1])
        elif segments[0] == "retry" and len(segments) == 3:
            self.send_json(*self.gallery.retry_frame(segments[1], segments[2]))
        else:
            self.send_json(404, {"error": "no such action: %s" % route})

    def launch(self, code):
        """Sends a browser opened at a one-time address on to the page, once."""
        expires = self.gallery.launch_codes.pop(code, None)
        if expires is None or expires < time.time():
            self.send_json(403, {"error": "this address opens the page once, within a minute; "
                                          "the next image run opens a fresh one"})
            return
        self.send_response(303)
        self.send_header("Location", "/%s/" % self.gallery.token)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

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

    def resend(self, run_id):
        """Starts a run again from the page's editor. The body is JSON naming the prompt and the
        providers; the answer names the new run, or why none started."""
        try:
            prompt, providers = parse_resend(self.read_body(RESEND_BODY_LIMIT, "resend"))
        except ValueError as e:
            self.send_json(400, {"error": str(e)})
            return
        except BodyRefused as e:
            self.send_json(e.code, {"error": str(e)})
            return
        code, body = self.gallery.resend(run_id, prompt, providers)
        self.send_json(code, body)

    def read_body(self, limit, action):
        """The request's body, of the length it declares and at most limit bytes, read within
        BODY_READ_SECONDS."""
        if "Transfer-Encoding" in self.headers:
            raise BodyRefused(411, "send the body with a Content-Length")
        length = self.headers.get("Content-Length", "")
        if not length.isdigit():
            raise BodyRefused(411, "send the body with a Content-Length")
        if int(length) > limit:
            raise BodyRefused(413, "the body is %s bytes; a %s's is at most %d" % (length, action, limit))
        self.connection.settimeout(BODY_READ_SECONDS)
        try:
            body = self.rfile.read(int(length))
        except socket.timeout:
            raise BodyRefused(408, "the body did not arrive within %d s" % BODY_READ_SECONDS)
        if len(body) != int(length):
            raise BodyRefused(400, "the body ended after %d of %s bytes" % (len(body), length))
        return body

    def delete(self):
        """Deletes each run the page's JSON body names that may go, with the files the page listed for
        it, and publishes the change, answering as answer_deletes does."""
        try:
            runs = parse_delete(self.read_body(DELETE_BODY_LIMIT, "delete"))
        except ValueError as e:
            self.send_json(400, {"error": str(e)})
            return
        except BodyRefused as e:
            self.send_json(e.code, {"error": str(e)})
            return
        self.answer_deletes([lambda namers, run_id=run_id, listed=listed: self.gallery.delete(run_id, listed, namers)
                             for run_id, listed in runs.items()])

    def delete_frame(self, run_id, provider):
        """Deletes one frame of a run with the files the page's JSON body lists for it, and publishes
        the change, answering as answer_deletes does."""
        try:
            listed = parse_delete_frame(self.read_body(DELETE_BODY_LIMIT, "delete"))
        except ValueError as e:
            self.send_json(400, {"error": str(e)})
            return
        except BodyRefused as e:
            self.send_json(e.code, {"error": str(e)})
            return
        self.answer_deletes([lambda namers: self.gallery.delete_frame(run_id, provider, listed, namers)])

    def answer_deletes(self, deletes):
        """Runs each of deletes, a function of image_namers' map answering (HTTP status, outcome), holding
        runs_lock, and publishes the change. Answers which were deleted, with their files, and which
        were kept and why: 200 when any was deleted, else the status of what kept them, 404 when none
        named exists. Nothing is deleted when a run in the gallery cannot be read."""
        outcomes = []
        with self.gallery.runs_lock:
            try:
                namers = self.gallery.image_namers()
            except RunRejected as e:
                self.send_json(409, {"error": "%s; nothing was deleted" % e})
                return
            except OSError as e:
                self.send_json(500, {"error": "could not read %s: %s, so which runs share an image is unknown; "
                                              "nothing was deleted" % (e.filename, e.strerror)})
                return
            for delete in deletes:
                outcomes.append(delete(namers))
        self.gallery.scan()
        deleted = [outcome for code, outcome in outcomes if code == 200]
        kept = [outcome for code, outcome in outcomes if code != 200]
        if deleted:
            self.send_json(200, {"deleted": deleted, "kept": kept})
            return
        codes = {code for code, outcome in outcomes}
        code = 500 if 500 in codes else 409 if 409 in codes else 404
        self.send_json(code, {"deleted": deleted, "kept": kept, "error": kept[0]["error"]})



class BodyRefused(Exception):
    """A request body the server will not read, with the HTTP status that says why."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def parse_delete(body):
    """The runs a delete's JSON body names, each mapped to the paths of the files the page listed as
    going with it, or ValueError saying what is wrong with them."""
    try:
        request = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        raise ValueError("the body is not JSON: %s" % e)
    runs = request.get("runs") if isinstance(request, dict) and sorted(request) == ["runs"] else None
    if not isinstance(runs, dict) or not runs:
        raise ValueError("the body must be an object with runs, each run's id mapped to the paths the page listed for it")
    for run_id, paths in runs.items():
        if not isinstance(paths, list) or not all(isinstance(path, str) for path in paths):
            raise ValueError("run %s's paths are %s, not a list of paths" % (json.dumps(run_id)[:80], json.dumps(paths)[:80]))
    return runs


def parse_delete_frame(body):
    """The paths of the files a frame's delete lists as going with it, or ValueError saying what is
    wrong with them."""
    try:
        request = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        raise ValueError("the body is not JSON: %s" % e)
    paths = request.get("paths") if isinstance(request, dict) and sorted(request) == ["paths"] else None
    if not isinstance(paths, list) or not all(isinstance(path, str) for path in paths):
        raise ValueError("the body must be an object with paths, the files the page listed for the frame")
    return paths


def parse_resend(body):
    """The prompt and providers a resend's JSON body names, or ValueError saying what is wrong with
    them. The same rules as the generate tool's: a prompt that is not blank, has no NUL and fits in
    PROMPT_LIMIT_BYTES, and one or more of RESEND_PROVIDERS, each once."""
    try:
        request = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        raise ValueError("the body is not JSON: %s" % e)
    if not isinstance(request, dict) or sorted(request) != ["prompt", "providers"]:
        raise ValueError("the body must be an object with prompt and providers, got %s" % body[:80].decode("utf-8", "replace"))
    prompt, providers = request["prompt"], request["providers"]
    if not isinstance(prompt, str) or not prompt.strip():
        raise ValueError("the prompt is blank")
    if "\0" in prompt:
        raise ValueError("the prompt holds a NUL character, which no program argument can carry")
    try:
        size = len(prompt.encode("utf-8"))
    except UnicodeEncodeError:
        raise ValueError("the prompt holds a lone surrogate, which is not text a program argument can carry")
    if size > PROMPT_LIMIT_BYTES:
        raise ValueError("the prompt is %d bytes; the most a prompt can carry to the providers is %d bytes"
                         % (size, PROMPT_LIMIT_BYTES))
    if not isinstance(providers, list) or not providers:
        raise ValueError("choose at least one provider")
    for name in providers:
        if name not in RESEND_PROVIDERS:
            raise ValueError("unknown provider %s; choose from %s" % (json.dumps(name), ", ".join(RESEND_PROVIDERS)))
    if len(set(providers)) != len(providers):
        raise ValueError("a provider is named twice; each provider runs once and saves one file")
    return prompt, providers


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

    def server_bind(self):
        # HTTPServer.server_bind looks the host name up, which can stall on a reverse lookup of
        # 127.0.0.1; the name is never used.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


class ControlHandler(socketserver.StreamRequestHandler):
    """Answers one command from a client command on the control socket: a line naming it, and for
    shutdown the pid it is meant for, answered with one line of JSON. Only this user can reach the
    socket, so a command carries no token."""
    timeout = 5

    def handle(self):
        gallery = self.server.gallery
        try:
            line = self.rfile.readline(64)
        except socket.timeout:
            # A client that sends no command within the timeout gets no answer.
            return
        command, _, argument = line.decode(errors="replace").strip().partition(" ")
        if command == "health":
            answer = {"pid": os.getpid(), "port": gallery.port, "token": gallery.token,
                      "version": gallery.version, "clients": gallery.clients}
        elif command == "open":
            answer = {"opened": gallery.open_page()}
        elif command == "shutdown":
            # Names the pid of the server the caller read health from. Another run may have
            # replaced that server since, and its successor is not the one the caller meant.
            answer = {"stopping": argument == str(os.getpid())}
        else:
            answer = {"error": "no such command: %r" % command}
        try:
            self.wfile.write(json.dumps(answer).encode() + b"\n")
        except (BrokenPipeError, ConnectionResetError):
            # The client stopped waiting, as one does after 15 s on a browser slow to open, and
            # nothing is left to answer. What it asked for still happens.
            pass
        # Only once the answer is sent: the main thread exits as soon as it sees the stop.
        if answer.get("stopping"):
            gallery.stop.set()


class ControlServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


def refuse_other_file():
    """Raises when something other than a socket has the control socket's name in the current
    folder. In a folder the user chose it may be a file of theirs, so it is never connected to or
    removed."""
    try:
        mode = os.lstat(CONTROL_SOCKET).st_mode
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(mode):
        raise OSError("%s is not a socket; move it so the server can make its control socket there"
                      % os.path.abspath(CONTROL_SOCKET))


def bind_control(root):
    """Binds the control socket, readable and writable by this user only. The caller holds
    server.lock, so a socket already there is one a dead server left."""
    os.chdir(str(root))
    refuse_other_file()
    try:
        os.unlink(CONTROL_SOCKET)
    except FileNotFoundError:
        pass
    control = ControlServer(CONTROL_SOCKET, ControlHandler)
    os.chmod(CONTROL_SOCKET, 0o600)
    os.chdir("/")
    return control


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
    try:
        control = bind_control(root)
    except OSError as e:
        sys.exit("image gallery: %s" % e)
    control.gallery = gallery
    threading.Thread(target=control.serve_forever, daemon=True).start()
    busy_at = time.time()
    while not gallery.stop.wait(SCAN_SECONDS):
        if gallery.scan() or gallery.clients > 0 or gallery.resending():
            busy_at = time.time()
        elif time.time() - busy_at > IDLE_SECONDS:
            # A run may have begun since the scan that found none live; look once more.
            if not gallery.scan() and gallery.clients == 0 and not gallery.resending():
                break
    # A frame's retry holds runs_lock from starting run-all.sh until the run is held for it, so the
    # server stops between retries, never with one started that no server knows of.
    gallery.runs_lock.acquire()
    # Gone before the server stops answering, and while this process still holds server.lock, so
    # the socket is never a successor's.
    os.unlink(str(root / CONTROL_SOCKET))
    control.server_close()
    httpd.server_close()
    os._exit(0)


# ── Client ────────────────────────────────────────────────────────────


def control(root, command, timeout=2):
    """Sends a command to the server serving root over its control socket and returns its answer,
    or None when no server listens there. The socket is reached by its name from inside root, so
    this process moves into root."""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        try:
            os.chdir(str(root))
            refuse_other_file()
            sock.connect(CONTROL_SOCKET)
        except (FileNotFoundError, ConnectionRefusedError):
            return None
        sock.sendall(command.encode() + b"\n")
        with sock.makefile("rb") as answer:
            line = answer.readline()
    if not line.endswith(b"\n"):
        raise ConnectionError("the server in %s closed its control socket without answering %s" % (root, command))
    return json.loads(line)


def wait_for_exit(pid, seconds):
    deadline = time.time() + seconds
    while pid_alive(pid) and time.time() < deadline:
        time.sleep(0.05)


def start_server(root, version):
    """Launches a server and returns its health once one answers: this one, or a racing caller's.
    None when none answers within START_WAIT_SECONDS."""
    subprocess.run([sys.executable, "-I", str(SCRIPT), "serve", "--root", str(root),
                    "--version", version], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, check=True)
    deadline = time.time() + START_WAIT_SECONDS
    while time.time() < deadline:
        health = control(root, "health")
        if health is not None:
            return health
        time.sleep(0.05)
    return None


def in_ssh_session():
    return bool(os.environ.get("SSH_CONNECTION") or os.environ.get("SSH_TTY"))


def ensure(root):
    version = plugin_version()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    health = control(root, "health")
    # The newest version serves: a run replaces a server older than its plugin and uses one of the same
    # version or newer, as a session the plugin was updated under but not yet restarted does.
    # Pages of a server this one replaces reconnect to its successor when it binds the same port.
    old_port, old_pages = None, 0
    if health is not None and version_order(health["version"]) < version_order(version):
        old_port, old_pages = health["port"], health["clients"]
        # The answer does not matter: a server another run started since says no, and one that
        # another run's shutdown is stopping can exit before it answers. Either way the old pid
        # is gone after the wait, and whatever answers then is the server to use.
        with contextlib.suppress(ConnectionError):
            control(root, "shutdown %d" % health["pid"])
        wait_for_exit(health["pid"], LOCK_WAIT_SECONDS)
        health = control(root, "health")
    if health is None:
        health = start_server(root, version)
        if health is None:
            print("image gallery: the server did not start within %d s; see %s" %
                  (START_WAIT_SECONDS, root / "server.log"), file=sys.stderr)
            return 1
    pages = health["clients"] + (old_pages if health["port"] == old_port else 0)
    if pages == 0 and os.environ.get("IMAGE_GALLERY_NO_OPEN") != "1":
        url = "http://127.0.0.1:%d/%s/" % (health["port"], health["token"])
        opened = False
        if not in_ssh_session():
            # Runs that ask together take turns opening the browser, so one slow to open can
            # outlast this wait; the address is printed then.
            try:
                opened = control(root, "open", timeout=15) == {"opened": True}
            except socket.timeout:
                opened = False
        if not opened:
            print("image gallery: open %s to watch the images" % url, file=sys.stderr)
    return 0


def clients(root):
    health = control(root, "health")
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
    try:
        return ensure(root) if args.command == "ensure" else clients(root)
    except (OSError, subprocess.CalledProcessError, ValueError) as e:
        print("image gallery: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
