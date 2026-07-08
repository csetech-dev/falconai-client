#!/usr/bin/env python3
"""HTTP webhook receiver — queues a GHCR deploy via deploy-agent trigger file."""
from __future__ import annotations

import json
import os
import sys
import traceback
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse

PORT = int(os.environ.get("GHCR_WEBHOOK_PORT", "9191"))
SECRET = os.environ.get("GHCR_WEBHOOK_SECRET", "")
DEPLOY_ROOT = Path(os.environ.get("FALCON_DEPLOY_DIR", "/opt/falconai-client"))
TRIGGER = DEPLOY_ROOT / ".deploy" / "trigger"


class WebhookHandler(BaseHTTPRequestHandler):
    server_version = "FalconGHCRWebhook/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[ghcr-webhook] %s - %s\n" % (self.address_string(), fmt % args))

    def _path(self) -> str:
        return urlparse(self.path).path.rstrip("/") or "/"

    def _authorized(self) -> bool:
        if not SECRET:
            return True
        auth = self.headers.get("Authorization", "")
        if auth == f"Bearer {SECRET}":
            return True
        return self.headers.get("X-Deploy-Token", "") == SECRET

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
        except BrokenPipeError:
            pass

    def do_GET(self) -> None:
        try:
            path = self._path()
            if path in ("/", "/health"):
                self._json(
                    200,
                    {
                        "status": "ok",
                        "trigger": str(TRIGGER),
                        "deploy_root": str(DEPLOY_ROOT),
                    },
                )
                return
            self._json(404, {"error": "not found", "path": path})
        except Exception as exc:
            self.log_message("GET failed: %s", exc)
            traceback.print_exc()
            self._json(500, {"error": str(exc)})

    def do_POST(self) -> None:
        try:
            path = self._path()
            if path not in ("/", "/deploy"):
                self._json(404, {"error": "not found", "path": path})
                return
            if not self._authorized():
                self._json(401, {"error": "unauthorized"})
                return

            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b""
            sha = "unknown"
            if raw:
                try:
                    sha = json.loads(raw).get("sha", sha) or "unknown"
                except json.JSONDecodeError:
                    pass

            TRIGGER.parent.mkdir(parents=True, exist_ok=True)
            payload_path = TRIGGER.parent / "trigger.json"
            if raw:
                payload_path.write_bytes(raw)
            else:
                payload_path.write_text("{}", encoding="utf-8")
            TRIGGER.touch()
            self.log_message("deploy queued sha=%s trigger=%s", sha, TRIGGER)
            self._json(202, {"status": "accepted", "sha": sha})
        except Exception as exc:
            self.log_message("POST failed: %s", exc)
            traceback.print_exc()
            self._json(500, {"error": str(exc)})


def main() -> None:
    if not SECRET:
        print(
            "[ghcr-webhook] WARNING: GHCR_WEBHOOK_SECRET is empty — anyone can trigger deploys.",
            file=sys.stderr,
        )
    TRIGGER.parent.mkdir(parents=True, exist_ok=True)
    bind = os.environ.get("GHCR_WEBHOOK_BIND", "0.0.0.0")
    server = HTTPServer((bind, PORT), WebhookHandler)
    print(
        f"[ghcr-webhook] listening on {bind}:{PORT} deploy_root={DEPLOY_ROOT} trigger={TRIGGER}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
