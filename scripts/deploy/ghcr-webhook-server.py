#!/usr/bin/env python3
"""HTTP webhook receiver — queues a GHCR deploy via deploy-agent trigger file."""
from __future__ import annotations

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

PORT = int(os.environ.get("GHCR_WEBHOOK_PORT", "9191"))
SECRET = os.environ.get("GHCR_WEBHOOK_SECRET", "")
DEPLOY_ROOT = Path(os.environ.get("FALCON_DEPLOY_DIR", "/opt/falconai-client"))
TRIGGER = DEPLOY_ROOT / ".deploy" / "trigger"


class WebhookHandler(BaseHTTPRequestHandler):
    server_version = "FalconGHCRWebhook/1.0"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[ghcr-webhook] %s - %s\n" % (self.address_string(), fmt % args))

    def _authorized(self) -> bool:
        if not SECRET:
            return True
        auth = self.headers.get("Authorization", "")
        if auth == f"Bearer {SECRET}":
            return True
        return self.headers.get("X-Deploy-Token", "") == SECRET

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path.rstrip("/") in ("", "/health"):
            self._json(200, {"status": "ok", "trigger": str(TRIGGER)})
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self) -> None:
        if not self._authorized():
            self._json(401, {"error": "unauthorized"})
            return

        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b""
        sha = "unknown"
        if raw:
            try:
                sha = json.loads(raw).get("sha", sha)
            except json.JSONDecodeError:
                pass

        TRIGGER.parent.mkdir(parents=True, exist_ok=True)
        TRIGGER.touch()
        self.log_message("deploy queued sha=%s", sha)
        self._json(202, {"status": "accepted", "sha": sha})


def main() -> None:
    if not SECRET:
        print(
            "[ghcr-webhook] WARNING: GHCR_WEBHOOK_SECRET is empty — anyone can trigger deploys.",
            file=sys.stderr,
        )
    TRIGGER.parent.mkdir(parents=True, exist_ok=True)
    bind = os.environ.get("GHCR_WEBHOOK_BIND", "0.0.0.0")
    server = HTTPServer((bind, PORT), WebhookHandler)
    print(f"[ghcr-webhook] listening on {bind}:{PORT} trigger={TRIGGER}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
