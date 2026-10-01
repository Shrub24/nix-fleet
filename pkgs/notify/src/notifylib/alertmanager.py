"""Alertmanager webhook payload -> one notification.

An Alertmanager *group* is one message: the daemon's `/alertmanager` route maps
a whole webhook body (all alerts in the group) into a single dispatch call, so a
burst of alerts sharing a group never fans out into a burst of notifications.

Severity is the group's worst member (critical > warning > info) because the
notification carries the group's weight. Members are listed as
`instance: summary`, one line each — and each line is prefixed with its own
severity only when the group mixes severities, which is exactly the case where
"which host is the critical one?" is the question being asked; a uniform group
would just repeat the notification's own severity on every line. Alertmanager's
label vocabulary is not ours, so a label that is not `warning`/`critical` is
info — never a guess.
"""

SEVERITY_ORDER = ("info", "warning", "critical")

# Alertmanager statuses the webhook contract defines. A body with any other
# status is not an Alertmanager webhook and is refused rather than guessed at.
STATUSES = ("firing", "resolved")


class PayloadError(ValueError):
    """A request body that is not an Alertmanager webhook group."""


def _mapping(value):
    """An Alertmanager sub-object; anything that is not a mapping reads empty."""
    return value if isinstance(value, dict) else {}


def _alert_severity(status, alert):
    if status == "resolved":
        return "info"
    declared = _mapping(alert.get("labels")).get("severity")
    return declared if declared in ("warning", "critical") else "info"


def _alert_line(alert, with_severity):
    labels = _mapping(alert.get("labels"))
    annotations = _mapping(alert.get("annotations"))
    name = labels.get("alertname") or "unknown"
    summary = annotations.get("summary") or annotations.get("description") or name
    where = labels.get("instance") or name
    if with_severity:
        declared = labels.get("severity")
        return "[%s] %s: %s" % (
            declared if declared in ("warning", "critical") else "info",
            where,
            summary,
        )
    return "%s: %s" % (where, summary)


def map_payload(payload):
    """Return (severity, title, body) for one Alertmanager webhook group.

    Raises PayloadError for anything that is not an Alertmanager webhook group;
    the caller turns that into a 400 with the message, never a silent drop.
    """
    if not isinstance(payload, dict):
        raise PayloadError("alertmanager payload must be a JSON object")

    status = payload.get("status")
    if status not in STATUSES:
        raise PayloadError(
            'alertmanager payload status must be "firing" or "resolved", got %r' % (status,)
        )

    alerts = payload.get("alerts")
    if not isinstance(alerts, list) or not alerts:
        raise PayloadError("alertmanager payload must carry a non-empty alerts list")
    if not all(isinstance(alert, dict) for alert in alerts):
        raise PayloadError("alertmanager payload alerts must be objects")

    name = _mapping(payload.get("commonLabels")).get("alertname") or _mapping(
        alerts[0].get("labels")
    ).get("alertname")
    if not name:
        raise PayloadError(
            "alertmanager payload carries no alertname, so the notification has no title "
            "(neither commonLabels.alertname nor alerts[0].labels.alertname)"
        )

    members = [_alert_severity(status, alert) for alert in alerts]
    severity = max(members, key=SEVERITY_ORDER.index)
    # Per-member severity earns its line-width only when the group disagrees
    # with itself; the notification's own severity covers the uniform case.
    mixed = len(set(members)) > 1
    title = "[%s] %s" % (status, name)
    return severity, title, "\n".join(_alert_line(alert, mixed) for alert in alerts)
