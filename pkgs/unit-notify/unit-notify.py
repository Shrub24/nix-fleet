#!/usr/bin/env python3
"""systemd event handler: post a unit outcome to the notification daemon.

Triggered by OnFailure=/OnSuccess= dependencies; all context comes from the
native $MONITOR_* environment (systemd >= 251) plus the rendered policy map at
/etc/notify/events.json. Exact per-invocation journal is retrieved with
journalctl --invocation=<ID> -u <unit>.
"""

import json
import os
import sys
import urllib.error
import urllib.request

DAEMON_URL = os.environ.get("NOTIFY_URL", "http://127.0.0.1:5555")
POLICY_FILE = os.environ.get("NOTIFY_EVENTS_FILE", "/etc/notify/events.json")

# OnFailure= handlers observe failure transitions; OnSuccess= handlers observe
# clean entry into the inactive state. The handler runs after the transition,
# so the triggering event is disambiguated from the result when needed.
EVENT_BY_RESULT = {"success": "success"}


def load_policy(unit):
    try:
        with open(POLICY_FILE) as f:
            events = json.load(f).get(unit, {})
    except (OSError, ValueError):
        events = {}
    return events


def infer_event(service_result, policy):
    if service_result == "success" and "success" in policy:
        return "success"
    return "failure"


def collect_journal(unit, invocation_id, lines):
    if lines <= 0 or not invocation_id:
        return ""
    import subprocess

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


def build_message(event, policy, result, exit_code, exit_status):
    parts = []
    if policy.get("context", True):
        parts.append("result=%s exit_code=%s exit_status=%s" % (result, exit_code, exit_status))
    return "\n".join(parts)


def post(payload):
    req = urllib.request.Request(
        "%s/notify" % DAEMON_URL,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10):
            return 0
    except (urllib.error.HTTPError, urllib.error.URLError, OSError) as exc:
        print("unit-notify: delivery failed: %s" % exc, file=sys.stderr)
        return 1


def main():
    unit = os.environ.get("MONITOR_UNIT", "")
    if not unit:
        sys.exit("unit-notify: MONITOR_UNIT not set; not triggered by a systemd event dependency")

    invocation_id = os.environ.get("MONITOR_INVOCATION_ID", "")
    result = os.environ.get("MONITOR_SERVICE_RESULT", "unknown")
    exit_code = os.environ.get("MONITOR_EXIT_CODE", "unknown")
    exit_status = os.environ.get("MONITOR_EXIT_STATUS", "unknown")

    policy = load_policy(unit)
    event = infer_event(result, policy)
    entry = policy.get(event, {})

    severity = entry.get("severity", event)
    topic = entry.get("topic")
    lines = int(entry.get("journalLines", 50))
    title = entry.get("title") or ("%s %s" % (unit, event))

    journal = collect_journal(unit, invocation_id, lines)
    body = build_message(event, entry, result, exit_code, exit_status)
    if journal:
        body = (body + "\n\n" + journal).strip() if body else journal

    payload = {
        "tier": severity,
        "title": title,
        "type": severity,
        "message": body,
    }
    if topic:
        payload["topic"] = topic

    sys.exit(post(payload))


if __name__ == "__main__":
    main()
