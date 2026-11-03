"""Client for the STS REST API v1 (stdlib only). lib/sts_api.sh is the bash twin.

    from sts_api import get, post, put, patch, request, task_wait, session_nbr

Base URL: STS_API_URL, else :8981 when COMPOSE_PROJECT_NAME=sts-sandbox, else :8980.
Token: STS_API_TOKEN, else STS_API_TOKEN_FILE, else <backups>/../config/bootstrap_admin.token.
Writes are refused unless /health reports the expected stack (sandbox when
COMPOSE_PROJECT_NAME=sts-sandbox, else live; STS_EXPECT_STACK overrides).
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sts_paths import backups_dir  # noqa: E402


class ApiError(RuntimeError):
    def __init__(self, status: int, code: str, message: str, method: str = "", path: str = ""):
        super().__init__(f"STS API {method} {path} -> HTTP {status} {code}: {message}")
        self.status, self.code, self.message = status, code, message


def base_url() -> str:
    env = os.environ.get("STS_API_URL", "").strip()
    if env:
        return env.rstrip("/")
    if os.environ.get("COMPOSE_PROJECT_NAME") == "sts-sandbox":
        return "http://localhost:8981/sts/api/v1"
    return "http://localhost:8980/sts/api/v1"


def expected_stack() -> str:
    env = os.environ.get("STS_EXPECT_STACK", "").strip()
    if env:
        return env
    return "sandbox" if os.environ.get("COMPOSE_PROJECT_NAME") == "sts-sandbox" else "live"


def token() -> str:
    env = os.environ.get("STS_API_TOKEN", "").strip()
    if env:
        return env
    file = os.environ.get("STS_API_TOKEN_FILE", "").strip()
    path = Path(file) if file else backups_dir().parent / "config" / "bootstrap_admin.token"
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


_guarded = False


def _send(method: str, path: str, body: Any = None) -> dict:
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(base_url() + path, data=data, method=method)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    tok = token()
    if tok:
        req.add_header("Authorization", f"Bearer {tok}")
    try:
        with urllib.request.urlopen(req, timeout=3600) as resp:
            return json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as exc:
        try:
            err = json.loads(exc.read().decode("utf-8"))["error"]
        except (ValueError, KeyError):
            err = {"code": "http", "message": exc.reason}
        raise ApiError(exc.code, err.get("code", ""), err.get("message", ""), method, path) from None
    except urllib.error.URLError as exc:
        raise ApiError(0, "unreachable", f"cannot reach {base_url()}: {exc.reason}", method, path) from None


def guard() -> str:
    """Print the target stack once; raise when it is not the expected one."""
    global _guarded
    stack = _send("GET", "/health").get("data", {}).get("stack", "")
    if stack != expected_stack():
        raise SystemExit(
            f"REFUSING: {base_url()} is stack '{stack or 'unknown'}' but this run expects "
            f"'{expected_stack()}'. Check COMPOSE_PROJECT_NAME / STS_API_URL / STS_EXPECT_STACK."
        )
    if not _guarded and os.environ.get("_STS_API_ANNOUNCED") != "1":
        print(f"==> STS API target: {stack} ({base_url()})", file=sys.stderr)
        os.environ["_STS_API_ANNOUNCED"] = "1"
    _guarded = True
    return stack


def request_raw(method: str, path: str, body: Any = None) -> dict:
    """Whole envelope ({data, meta})."""
    if method != "GET":
        guard()
    return _send(method, path, body)


def request(method: str, path: str, body: Any = None) -> Any:
    return request_raw(method, path, body).get("data")


def get(path: str) -> Any:
    return request("GET", path)


def post(path: str, body: Any = None) -> Any:
    return request("POST", path, body if body is not None else {})


def put(path: str, body: Any) -> Any:
    return request("PUT", path, body)


def patch(path: str, body: Any) -> Any:
    return request("PATCH", path, body)


def get_all(path: str, page: int = 1000) -> list:
    """Every row of a list route (follows limit/offset)."""
    rows: list = []
    sep = "&" if "?" in path else "?"
    while True:
        env = request_raw("GET", f"{path}{sep}limit={page}&offset={len(rows)}")
        chunk = env.get("data") or []
        rows.extend(chunk)
        total = (env.get("meta") or {}).get("total", len(rows))
        if not chunk or len(rows) >= total:
            return rows


def session_nbr() -> int:
    return int(get("/session")["session_nbr"])


def task_wait(task_id: str, timeout: int = 3600, out=None) -> dict:
    out = out or sys.stdout
    shown, start = 0, time.time()
    while True:
        task = get(f"/tasks/{task_id}?log=5000")
        log = task.get("log") or []
        if isinstance(log, str):
            log = log.splitlines()
        for line in log[shown:]:
            if not os.environ.get("STS_TASK_KEEP_TS"):
                line = re.sub(r"^\[\d\d:\d\d:\d\d\] ", "", line)
            drop = os.environ.get("STS_TASK_DROP")
            if drop and re.search(drop, line):
                continue
            if not os.environ.get("STS_TASK_QUIET"):
                print(line, file=out, flush=True)
        shown = len(log)
        if task.get("status") == "succeeded":
            return task
        if task.get("status") == "failed":
            raise ApiError(0, "task_failed", f"task {task_id} failed: {task.get('error')}", "TASK", task_id)
        if time.time() - start > timeout:
            raise ApiError(0, "timeout", f"task {task_id} still {task.get('status')} after {timeout}s", "TASK", task_id)
        time.sleep(1)


def run_task(path: str, body: Any = None, timeout: int = 3600) -> dict:
    tmo = os.environ.get("STS_TASK_TIMEOUT", "").strip()
    if tmo and path != "/admin/restore":
        body = {**(body or {}), "timeout_seconds": int(tmo)}
    task = post(path, body)
    return task_wait(task["task_id"], timeout)
