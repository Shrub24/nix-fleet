"""notify-daemon: the dispatch authority.

Owns the secrets, the policy map, and the journal. Local connectors (the
notify CLI, unit-notify handlers) and external callers (app webhooks) POST
plain HTTP; the daemon performs all dispatch.

Transports:
- unix socket /run/notify/notify.sock (group `notify`): local dispatchers;
  filesystem permissions are the auth model
- loopback TCP :5555: external HTTP callers (beszel webhooks, CI, tunnels)
"""

import json
import logging
import os
import socket
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import config as cfg
from .dispatch import dispatch

log = logging.getLogger("notify-daemon")


def _load_policy():
    try:
        with open(cfg.events_file()) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _collect_journal(unit, invocation_id, lines):
    if lines <= 0 or not invocation_id:
        return ""
    proc = subprocess.run(
        [
            "journalctl",
            f"--invocation={invocation_id}",
            "-u",
            unit,
            "-n",
            str(lines),
            "--no-pager",
            "-q",
        ],
        capture_output=True,
        text=True,
        timeout=15,
    )
    return proc.stdout or ""


def _handle_event(payload):
    """Resolve one systemd unit event: policy, exact-invocation journal, dispatch."""
    unit = payload.get("unit", "")
    if not unit:
        return {"error": "missing unit"}, 400

    event = "success" if payload.get("result") == "success" else "failure"
    entry = _load_policy().get(unit, {}).get(event, {})
    if not entry:
        return {"status": "skipped"}, 200

    severity = entry.get("severity", event)
    topic = entry.get("topic")
    title = entry.get("title") or ("%s %s" % (unit, event))

    parts = []
    if entry.get("context", True):
        parts.append(
            "result=%s exit_code=%s exit_status=%s"
            % (payload.get("result", "unknown"), payload.get("exit_code", "unknown"), payload.get("exit_status", "unknown"))
        )
    journal = _collect_journal(unit, payload.get("invocation_id", ""), int(entry.get("journalLines", 50)))
    if journal:
        parts.append(journal)
    body = "\n\n".join(parts)

    errors = dispatch(severity, title, body, topic=topic)
    if errors:
        return {"status": "partial", "errors": errors}, 500
    return {"status": "ok"}, 200


class Handler(BaseHTTPRequestHandler):
    def _reply(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._reply({"status": "ok", "config": cfg.load() is not None})
        else:
            self._reply({"error": "not found"}, status=404)

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
        except (ValueError, json.JSONDecodeError):
            self._reply({"error": "invalid JSON body"}, status=400)
            return

        if self.path == "/notify":
            # Accepts the legacy notification-daemon schema: `tier` maps to
            # severity, `type` is ignored.
            errors = dispatch(
                body.get("severity", body.get("tier", "info")),
                body.get("title", "Notification"),
                body.get("message", ""),
                topic=body.get("topic"),
            )
            if errors:
                self._reply({"status": "partial", "errors": errors}, status=500)
            else:
                self._reply({"status": "ok"})
        elif self.path == "/event":
            payload, status = _handle_event(body)
            self._reply(payload, status=status)
        else:
            self._reply({"error": "not found"}, status=404)

    def log_message(self, fmt, *args):
        # No address_string(): AF_UNIX clients have no peer address.
        log.info(fmt, *args)


class UnixHTTPServer(ThreadingHTTPServer):
    address_family = socket.AF_UNIX

    def server_bind(self):
        super().server_bind()
        os.chmod(self.server_address, 0o660)


def serve(port, socket_path):
    logging.basicConfig(level=logging.INFO)
    tcp = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    unix = UnixHTTPServer(socket_path, Handler)
    import threading

    for server in (tcp, unix):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    log.info("listening on 127.0.0.1:%d and %s", port, socket_path)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
