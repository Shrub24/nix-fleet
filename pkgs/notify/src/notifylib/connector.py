"""Connectors for the notify daemon: CLI and systemd event handler.

Both are thin HTTP clients — the daemon owns secrets, policy, and journal
access, so these run unprivileged.
"""

import json
import os
import sys
import urllib.error
import urllib.request


def _post(daemon, path, payload):
    if daemon.startswith("/"):
        # Unix socket transport
        import socket

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(daemon)
            body = json.dumps(payload).encode()
            sock.sendall(
                (
                    "POST %s HTTP/1.0\r\nHost: notify\r\nContent-Type: application/json\r\n"
                    "Content-Length: %d\r\n\r\n" % (path, len(body))
                ).encode()
                + body
            )
            sock.shutdown(socket.SHUT_WR)
            data = b""
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                data += chunk
            head, _, rest = data.partition(b"\r\n\r\n")
            status_line = head.split(b"\r\n")[0]
            return int(status_line.split(b" ")[1]), rest
        finally:
            sock.close()
    req = urllib.request.Request(
        "http://%s%s" % (daemon, path),
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def _socket_path():
    return os.environ.get("NOTIFY_SOCKET_PATH", "/run/notify/notify.sock")


def report_error(prefix, status, body):
    print("%s: daemon error %s: %s" % (prefix, status, body.decode(errors="replace")[:200]), file=sys.stderr)
