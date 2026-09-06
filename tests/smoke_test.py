"""Exercise the real smoke gate against disposable local HTTP listeners."""
import concurrent.futures
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SmokeTest(unittest.TestCase):
    def run_gate(self, mode="healthy", expected=0, rule=None, configured=True):
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                status, body = 200, {"status": "UP"}
                if self.path.startswith("/actuator/health"):
                    if mode == "not-ready":
                        status = 503
                elif self.path == "/actuator/info":
                    body = {"build": {"sha": "wrong" if mode == "wrong-build" else "abc1234"}}
                elif "/report" in self.path:
                    body = {"state": "OK", "value": 0} if mode == "contract" else {"state": "UNOBSERVED", "value": None}
                    if mode == "product-failure":
                        status = 503
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as temp:
                env = dict(os.environ, GATE_REPORT_DIR=temp, SMOKE_SETTLE="1",
                           SMOKE_TIMEOUT="1", SMOKE_EXPECT_SHA="abc1234",
                           SMOKE_URL=f"http://127.0.0.1:{server.server_port}" if configured else "",
                           NO_PROXY="*", no_proxy="*")
                result = subprocess.run(["bash", str(ROOT / "gates/smoke.sh")],
                                        env=env, capture_output=True, text=True, timeout=15)
                report = json.loads(Path(temp, "smoke.json").read_text())
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertEqual(report["exit_code"], expected)
                if rule:
                    self.assertIn(rule, report["rules"])
                if expected in (0, 1):
                    self.assertGreater(report["scanned"], 0)
                return report
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_healthy_control(self):
        self.run_gate()

    def test_wrong_build(self):
        self.run_gate("wrong-build", 1, "wrong-build-serving")

    def test_not_ready(self):
        self.run_gate("not-ready", 1, "not-ready")

    def test_product_failure(self):
        self.run_gate("product-failure", 1, "product-endpoint-failed")

    def test_contract_violation(self):
        self.run_gate("contract", 1, "contract-violated")

    def test_not_applicable(self):
        self.run_gate(expected=3, configured=False)

    def test_dns_failure_is_unverified(self):
        # A deterministic transport fixture: curl exit 6 means DNS failure.
        # It exercises the actual gate classifier without depending on DNS.
        with tempfile.TemporaryDirectory() as temp:
            wrapper = Path(temp, "curl")
            wrapper.write_text("#!/bin/sh\nexit 6\n")
            wrapper.chmod(0o755)
            from unittest.mock import patch
            with patch.dict(os.environ, {"PATH":temp+os.pathsep+os.environ["PATH"]}):
                report = self.run_gate(expected=2)
            self.assertEqual(report["status"], "error")

    def test_parallel_different_responses(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            good = pool.submit(self.run_gate)
            bad = pool.submit(self.run_gate, "wrong-build", 1, "wrong-build-serving")
            good.result()
            bad.result()

    def test_temporary_body_is_private_and_cleaned(self):
        with tempfile.TemporaryDirectory() as temp:
            wrapper = Path(temp, "curl")
            real_curl = subprocess.check_output(["which", "curl"], text=True).strip()
            wrapper.write_text("#!/bin/bash\nprintf '%s\\n' \"$@\" >> \"$CAPTURE_ARGS\"\nexec \"" + real_curl + "\" \"$@\"\n")
            wrapper.chmod(0o755)
            from unittest.mock import patch
            with patch.dict(os.environ, {"PATH":temp+os.pathsep+os.environ["PATH"], "CAPTURE_ARGS":str(Path(temp,"args")), "TMPDIR":temp}):
                self.run_gate()
            args = Path(temp, "args").read_text().splitlines()
            bodies = [args[i+1] for i, value in enumerate(args) if value == "-o"]
            self.assertEqual(len(bodies), 3)
            for body in bodies:
                self.assertEqual(Path(body).parent, Path(temp))
                self.assertFalse(Path(body).exists())


if __name__ == "__main__":
    unittest.main()
