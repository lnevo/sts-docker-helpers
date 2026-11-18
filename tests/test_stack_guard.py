"""Stack guard in lib/sts_api.{py,sh} and lib/paths.sh.

A stub /health server on 127.0.0.1 stands in for STS (no real stack is reached),
and a fake `docker` on PATH stands in for the compose web container.
"""

import http.server
import importlib
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
import sts_api  # noqa: E402

GUARD_ENV = ("STS_API_URL", "STS_EXPECT_STACK", "COMPOSE_PROJECT_NAME", "STS_API_TOKEN",
             "STS_API_TOKEN_FILE", "_STS_API_ANNOUNCED")


class StubSTS:
    """Answers GET /health with a chosen stack and records every request."""

    def __init__(self, stack):
        self.stack = stack
        self.requests = []
        stub = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def _reply(self, payload):
                body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):  # noqa: N802
                stub.requests.append(("GET", self.path))
                if self.path.endswith("/health"):
                    self._reply({"data": {"status": "ok", "stack": stub.stack}})
                else:
                    self._reply({"data": {}})

            def do_POST(self):  # noqa: N802
                length = int(self.headers.get("Content-Length") or 0)
                self.rfile.read(length)
                stub.requests.append(("POST", self.path))
                self._reply({"data": {"ok": True}})

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/sts/api/v1"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def writes(self):
        return [r for r in self.requests if r[0] != "GET"]

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def clean_env(**extra):
    env = {k: v for k, v in os.environ.items() if k not in GUARD_ENV}
    env["STS_API_TOKEN"] = "sts_" + "0" * 40
    env.update(extra)
    return env


class PythonClient(unittest.TestCase):
    def setUp(self):
        self._saved = {k: os.environ.get(k) for k in GUARD_ENV}
        for k in GUARD_ENV:
            os.environ.pop(k, None)
        os.environ["_STS_API_ANNOUNCED"] = "1"
        importlib.reload(sts_api)

    def tearDown(self):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_default_expects_uat(self):
        self.assertEqual(sts_api.expected_stack(), "uat")

    def test_sandbox_project_expects_sandbox(self):
        os.environ["COMPOSE_PROJECT_NAME"] = "sts-sandbox"
        self.assertEqual(sts_api.expected_stack(), "sandbox")

    def test_override_wins(self):
        os.environ["COMPOSE_PROJECT_NAME"] = "sts-sandbox"
        os.environ["STS_EXPECT_STACK"] = "live"
        self.assertEqual(sts_api.expected_stack(), "live")

    def test_unknown_override_refused(self):
        for value in ("prod", "sandbox "):
            os.environ["STS_EXPECT_STACK"] = value
            with self.assertRaises(SystemExit):
                sts_api.expected_stack()

    def _with_stub(self, stack):
        stub = StubSTS(stack)
        self.addCleanup(stub.close)
        os.environ["STS_API_URL"] = stub.url
        return stub

    def test_write_to_live_refused_by_default(self):
        stub = self._with_stub("live")
        with self.assertRaises(SystemExit) as cm:
            sts_api.post("/session/advance")
        self.assertIn("REFUSING", str(cm.exception))
        self.assertEqual(stub.writes(), [])

    def test_write_to_uat_allowed_by_default(self):
        stub = self._with_stub("uat")
        sts_api.post("/session/advance")
        self.assertEqual(stub.writes(), [("POST", "/sts/api/v1/session/advance")])

    def test_write_to_live_allowed_when_named(self):
        stub = self._with_stub("live")
        os.environ["STS_EXPECT_STACK"] = "live"
        sts_api.post("/session/advance")
        self.assertEqual(len(stub.writes()), 1)

    def test_reads_are_not_guarded(self):
        stub = self._with_stub("live")
        sts_api.get("/session")
        self.assertEqual(stub.requests, [("GET", "/sts/api/v1/session")])



def run_bash(script, env):
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env, timeout=60)


class BashClient(unittest.TestCase):
    PRE = f'set -u; source "{ROOT}/lib/sts_api.sh"; '

    def stub(self, stack):
        stub = StubSTS(stack)
        self.addCleanup(stub.close)
        return stub

    def test_default_expects_uat(self):
        r = run_bash(self.PRE + "sts_api_expected_stack", clean_env())
        self.assertEqual(r.stdout, "uat")

    def test_sandbox_project_and_override(self):
        r = run_bash(self.PRE + "sts_api_expected_stack", clean_env(COMPOSE_PROJECT_NAME="sts-sandbox"))
        self.assertEqual(r.stdout, "sandbox")
        r = run_bash(self.PRE + "sts_api_expected_stack",
                     clean_env(COMPOSE_PROJECT_NAME="sts-sandbox", STS_EXPECT_STACK="live"))
        self.assertEqual(r.stdout, "live")

    def test_unknown_override_refused(self):
        stub = self.stub("live")
        r = run_bash(self.PRE + "sts_api POST /session/advance '{}'",
                     clean_env(STS_API_URL=stub.url, STS_EXPECT_STACK="prod"))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not one of", r.stderr)
        self.assertEqual(stub.writes(), [])

    def test_write_to_live_refused_by_default(self):
        stub = self.stub("live")
        r = run_bash(self.PRE + "sts_api POST /session/advance '{}'", clean_env(STS_API_URL=stub.url))
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("REFUSING", r.stderr)
        self.assertEqual(stub.writes(), [])

    def test_write_to_uat_allowed_by_default(self):
        stub = self.stub("uat")
        r = run_bash(self.PRE + "sts_api POST /session/advance '{}'", clean_env(STS_API_URL=stub.url))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(stub.writes(), [("POST", "/sts/api/v1/session/advance")])

    def test_write_to_live_allowed_when_named(self):
        stub = self.stub("live")
        r = run_bash(self.PRE + "sts_api POST /session/advance '{}'",
                     clean_env(STS_API_URL=stub.url, STS_EXPECT_STACK="live"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(stub.writes()), 1)

    def test_require_sandbox(self):
        stub = self.stub("uat")
        r = run_bash(self.PRE + "sts_api_require_sandbox", clean_env(STS_API_URL=stub.url))
        self.assertNotEqual(r.returncode, 0)
        sandbox = self.stub("sandbox")
        r = run_bash(self.PRE + 'sts_api_require_sandbox && printf %s "$STS_EXPECT_STACK"',
                     clean_env(STS_API_URL=sandbox.url))
        self.assertEqual((r.returncode, r.stdout), (0, "sandbox"), r.stderr)
        r = run_bash(self.PRE + "sts_api_require_sandbox",
                     clean_env(STS_API_URL=sandbox.url, STS_EXPECT_STACK="uat"))
        self.assertNotEqual(r.returncode, 0)


FAKE_DOCKER = """#!/usr/bin/env bash
# compose ... ps -q web -> FAKE_CID; inspect -> STS_STACK_NAME=FAKE_STACK
case "$*" in
  compose*"ps -q web"*) [[ -n "${FAKE_CID:-}" ]] && printf '%s\\n' "${FAKE_CID}" ;;
  inspect*) printf 'PATH=/usr/bin\\nSTS_STACK_NAME=%s\\n' "${FAKE_STACK}" ;;
  *) echo "unexpected docker $*" >&2; exit 9 ;;
esac
"""


class ContainerGuard(unittest.TestCase):
    """sts_require_sandbox in lib/paths.sh, used by the docker-exec writers."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        fake_bin = root / "fakebin"
        fake_bin.mkdir()
        docker = fake_bin / "docker"
        docker.write_text(FAKE_DOCKER)
        docker.chmod(0o755)
        (root / "sts-docker").mkdir()
        (root / "sts-docker-data" / "backups").mkdir(parents=True)
        self.root, self.fake_bin = root, fake_bin

    def run_guard(self, stack, cid="abc123def4567890", **env):
        stub = StubSTS(stack)
        self.addCleanup(stub.close)
        script = (f'set -u; source "{ROOT}/lib/paths.sh"; '
                  f'STS_DOCKER="{self.root}/sts-docker" sts_helpers_resolve_paths "{ROOT}/bin/x.sh"; '
                  'sts_require_sandbox')
        e = clean_env(STS_API_URL=stub.url, FAKE_CID=cid, FAKE_STACK=stack,
                      PATH=f"{self.fake_bin}:{os.environ['PATH']}", **env)
        e.pop("STS_BACKUPS_DIR", None)
        return run_bash(script, e), stub

    def test_sandbox_container_passes(self):
        r, _ = self.run_guard("sandbox")
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_uat_container_refused(self):
        r, stub = self.run_guard("uat")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("stack 'uat'", r.stderr)
        self.assertEqual(stub.requests, [])  # stopped before the API

    def test_live_container_refused(self):
        r, _ = self.run_guard("live")
        self.assertNotEqual(r.returncode, 0)

    def test_no_container_refused(self):
        r, _ = self.run_guard("sandbox", cid="")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no running web container", r.stderr)

    def test_override_to_other_stack_refused(self):
        r, _ = self.run_guard("sandbox", STS_EXPECT_STACK="uat")
        self.assertNotEqual(r.returncode, 0)


class WritersCallTheGuard(unittest.TestCase):
    """Every simulation, sweep and docker-exec writer refuses anything but the sandbox."""

    SANDBOX_ONLY = [
        "apply_shipment_tune", "backfill_starting_after_reposition",
        "benchmark_home_split",
        "rewind_ck1_weigh", "rewind_session", "run_catalog_tests", "run_coke_stagger_compare",
        "run_gate_reposition_sweep", "run_lane_tune_sweep", "run_nvl_tune_sweep",
        "run_track_scale_10x10", "run_traffic_extremes", "run_traffic_from_s2_sweep",
    ]

    def test_guard_present(self):
        for name in self.SANDBOX_ONLY:
            path = ROOT / "bin" / f"{name}.sh"
            self.assertTrue(path.exists(), f"{name}.sh is listed but missing; update SANDBOX_ONLY")
            with self.subTest(script=name):
                self.assertIn("sts_require_sandbox || exit 1", path.read_text())
        sims = (ROOT / "bin" / "run_session_simulations.sh").read_text()
        self.assertIn("sts_api_require_sandbox || exit 1", sims)

    def test_every_run_sweep_is_guarded(self):
        allowed = {"run_catalog_workflow.sh"}  # generic workflow runner: normal guard (uat by default)
        for path in sorted((ROOT / "bin").glob("run_*.sh")):
            if path.name in allowed:
                continue
            with self.subTest(script=path.name):
                text = path.read_text()
                self.assertTrue("sts_require_sandbox || exit 1" in text
                                or "sts_api_require_sandbox || exit 1" in text)


if __name__ == "__main__":
    unittest.main()
