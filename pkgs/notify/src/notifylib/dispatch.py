"""Dispatch a notification to Telegram (apprise) and ntfy (HTTP).

Shared by the notify CLI and the unit-notify systemd handler. Delivery is
best-effort by design: dispatch failures are logged, never raised, so a
broken notification pipeline cannot influence the unit it observes.
"""

import json
import logging
import urllib.error
import urllib.request

import apprise

from . import config as cfg

log = logging.getLogger("notify")

TYPE_MAP = {
    "info": apprise.NotifyType.INFO,
    "success": apprise.NotifyType.SUCCESS,
    "warning": apprise.NotifyType.WARNING,
    "failure": apprise.NotifyType.FAILURE,
    "critical": apprise.NotifyType.FAILURE,
}

NTFY_PRIORITY_MAP = {
    "info": 1,
    "success": 2,
    "warning": 3,
    "failure": 4,
    "critical": 5,
}

TOPIC_FALLBACK = {
    "critical": "system",
    "failure": "system",
    "warning": "system",
    "success": "system",
    "info": "general",
}


def _send_apprise(settings, title, message, severity, topic):
    token_file = settings.get("token_file")
    if not token_file or not settings.get("chat_id"):
        return []
    try:
        with open(token_file) as f:
            bot_token = f.read().strip()
    except OSError as exc:
        log.error("telegram token unreadable: %s", exc)
        return ["telegram: token unreadable"]

    topic_id = settings.get("topics", {}).get(topic or "")
    if not topic_id:
        return []
    url = "tgram://%s/%s:%s" % (bot_token, settings["chat_id"], topic_id)
    apobj = apprise.Apprise()
    apobj.add(url)
    if not apobj.notify(
        title=title,
        body=message or "(no body)",
        notify_type=TYPE_MAP.get(severity, apprise.NotifyType.INFO),
    ):
        return ["telegram: delivery failed"]
    return []


def _send_ntfy(ntfy, title, message, severity, topic):
    server = ntfy.get("server_url")
    if not server:
        return []
    topic_name = topic or TOPIC_FALLBACK.get(severity, "system")
    ntfy_topic = ntfy.get("topics", {}).get(topic_name)
    if not ntfy_topic:
        return ["ntfy: unknown topic '%s'" % topic_name]

    body = {
        "topic": ntfy_topic,
        "title": title,
        "body": message or "(no body)",
        "priority": NTFY_PRIORITY_MAP.get(severity, 3),
        "Tags": severity,
    }
    headers = {"Content-Type": "application/json"}
    token_file = ntfy.get("token_file")
    if token_file:
        try:
            with open(token_file) as f:
                headers["Authorization"] = "Bearer %s" % f.read().strip()
        except OSError:
            pass  # best-effort: send unauthenticated rather than not at all

    req = urllib.request.Request(
        "%s/%s" % (server.rstrip("/"), ntfy_topic),
        data=json.dumps(body).encode(),
        headers=headers,
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            log.info("ntfy sent: topic=%s status=%d", topic_name, resp.status)
    except (urllib.error.HTTPError, urllib.error.URLError, OSError) as exc:
        return ["ntfy: %s" % exc]
    return []


def dispatch(severity, title, message, topic=None):
    """Send one notification. Returns a list of error strings (empty = all sent)."""
    settings = cfg.load()
    if settings is None:
        return ["config not found"]

    errors = []
    labelled = "[%s] %s" % (topic or "general", title)

    errors += _send_apprise(settings.get("telegram", settings), labelled, message, severity, topic)

    if settings.get("ntfy", {}).get("server_url"):
        errors += _send_ntfy(settings["ntfy"], labelled, message, severity, topic)

    return errors
