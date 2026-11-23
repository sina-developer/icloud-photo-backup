#!/usr/bin/env python3
"""iCloud Photo Backup - a small local web UI around icloudpd.

Runs a web server on 127.0.0.1 only. It starts icloudpd in a pseudo-terminal,
answers its prompts (password, two-factor code) from the UI, parses its log to
show progress, and pauses/resumes by stopping and restarting icloudpd (which
skips files already on disk and continues half-finished .part files).
"""

import json
import os
import pty
import re
import secrets
import select
import shutil
import signal
import subprocess
import sys
import threading
import time
import webbrowser
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

APP_NAME = "iCloud Photo Backup"
FROZEN = getattr(sys, "frozen", False)  # True inside the self-contained app build
HERE = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
PORT = int(os.environ.get("ICPB_PORT", "8765"))
SUPPORT_DIR = os.path.expanduser("~/Library/Application Support/iCloudPhotoBackup")
CONFIG_PATH = os.path.join(SUPPORT_DIR, "config.json")
THUMB_DIR = os.path.join(SUPPORT_DIR, "thumbs")
TOKEN = secrets.token_hex(16)


def read_version():
    for p in (os.path.join(HERE, "VERSION"), os.path.join(HERE, "..", "VERSION")):
        try:
            with open(p) as f:
                return f.read().strip()
        except OSError:
            continue
    return "dev"


VERSION = read_version()
MEDIA_EXT = {".jpg", ".jpeg", ".heic", ".png", ".gif", ".tif", ".tiff", ".dng",
             ".raw", ".cr2", ".nef", ".arw", ".mov", ".mp4", ".m4v", ".avi", ".webp"}
VIDEO_EXT = {".mov", ".mp4", ".m4v", ".avi"}
LOG_RE = re.compile(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:,\d+)? (DEBUG|INFO|WARNING|ERROR|CRITICAL)\s+(.*)$")
TOTAL_RE = re.compile(r"^Downloading (\d+|the first|\?\?\?) .* to .* \.\.\.$")
AUTH_FAIL_HINTS = ("Invalid email/password", "Failed to verify", "password is wrong",
                   "Authentication failed", "PyiCloudFailedLoginException", "service is not activated")
MAX_AUTO_RETRIES = 20
RETRY_DELAY = 30


def find_icloudpd():
    """Command prefix that runs icloudpd, or None if it isn't available."""
    if FROZEN:  # the bundled app carries a standalone icloudpd next to its executable
        bundled = os.path.join(os.path.dirname(sys.executable), "icloudpd")
        return [bundled] if os.path.exists(bundled) else None
    for cand in (shutil.which("icloudpd"), "/opt/homebrew/bin/icloudpd", "/usr/local/bin/icloudpd"):
        if cand and os.path.exists(cand):
            return [cand]
    return None


def load_config():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except Exception:
        return {}


def save_config(cfg):
    os.makedirs(SUPPORT_DIR, exist_ok=True)
    with open(CONFIG_PATH, "w") as f:
        json.dump(cfg, f, indent=2)


def human_bytes(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return ("%.0f %s" if unit in ("B", "KB") else "%.1f %s") % (n, unit)
        n /= 1024


class Backup:
    """Owns the icloudpd process and everything the UI shows."""

    def __init__(self):
        self.lock = threading.RLock()
        self.cfg = load_config()
        self.password = None          # kept in memory only, never written to disk
        self.proc_pid = None
        self.master_fd = None
        self.caffeinate = None
        self.state = "idle"           # idle | starting | running | needs_input | pausing | paused | done | error | retrying
        self.message = "Ready."
        self.prompt = None            # {"text": ..., "secret": bool}
        self.user_stopped = False
        self.auth_failed = False
        self.retries = 0
        self.retry_at = None
        self.log = deque(maxlen=300)
        self.errors = deque(maxlen=50)
        self.reset_run_counters()
        self.disk = {"files": 0, "bytes": 0, "recent": [], "scanned_at": 0}
        self.rate_window = deque(maxlen=400)
        self.byte_window = deque(maxlen=60)
        threading.Thread(target=self._scanner, daemon=True).start()

    def reset_run_counters(self):
        self.total = None
        self.processed = 0       # assets handled this run (downloaded or already there)
        self.downloaded = 0      # files downloaded this run
        self.skipped = 0         # files already on disk this run
        self.current = ""

    # ----- public actions -------------------------------------------------
    def start(self, username, directory, password=None, options=None):
        with self.lock:
            if self.state in ("starting", "running", "needs_input", "pausing"):
                return "Already running."
            exe = find_icloudpd()
            if not exe:
                return "icloudpd is not installed. Run: brew install icloudpd"
            if not username or "@" not in username:
                return "Enter your Apple ID email."
            if not directory:
                return "Choose a folder on your SSD first."
            if not os.path.isdir(directory):
                return "That folder doesn't exist (is the SSD plugged in?)."
            if not os.access(directory, os.W_OK):
                return "Can't write to that folder."
            if password:
                self.password = password
            opts = options or self.cfg.get("options", {})
            self.cfg.update({"username": username, "directory": directory, "options": opts})
            save_config(self.cfg)
            self.retries = 0
            self._launch()
            return None

    def pause(self):
        with self.lock:
            self.retry_at = None
            if self.proc_pid is None:
                if self.state == "retrying":
                    self._set("paused", "Paused. Press Resume to continue.")
                return None
            self.user_stopped = True
            self._set("pausing", "Pausing...")
            pid = self.proc_pid
        try:
            os.kill(pid, signal.SIGINT)
        except ProcessLookupError:
            return None

        def escalate():
            time.sleep(6)
            with self.lock:
                if self.proc_pid == pid:
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
        threading.Thread(target=escalate, daemon=True).start()
        return None

    def answer(self, text):
        with self.lock:
            if self.master_fd is None or self.prompt is None:
                return "Nothing is waiting for an answer."
            if self.prompt.get("secret"):
                self.password = text
            self.prompt = None
            self._set("running", "Signing in...")
            os.write(self.master_fd, (text + "\n").encode())
        return None

    def snapshot(self):
        with self.lock:
            now = time.time()
            rate = self._rate(self.rate_window, now, 120)
            brate = self._rate(self.byte_window, now, 60)
            eta = None
            if self.total and rate and rate > 0 and self.state == "running":
                eta = max(0, (self.total - self.processed) / rate)
            directory = self.cfg.get("directory")
            mac = disk_info(os.path.expanduser("~"))
            target = disk_info(directory) if directory and os.path.isdir(directory) else None
            free = target["free"] if target else None
            same_disk = False
            if target:
                try:
                    same_disk = os.stat(directory).st_dev == os.stat(os.path.expanduser("~")).st_dev
                except OSError:
                    pass
            # Estimate the whole library's size from the average size of what's already on disk.
            est_total = None
            assets_on_disk = self.disk.get("assets", 0)
            if self.total and assets_on_disk >= 20 and self.disk["bytes"] > 0:
                est_total = self.disk["bytes"] / assets_on_disk * self.total
            pct = None
            if self.total:
                pct = min(100.0, 100.0 * self.processed / self.total)
            return {
                "version": VERSION,
                "state": self.state,
                "message": self.message,
                "prompt": self.prompt,
                "username": self.cfg.get("username", ""),
                "directory": directory or "",
                "options": self.cfg.get("options", {}),
                "on_internal_disk": bool(directory) and not directory.startswith("/Volumes/"),
                "have_password": self.password is not None,
                "icloudpd": find_icloudpd() is not None,
                "total": self.total,
                "processed": self.processed,
                "percent": pct,
                "downloaded": self.downloaded,
                "skipped": self.skipped,
                "errors": list(self.errors)[-8:],
                "error_count": len(self.errors),
                "current": self.current,
                "rate_per_min": rate * 60 if rate else 0,
                "bytes_per_sec": brate or 0,
                "eta_seconds": eta,
                "free_bytes": free,
                "mac_disk": mac,
                "target_disk": target,
                "same_disk": same_disk,
                "estimated_total_bytes": est_total,
                "disk_files": self.disk["files"],
                "disk_bytes": self.disk["bytes"],
                "recent": self.disk["recent"],
                "retry_in": max(0, int(self.retry_at - now)) if self.retry_at else None,
                "retries": self.retries,
                "log": list(self.log)[-80:],
            }

    def shutdown(self):
        self.retry_at = None
        pid = self.proc_pid
        if not pid:
            return
        self.user_stopped = True
        for sig, wait in ((signal.SIGINT, 3), (signal.SIGTERM, 2), (signal.SIGKILL, 0)):
            try:
                os.kill(pid, sig)
            except (ProcessLookupError, TypeError):
                return
            deadline = time.time() + wait
            while time.time() < deadline:
                if self.proc_pid != pid:
                    return
                time.sleep(0.1)

    # ----- internals ------------------------------------------------------
    def _set(self, state, message):
        self.state = state
        self.message = message

    @staticmethod
    def _rate(window, now, span):
        pts = [p for p in window if now - p[0] <= span]
        if len(pts) < 2:
            return None
        dt = pts[-1][0] - pts[0][0]
        if dt < 5:
            return None
        return (pts[-1][1] - pts[0][1]) / dt

    def _build_cmd(self):
        c = self.cfg
        o = c.get("options", {})
        cmd = find_icloudpd() + ["--no-progress-bar", "--log-level", "debug",
               "--password-provider", "console", "--mfa-provider", "console",
               "--username", c["username"], "--directory", c["directory"],
               "--size", "original"]
        if o.get("skip_videos"):
            cmd.append("--skip-videos")
        if o.get("skip_live_photos"):
            cmd.append("--skip-live-photos")
        if o.get("adp"):
            cmd.append("--adp-web-access")
        if o.get("folder_structure") == "none":
            cmd += ["--folder-structure", "none"]
        elif o.get("folder_structure") == "month":
            cmd += ["--folder-structure", "{:%Y/%m}"]
        return cmd

    def _launch(self):
        cmd = self._build_cmd()
        self.reset_run_counters()
        self.user_stopped = False
        self.auth_failed = False
        self.prompt = None
        self.retry_at = None
        self.rate_window.clear()
        self._set("starting", "Starting up and connecting to iCloud (about 10 seconds)...")
        self._log("app", "Starting icloudpd%s" % (" (attempt %d)" % (self.retries + 1) if self.retries else ""))
        env = dict(os.environ, TERM="dumb", COLUMNS="250", PYTHONUNBUFFERED="1")
        pid, fd = pty.fork()
        if pid == 0:  # child
            try:
                os.execve(cmd[0], cmd, env)
            finally:
                os._exit(127)
        self.proc_pid, self.master_fd = pid, fd
        try:  # keep the Mac awake while downloading
            self.caffeinate = subprocess.Popen(["caffeinate", "-ims", "-w", str(pid)])
        except Exception:
            self.caffeinate = None
        threading.Thread(target=self._reader, args=(pid, fd), daemon=True).start()

    def _log(self, level, text):
        self.log.append({"t": time.strftime("%H:%M:%S"), "level": level, "text": text})

    def _reader(self, pid, fd):
        buf = b""
        last_data = time.time()
        while True:
            try:
                r, _, _ = select.select([fd], [], [], 0.4)
            except (OSError, ValueError):
                break
            if r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    data = b""
                if not data:
                    break
                buf += data
                last_data = time.time()
                parts = re.split(rb"\r\n|\n|\r", buf)
                buf = parts.pop()
                for raw in parts:
                    self._handle_line(raw.decode("utf-8", "replace").rstrip())
            elif buf and time.time() - last_data > 0.3:
                # A line without newline that stays put is a prompt waiting for input.
                self._handle_prompt(buf.decode("utf-8", "replace").strip())
                buf = b""
        if buf:
            self._handle_line(buf.decode("utf-8", "replace").rstrip())
        _, status = os.waitpid(pid, 0)
        code = os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else (status >> 8)
        try:
            os.close(fd)
        except OSError:
            pass
        self._on_exit(code)

    def _handle_prompt(self, text):
        with self.lock:
            low = text.lower()
            if "password" in low:
                if self.password:
                    os.write(self.master_fd, (self.password + "\n").encode())
                    self._log("app", "Sent password")
                    return
                self.prompt = {"text": "Enter your Apple ID password", "secret": True}
                self._set("needs_input", "iCloud needs your password.")
            elif "two-factor" in low or "two-step" in low:
                self.prompt = {"text": "Enter the 6-digit code shown on your iPhone, iPad or Mac", "secret": False, "raw": text}
                self._set("needs_input", "Enter the verification code from your Apple device.")
            elif "choose an option" in low or "[y/n]" in low:
                self.prompt = {"text": text, "secret": False, "raw": text}
                self._set("needs_input", "icloudpd is asking a question.")
            else:
                self._handle_line(text)
                return
            self._log("prompt", text)

    def _handle_line(self, line):
        if not line.strip():
            return
        with self.lock:
            m = LOG_RE.match(line)
            level, msg = (m.group(1), m.group(2)) if m else ("OUT", line)
            if level == "DEBUG":
                if msg.endswith(" already exists") or msg.endswith(" deduplicated"):
                    self.skipped += 1
                    self._count_asset(msg.rsplit(" ", 2)[0])
                elif msg.startswith("Downloading ") and msg.endswith("..."):
                    self.current = os.path.basename(msg[len("Downloading "):-3])
                    if self.state == "starting":
                        self._set("running", "Downloading...")
                elif msg.startswith("Authenticating"):
                    self._set("starting", "Signing in to iCloud...")
                return  # debug lines are too noisy for the visible log
            self._log(level.lower(), msg)
            if level in ("ERROR", "CRITICAL"):
                self.errors.append({"t": time.strftime("%H:%M:%S"), "text": msg})
                if any(h.lower() in msg.lower() for h in AUTH_FAIL_HINTS):
                    self.auth_failed = True
                    if "password" in msg.lower() or "login" in msg.lower():
                        self.password = None
            tm = TOTAL_RE.match(msg)
            if tm:
                v = tm.group(1)
                self.total = 1 if v == "the first" else (int(v) if v.isdigit() else None)
                self._set("running", "Downloading...")
            elif msg.startswith("Downloaded "):
                self.downloaded += 1
                self._count_asset(msg[len("Downloaded "):])
            elif msg.startswith("Two-factor authentication is required"):
                self._set("starting", "Two-factor authentication needed...")
            elif "Great, you're all set up" in msg or msg.startswith("Authentication completed"):
                self._set("starting", "Signed in. Reading your library...")
            elif msg.startswith("Processing user"):
                self._set("starting", "Reading your photo library (this can take a few minutes)...")

    def _count_asset(self, path):
        # The video half of a Live Photo is a second file for the same asset.
        if not path.upper().endswith("_HEVC.MOV"):
            self.processed += 1
            self.rate_window.append((time.time(), self.processed))

    def _on_exit(self, code):
        with self.lock:
            self.proc_pid = None
            self.master_fd = None
            self.prompt = None
            self._log("app", "icloudpd exited with code %s" % code)
            if self.user_stopped:
                self._set("paused", "Paused. Everything downloaded so far is safe on your SSD. Press Resume to continue.")
            elif code == 0:
                self.retries = 0
                if self.total is None and self.processed == 0:
                    self._set("error", "icloudpd stopped without downloading anything. Check the log below.")
                else:
                    self._set("done", "Backup complete. All %s items are on your SSD." % (self.total or self.processed))
            elif self.auth_failed:
                self._set("error", "Sign-in failed. Check your Apple ID and password and press Start again.")
            elif self.retries < MAX_AUTO_RETRIES:
                self.retries += 1
                self.retry_at = time.time() + RETRY_DELAY
                self._set("retrying", "Connection problem. Retrying automatically in %d s..." % RETRY_DELAY)
                threading.Thread(target=self._retry_later, daemon=True).start()
            else:
                self._set("error", "Stopped after %d failed attempts. Press Resume to try again." % self.retries)

    def _retry_later(self):
        while True:
            time.sleep(1)
            with self.lock:
                if self.retry_at is None or self.state != "retrying":
                    return
                if time.time() >= self.retry_at:
                    self.retry_at = None
                    self._launch()
                    return

    def _scanner(self):
        """Periodically count what's actually in the backup folder."""
        last_bytes = None
        while True:
            directory = self.cfg.get("directory")
            busy = self.state in ("running", "starting", "needs_input", "pausing")
            if directory and os.path.isdir(directory):
                files, total, recent = 0, 0, []
                for root, dirs, names in os.walk(directory):
                    dirs[:] = [d for d in dirs if not d.startswith(".")]
                    for n in names:
                        ext = os.path.splitext(n)[1].lower()
                        p = os.path.join(root, n)
                        try:
                            st = os.stat(p)
                        except OSError:
                            continue
                        total += st.st_size
                        if ext in MEDIA_EXT and not n.startswith("."):
                            files += 1
                            if not n.upper().endswith("_HEVC.MOV"):
                                recent.append((st.st_mtime, p))
                recent.sort(reverse=True)
                rec = [{"path": os.path.relpath(p, directory), "name": os.path.basename(p),
                        "video": os.path.splitext(p)[1].lower() in VIDEO_EXT} for _, p in recent[:18]]
                with self.lock:
                    self.disk = {"files": files, "bytes": total, "recent": rec,
                                 "assets": len(recent), "scanned_at": time.time()}
                    if busy:
                        self.byte_window.append((time.time(), total))
                    last_bytes = total
            time.sleep(4 if busy else 15)


def disk_info(path):
    """Total/used/free bytes and a display name for the volume holding `path`."""
    try:
        u = shutil.disk_usage(path)
    except OSError:
        return None
    real = os.path.realpath(path)
    name = real.split("/")[2] if real.startswith("/Volumes/") else startup_disk_name()
    return {"name": name, "total": u.total, "used": u.total - u.free, "free": u.free}


_STARTUP_NAME = []


def startup_disk_name():
    if not _STARTUP_NAME:
        name = "Macintosh HD"
        try:
            r = subprocess.run(["diskutil", "info", "/"], capture_output=True, text=True, timeout=3)
            m = re.search(r"Volume Name:\s+(.+)", r.stdout)
            if m:
                name = m.group(1).strip()
        except Exception:
            pass
        _STARTUP_NAME.append(name)
    return _STARTUP_NAME[0]


BACKUP = Backup()


def make_thumb(directory, rel):
    src = os.path.realpath(os.path.join(directory, rel))
    if not src.startswith(os.path.realpath(directory) + os.sep) or not os.path.isfile(src):
        return None
    os.makedirs(THUMB_DIR, exist_ok=True)
    key = "%x_%x" % (abs(hash(src)), int(os.path.getmtime(src)))
    out_dir = os.path.join(THUMB_DIR, key)
    out = os.path.join(out_dir, os.path.basename(src) + ".png")
    if not os.path.exists(out):
        os.makedirs(out_dir, exist_ok=True)
        subprocess.run(["qlmanage", "-t", "-s", "320", "-o", out_dir, src],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    return out if os.path.exists(out) else None


def choose_folder():
    script = 'POSIX path of (choose folder with prompt "Choose a folder on your SSD for the photos")'
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return r.stdout.strip().rstrip("/") or None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _host_ok(self):
        host = (self.headers.get("Host") or "").split(":")[0]
        return host in ("127.0.0.1", "localhost")

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self._host_ok():
            return self._send(403, {"error": "forbidden"})
        u = urlparse(self.path)
        if u.path == "/":
            with open(os.path.join(HERE, "index.html")) as f:
                html = f.read().replace("__TOKEN__", TOKEN)
            return self._send(200, html, "text/html; charset=utf-8")
        q = parse_qs(u.query)
        if q.get("token", [""])[0] != TOKEN and self.headers.get("X-Token") != TOKEN:
            return self._send(403, {"error": "forbidden"})
        if u.path == "/api/state":
            return self._send(200, BACKUP.snapshot())
        if u.path == "/thumb":
            d = BACKUP.cfg.get("directory")
            p = make_thumb(d, q.get("p", [""])[0]) if d else None
            if not p:
                return self._send(404, {"error": "no thumbnail"})
            with open(p, "rb") as f:
                return self._send(200, f.read(), "image/png")
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._host_ok() or self.headers.get("X-Token") != TOKEN:
            return self._send(403, {"error": "forbidden"})
        n = int(self.headers.get("Content-Length") or 0)
        try:
            data = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            data = {}
        p = urlparse(self.path).path
        err = None
        if p == "/api/start":
            err = BACKUP.start(data.get("username", "").strip(), data.get("directory", "").strip(),
                               data.get("password") or None, data.get("options"))
        elif p == "/api/pause":
            err = BACKUP.pause()
        elif p == "/api/answer":
            err = BACKUP.answer(str(data.get("text", "")).strip())
        elif p == "/api/choose-folder":
            folder = choose_folder()
            if folder:
                with BACKUP.lock:
                    BACKUP.cfg["directory"] = folder
                    save_config(BACKUP.cfg)
            return self._send(200, {"directory": folder})
        elif p == "/api/open-folder":
            d = BACKUP.cfg.get("directory")
            if d and os.path.isdir(d):
                subprocess.Popen(["open", d])
        elif p == "/api/forget-password":
            BACKUP.password = None
        elif p == "/api/quit":
            self._send(200, {"ok": True})
            threading.Thread(target=lambda: (BACKUP.shutdown(), time.sleep(0.5), os._exit(0)), daemon=True).start()
            return
        else:
            return self._send(404, {"error": "not found"})
        self._send(200, {"error": err} if err else {"ok": True})


def watch_parent(ppid):
    """Exit (pausing the download) if the native app that started us goes away."""
    while True:
        time.sleep(2)
        try:
            os.kill(ppid, 0)
        except ProcessLookupError:
            BACKUP.shutdown()
            os._exit(0)


def main():
    native = "--native" in sys.argv  # started by the macOS app window
    try:
        server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    except OSError:
        if native:
            print("ERROR could not open a local port", flush=True)
            sys.exit(1)
        # Already running: just show the page again.
        webbrowser.open("http://127.0.0.1:%d/" % PORT)
        return
    url = "http://127.0.0.1:%d/" % server.server_address[1]

    def on_term(*_):
        threading.Thread(target=lambda: (BACKUP.shutdown(), os._exit(0)), daemon=True).start()
    signal.signal(signal.SIGTERM, on_term)
    if "--parent-pid" in sys.argv:
        ppid = int(sys.argv[sys.argv.index("--parent-pid") + 1])
        threading.Thread(target=watch_parent, args=(ppid,), daemon=True).start()
    print("%s %s running at %s" % (APP_NAME, VERSION, url), flush=True)
    print("READY %s" % url, flush=True)
    if not native and "--no-browser" not in sys.argv:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
