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

# The validated severity vocabulary: three values, at the ends and middle of
# ntfy's own 1-5 priority scale. Everything that produces a severity — the Nix
# event policy, the Alertmanager mapping, an HTTP caller — is checked against it
# rather than being allowed to degrade silently into an unfamiliar label.
SEVERITIES = ("info", "warning", "critical")

TYPE_MAP = {
    "info": apprise.NotifyType.INFO,
    "warning": apprise.NotifyType.WARNING,
    "critical": apprise.NotifyType.FAILURE,
}

# ntfy's full priority scale is 1-5; slots 2 and 4 are deliberately unexposed —
# reserved for future severities, so the dispatch surface stays three-valued
# (info | warning | critical).
NTFY_PRIORITY_MAP = {
    "info": 1,
    "warning": 3,
    "critical": 5,
}


def _resolve_topic(settings, topic, transport):
    """Resolve a notification's use-case topic to this transport's destination.

    Topics are routing, declared by the deployment's config: an explicit topic
    names a use-case key, and otherwise the deployment's single default topic
    does. Severity is weight, never a topic selector. An unresolvable topic is a
    named error rather than a silent skip — a notification nobody can route is a
    notification nobody receives.
    """
    name = topic or settings.get("default_topic")
    if not name:
        return None, [
            "%s: notification carries no topic and the deployment declares no default_topic"
            % transport
        ]
    destination = settings.get("topics", {}).get(name)
    if not destination:
        return None, ["%s: unknown topic '%s'" % (transport, name)]
    return destination, []


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

    topic_id, errors = _resolve_topic(settings, topic, "telegram")
    if errors:
        return errors
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
    # Topics are routing, declared by the deployment's config; an explicit
    # topic or the deployment's single default topic selects one. Severity is
    # weight, never a topic selector.
    ntfy_topic, errors = _resolve_topic(ntfy, topic, "ntfy")
    if errors:
        return errors

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
            log.info("ntfy sent: topic=%s status=%d", ntfy_topic, resp.status)
    except (urllib.error.HTTPError, urllib.error.URLError, OSError) as exc:
        return ["ntfy: %s" % exc]
    return []


def dispatch(severity, title, message, topic=None):
    """Send one notification. Returns a list of error strings (empty = all sent)."""
    settings = cfg.load()
    if settings is None:
        return ["config not found"]

    errors = []
    # The title carries the routing topic when the caller named one. It invents
    # nothing otherwise: each transport resolves its own default topic, and a
    # single label could not name them all.
    labelled = "[%s] %s" % (topic, title) if topic else title

    errors += _send_apprise(settings.get("telegram", settings), labelled, message, severity, topic)

    if settings.get("ntfy", {}).get("server_url"):
        errors += _send_ntfy(settings["ntfy"], labelled, message, severity, topic)

    return errors
