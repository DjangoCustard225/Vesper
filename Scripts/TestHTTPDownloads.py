"""Exercise production parallel HTTP transfers against a real local range server."""
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import re
import subprocess
import tempfile
import threading
import time

root = Path(__file__).resolve().parent.parent
scratch = Path(os.environ.get("VESPER_TEST_SCRATCH", "/tmp/vesper-usenet-core"))
triple = json.loads(subprocess.check_output(["swift", "-print-target-info"]))["target"]["triple"]
build = scratch / triple / "debug"
if not (build / "Modules/VesperCore.swiftmodule").exists():
    architecture = triple.split("-")[0]
    candidates = [p.parent.parent for p in scratch.glob("*/debug/Modules/VesperCore.swiftmodule")
                  if p.parent.parent.parent.name.startswith(architecture)]
    if candidates:
        build = candidates[0]
objects = list((build / "VesperCore.build").glob("*.o"))
if not objects:
    raise SystemExit("Run Core tests before the HTTP transfer checks.")
size = 32 * 1024 * 1024 + 123
payload = (b"\x1a\x45\xdf\xa3" * ((size + 3) // 4))[:size]
requests = Counter()
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        match = re.fullmatch(r"bytes=(\d+)-(\d+)", self.headers.get("Range", ""))
        assert match and self.headers.get("If-Range") == '"version1"'
        assert self.headers.get("Accept-Encoding") == "identity"
        lower, upper = map(int, match.groups())
        with lock:
            requests[self.path, lower] += 1
            attempt = requests[self.path, lower]
        if self.path == "/resume" and lower == 32 * 1024 * 1024 and attempt == 1:
            time.sleep(1)
            self.send_response(503)
            self.send_header("Retry-After", "15")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        ignored = self.path == "/ignored"
        body = payload if ignored else payload[lower:upper + 1]
        self.send_response(200 if ignored else 206)
        self.send_header("Content-Type", "video/x-matroska")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("ETag", '"changed"' if self.path == "/changed" else '"version1"')
        if not ignored:
            start = lower + 1 if self.path == "/wrong-range" else lower
            self.send_header("Content-Range", f"bytes {start}-{upper}/{size}")
        self.end_headers()
        if self.path == "/cancel":
            time.sleep(1)
        try:
            self.wfile.write(body[:-1] if self.path == "/short" else body)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix="vesper-http-tests-") as directory:
        binary = Path(directory) / "Tests"
        subprocess.run(["swiftc", "-swift-version", "5", "-warnings-as-errors", "-parse-as-library",
                        "-I", str(build / "Modules"),
                        str(root / "Tests/HTTPParallelDownloadTests.swift"),
                        str(root / "Vesper/Features/Downloads/HTTPParallelDownload.swift"),
                        *map(str, objects), "-o", str(binary)], check=True)
        subprocess.run([str(binary), f"http://127.0.0.1:{server.server_port}"], check=True, timeout=90)
        assert requests["/resume", 0] == 1 and requests["/resume", 16 * 1024 * 1024] == 1, requests
        assert requests["/resume", 32 * 1024 * 1024] == 2, requests
        print("Completed HTTP ranges were reused without downloading them again.")
finally:
    server.shutdown()
    server.server_close()
