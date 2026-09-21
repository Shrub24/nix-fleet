"""notify CLI: send semantic/application notifications, or run the daemon."""

import argparse
import os
import sys

from .connector import _post, _daemon_url, _socket_path, report_error
from .daemon import serve as _serve_daemon


def _send(args):
    message = args.message
    if not message and not sys.stdin.isatty():
        message = sys.stdin.read().strip()
    payload = {
        "severity": args.severity,
        "title": args.title,
        "message": message,
    }
    if args.topic:
        payload["topic"] = args.topic
    try:
        status, body = _post(_socket_path(), "/notify", payload)
    except (OSError, ConnectionError) as exc:
        print("notify: cannot reach daemon: %s" % exc, file=sys.stderr)
        sys.exit(2)
    if status >= 400:
        report_error("notify", status, body)
        sys.exit(1)


def _test(args):
    payload = {"severity": args.severity, "title": "notify test", "message": "Test notification from %s." % os.uname().nodename}
    if args.topic:
        payload["topic"] = args.topic
    try:
        status, body = _post(_socket_path(), "/notify", payload)
    except (OSError, ConnectionError) as exc:
        print("notify: cannot reach daemon: %s" % exc, file=sys.stderr)
        sys.exit(2)
    if status >= 400:
        report_error("notify test", status, body)
        sys.exit(1)
    print("sent")


def _serve(args):
    _serve_daemon(args.port, args.socket)


def main():
    parser = argparse.ArgumentParser(
        prog="notify",
        description="Semantic notifications: send via the local daemon, or run it",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_send = sub.add_parser("send", help="Send a notification (stdin = body)")
    p_send.add_argument("severity", choices=["info", "success", "warning", "failure", "critical"])
    p_send.add_argument("title", nargs="?", default="Notification")
    p_send.add_argument("--topic", default=None)
    p_send.add_argument("message", nargs="?", default="")

    p_test = sub.add_parser("test", help="Send a test notification end-to-end")
    p_test.add_argument("--topic", default=None)
    p_test.add_argument("--severity", default="info", choices=["info", "success", "warning", "failure", "critical"])

    p_serve = sub.add_parser("serve", help="Run the notify daemon")
    p_serve.add_argument("--port", type=int, default=5555)
    p_serve.add_argument("--socket", default="/run/notify/notify.sock")

    args = parser.parse_args()
    if args.command == "send":
        _send(args)
    elif args.command == "test":
        _test(args)
    elif args.command == "serve":
        _serve(args)


if __name__ == "__main__":
    main()
