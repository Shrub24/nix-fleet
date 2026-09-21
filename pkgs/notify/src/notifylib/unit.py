"""unit-notify: systemd OnFailure=/OnSuccess= connector.

Reads the native $MONITOR_* environment (systemd >= 251) and POSTs the event
to the daemon, which resolves policy and collects the exact invocation
journal. Runs unprivileged by design.
"""

import os
import sys

from .connector import _post, _socket_path, report_error


def main():
    unit = os.environ.get("MONITOR_UNIT", "")
    if not unit:
        sys.exit("unit-notify: MONITOR_UNIT not set; not triggered by a systemd event dependency")

    payload = {
        "unit": unit,
        "invocation_id": os.environ.get("MONITOR_INVOCATION_ID", ""),
        "result": os.environ.get("MONITOR_SERVICE_RESULT", "unknown"),
        "exit_code": os.environ.get("MONITOR_EXIT_CODE", "unknown"),
        "exit_status": os.environ.get("MONITOR_EXIT_STATUS", "unknown"),
    }
    try:
        status, body = _post(_socket_path(), "/event", payload)
    except (OSError, ConnectionError) as exc:
        print("unit-notify: cannot reach daemon: %s" % exc, file=sys.stderr)
        sys.exit(2)
    if status >= 400:
        report_error("unit-notify", status, body)
        sys.exit(1)


if __name__ == "__main__":
    main()
