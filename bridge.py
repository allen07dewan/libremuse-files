#!/usr/bin/env python3
"""
LibreMuse bridge server.

Runs on your own PC and forwards prompts from the Roblox Studio plugin
to `opencode run`, using YOUR opencode.json config (model, providers, keys).
Nothing leaves your computer except opencode's normal API calls.

Usage:
    python bridge.py
    # keep this window open while you use the Studio plugin

Endpoints (all on 127.0.0.1 only):
    GET  /ping          -> {"ok": true}
    POST /chat          -> {"job_id": "..."}   (body: {"prompt": "...", "system": "..."})
    POST /plan          -> {"job_id": "..."}   (body: {"prompt": "game description"})
    POST /validate      -> {"status": "done", "valid": true|false, ...}
                           (body: {"license_key": "..."}; validates against Whop)
    GET  /result?id=... -> {"status": "running"} |
                           {"status": "done", "text": "..."} |
                           {"status": "done", "steps": [...]}   (plan jobs) |
                           {"status": "error", "text": "..."}
"""

import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

HOST = "127.0.0.1"
PORT = 8765

# `opencode run` uses your global config (~/.config/opencode/opencode.json),
# so the default model from your config is used. Add "--model", "your/model"
# here if you want to force a specific one.
OPENCODE_CMD = ["opencode", "run"]
TIMEOUT_SECONDS = 280  # per-request ceiling; plugin polls, so HTTP never hangs
MAX_PLAN_STEPS = 8

# ---- License validation (LibreMuse / LibreMuse Pro) ----
# The SELLER pastes their Whop API key here before uploading bridge.py to the
# Content app. Create a DEDICATED key in the Whop dashboard (Developer -> API keys)
# and use it ONLY for this file. Buyers download this file, so never reuse your
# main API key here. You can also set the WHOP_API_KEY environment variable
# instead of editing this line.
WHOP_API_KEY = os.environ.get("WHOP_API_KEY", "apik_k5yivHQfOrGoM_C7075691_C_bb3dc32ea25dbc93f916fca296ab9ad456d02cc6c50c9cb975ba98138301e4")
WHOP_VALIDATE_URL = "https://api.whop.com/v2/memberships/validate_license"
# Stable per-machine id, stored next to this file. The key is bound to the first
# machine that activates it (Whop metadata binding).
MACHINE_ID_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".libremuse_machine_id")

# Job results are kept so the plugin can poll for them, but cleaned up so a
# long session doesn't grow forever.
JOB_TTL_SECONDS = 1800  # drop finished results older than 30 minutes
MAX_JOBS = 100  # hard cap on stored results

VALID_CLASSES = {"Script", "LocalScript", "ModuleScript"}
VALID_PARENTS = {
    "ServerScriptService",
    "ServerStorage",
    "ReplicatedStorage",
    "StarterPlayerScripts",
    "StarterCharacterScripts",
    "Workspace",
}

PLAN_SYSTEM = """You are a Roblox game architect. Given a game description, break it \
into concrete implementation steps that a code generator will build one by one.

Reply with ONLY a JSON object — no markdown fences, no explanations, no extra text:

{"steps": [{"name": "short step name", "class": "Script", "parent": "ServerScriptService", "prompt": "detailed self-contained prompt for generating this step's Luau code"}]}

Rules:
- "class" must be exactly one of: Script, LocalScript, ModuleScript.
- "parent" must be exactly one of: ServerScriptService, ServerStorage, ReplicatedStorage, StarterPlayerScripts, StarterCharacterScripts, Workspace.
- Max 8 steps. Each step's "prompt" must be fully self-contained: describe exactly what the Luau code must do, including remotes/folders it should create if other steps depend on them.
- Order steps so foundations (data stores, remote events, shared modules) come before gameplay that uses them.
- Prefer fewer, bigger steps over many tiny ones.
"""

jobs = {}  # job_id -> result dict
jobs_lock = threading.Lock()


def _purge_old_jobs():
    """Drop old finished results so the store stays bounded."""
    now = time.time()
    with jobs_lock:
        stale = [
            jid
            for jid, j in jobs.items()
            if j.get("status") != "running" and now - j.get("started", now) > JOB_TTL_SECONDS
        ]
        for jid in stale:
            del jobs[jid]
        if len(jobs) > MAX_JOBS:
            oldest_first = sorted(
                (
                    (jid, j)
                    for jid, j in jobs.items()
                    if j.get("status") != "running"
                ),
                key=lambda kv: kv[1].get("started", 0),
            )
            for jid, _ in oldest_first[: len(jobs) - MAX_JOBS]:
                del jobs[jid]


def run_opencode(prompt, system):
    full_prompt = f"{system}\n\n{prompt}" if system else prompt
    try:
        # The prompt goes through stdin, not argv: `opencode run` reads piped
        # stdin when it isn't a TTY. This avoids Windows' ~32k command-line
        # limit when big Studio context (attached scripts) is included.
        proc = subprocess.run(
            OPENCODE_CMD,
            input=full_prompt,
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECONDS,
        )
        out = (proc.stdout or "").strip()
        err = (proc.stderr or "").strip()
        if proc.returncode == 0 and out:
            return "done", out
        return "error", err or out or f"opencode exited with code {proc.returncode}"
    except subprocess.TimeoutExpired:
        return "error", f"opencode timed out after {TIMEOUT_SECONDS}s."
    except FileNotFoundError:
        return "error", "'opencode' not found on PATH. Install opencode and retry."
    except Exception as exc:  # noqa: BLE001
        return "error", f"bridge error: {exc}"


def extract_json(text):
    """Pull the first {...} JSON object out of possibly noisy model output."""
    t = re.sub(r"```\w*\n?", "", text).strip()
    start, end = t.find("{"), t.rfind("}")
    if start == -1 or end == -1 or end <= start:
        return None
    try:
        return json.loads(t[start : end + 1])
    except json.JSONDecodeError:
        return None


def validate_plan(obj):
    if not isinstance(obj, dict):
        return None
    steps = obj.get("steps")
    if not isinstance(steps, list) or not steps:
        return None
    clean = []
    for s in steps[:MAX_PLAN_STEPS]:
        if not isinstance(s, dict):
            continue
        prompt = str(s.get("prompt") or "").strip()
        if not prompt:
            continue
        clean.append(
            {
                "name": str(s.get("name") or "Step")[:60],
                "class": s.get("class") if s.get("class") in VALID_CLASSES else "Script",
                "parent": s.get("parent") if s.get("parent") in VALID_PARENTS else "ServerScriptService",
                "prompt": prompt,
            }
        )
    return clean or None


def plan_game(description):
    status, text = run_opencode(description, PLAN_SYSTEM)
    if status != "done":
        return {"status": "error", "text": text}
    steps = validate_plan(extract_json(text))
    if not steps:
        return {"status": "error", "text": "planner returned invalid JSON. Raw output:\n" + text[:500]}
    return {"status": "done", "steps": steps}


def get_machine_id():
    """Stable per-machine id for Whop license metadata binding."""
    try:
        if os.path.exists(MACHINE_ID_FILE):
            with open(MACHINE_ID_FILE, "r") as f:
                mid = f.read().strip()
                if mid:
                    return mid
    except OSError:
        pass
    mid = uuid.uuid4().hex
    try:
        with open(MACHINE_ID_FILE, "w") as f:
            f.write(mid)
    except OSError:
        pass
    return mid


def validate_license_key(license_key):
    """Validate a buyer's license key against Whop's API."""
    key = (license_key or "").strip()
    if not key:
        return {"status": "error", "text": "Empty license key."}
    if not WHOP_API_KEY or WHOP_API_KEY == "PASTE_YOUR_WHOP_API_KEY_HERE":
        return {
            "status": "error",
            "text": "License validation isn't configured (seller: add WHOP_API_KEY to bridge.py).",
        }
    payload = json.dumps({
        "license_key": key,
        "metadata": {"machine_id": get_machine_id()},
    }).encode()
    req = urllib.request.Request(
        WHOP_VALIDATE_URL,
        data=payload,
        headers={
            "Authorization": "Bearer " + WHOP_API_KEY,
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            code = resp.status
            body = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        code = e.code
        try:
            body = e.read().decode("utf-8", "replace")
        except Exception:
            body = ""
    except Exception as exc:  # noqa: BLE001
        return {"status": "error", "text": "Couldn't reach Whop: " + str(exc)[:150]}
    # 201 = valid (first activation, or same machine as before)
    if code == 201:
        return {"status": "done", "valid": True}
    # 400 = invalid key, or key bound to a different machine
    if code == 400:
        return {
            "status": "done",
            "valid": False,
            "text": "Invalid key, or this key is already activated on a different machine.",
        }
    return {"status": "error", "text": "Whop API error (HTTP %d): %s" % (code, body[:150])}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # quieter logs
        print(f"[bridge] {self.command} {self.path}")

    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            return json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            return None

    def _start_job(self, worker):
        _purge_old_jobs()
        job_id = uuid.uuid4().hex
        with jobs_lock:
            jobs[job_id] = {"status": "running", "started": time.time()}

        def runner():
            try:
                result = worker()
            except Exception as exc:  # noqa: BLE001
                result = {"status": "error", "text": f"bridge error: {exc}"}
            with jobs_lock:
                result["started"] = jobs[job_id].get("started", time.time())
                jobs[job_id] = result
            print(f"[bridge] job {job_id[:8]} -> {result.get('status')}")

        threading.Thread(target=runner, daemon=True).start()
        self._send({"job_id": job_id})

    def do_GET(self):
        if self.path == "/ping":
            self._send({"ok": True})
        elif self.path.startswith("/result"):
            job_id = self.path.split("id=", 1)[1] if "id=" in self.path else ""
            with jobs_lock:
                job = jobs.get(job_id)
            if not job:
                self._send({"status": "error", "text": "unknown job id"}, 404)
            else:
                self._send(job)
        else:
            self._send({"error": "not found"}, 404)

    def do_POST(self):
        if self.path == "/chat":
            body = self._read_json()
            if body is None:
                self._send({"error": "invalid JSON"}, 400)
                return
            prompt = (body.get("prompt") or "").strip()
            system = (body.get("system") or "").strip()
            if not prompt:
                self._send({"error": "empty prompt"}, 400)
                return
            self._start_job(lambda: dict(zip(("status", "text"), run_opencode(prompt, system))))
        elif self.path == "/plan":
            body = self._read_json()
            if body is None:
                self._send({"error": "invalid JSON"}, 400)
                return
            description = (body.get("prompt") or "").strip()
            if not description:
                self._send({"error": "empty prompt"}, 400)
                return
            self._start_job(lambda: plan_game(description))
        elif self.path == "/validate":
            body = self._read_json()
            if body is None:
                self._send({"error": "invalid JSON"}, 400)
                return
            # Fast synchronous call (Whop API, ~20s timeout) — no job needed.
            self._send(validate_license_key(body.get("license_key")))
        else:
            self._send({"error": "not found"}, 404)


if __name__ == "__main__":
    server = HTTPServer((HOST, PORT), Handler)
    print(f"[bridge] listening on http://{HOST}:{PORT} (localhost only)")
    print("[bridge] press Ctrl+C to stop")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[bridge] stopped")
