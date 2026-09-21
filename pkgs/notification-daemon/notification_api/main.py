import json
import logging
import os
import urllib.error
import urllib.request

import apprise
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

CONFIG_PATH = os.environ.get(
    "NOTIFICATION_DAEMON_CONFIG",
    "/etc/notification-daemon/config.json",
)
HOST = os.environ.get("NOTIFICATION_DAEMON_HOST", "127.0.0.1")
PORT = int(os.environ.get("NOTIFICATION_DAEMON_PORT", "5555"))
# Cloudflare Browser Integrity Check blocks the urllib default
# "Python-urllib/3.x" User-Agent, so every ntfy HTTP request carries an
# explicit application User-Agent.
USER_AGENT = "notification-daemon/1.0"
NTFY_PRIORITY_MAP = {
    "info": 1,
    "success": 2,
    "warning": 3,
    "failure": 4,
    "critical": 5,
    "music": 2,
    "system": 3,
}

TOPIC_FALLBACK = {
    "info": "system",
    "success": "system",
    "warning": "system",
    "failure": "services",
    "critical": "services",
    "music": "music",
    "system": "system",
}
app = FastAPI(title="notification-daemon")
logger = logging.getLogger("notification-daemon")

TYPE_MAP = {
    "info": apprise.NotifyType.INFO,
    "success": apprise.NotifyType.SUCCESS,
    "warning": apprise.NotifyType.WARNING,
    "failure": apprise.NotifyType.FAILURE,
    "critical": apprise.NotifyType.FAILURE,
}


def load_config():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as exc:
        logger.error("failed to load config: %s", exc)
        return None


def build_notify_url(bot_token: str, chat_id: str, topic_id: str) -> str:
    return "tgram://%s/%s:%s" % (bot_token, chat_id, topic_id)


def _self_notify(config, title, message):
    """Log to stderr and push via ntfy direct. Never recurses."""
    logger.error("self-notify: %s - %s", title, message)
    if not config:
        return
    ntfy_cfg = config.get("ntfy")
    ntfy_url = (ntfy_cfg or {}).get("server_url")
    if not ntfy_url:
        return
    token = None
    ntf_path = (ntfy_cfg or {}).get("token_file")
    if ntf_path:
        try:
            token = open(ntf_path).read().strip()
        except Exception:
            pass
    headers = {
        "Title": title,
        "Priority": "5",
        "Tags": "warning",
        "User-Agent": USER_AGENT,
    }
    if token:
        headers["Authorization"] = "Bearer %s" % token
    url = "%s/daemon-errors" % ntfy_url.rstrip("/")
    try:
        urllib.request.urlopen(
            urllib.request.Request(url, data=message.encode(), headers=headers),
            timeout=10,
        )
    except Exception:
        pass


def _send_apprise(config, labelled_title, message, notify_type, tier):
    topics = config.get("topics", {})
    topic_id = topics.get(tier)
    if not topic_id:
        return False, "unknown tier '%s'" % tier
    chat_id = config.get("chat_id")
    token_file = config.get("token_file")
    if not chat_id or not token_file:
        return True, None
    try:
        with open(token_file) as f:
            bot_token = f.read().strip()
    except (FileNotFoundError, PermissionError) as exc:
        return False, "cannot read token file: %s" % exc
    url = build_notify_url(bot_token, chat_id, topic_id)
    apobj = apprise.Apprise()
    apobj.add(url)
    apprise_type = TYPE_MAP.get(notify_type, apprise.NotifyType.INFO)
    if not apobj.notify(
        title=labelled_title, body=message or "(no body)", notify_type=apprise_type
    ):
        return False, "apprise dispatch returned False"
    return True, None


def _send_ntfy(
    server_url, topics, token, tier, title, message, notify_type, topic=None
):
    topic_name = topic or TOPIC_FALLBACK.get(tier, "system")
    ntfy_topic = topics.get(topic_name)
    if not ntfy_topic:
        logger.warning(
            "ntfy: unknown topic '%s' (known: %s)", topic_name, ", ".join(topics.keys())
        )
        return False, "unknown ntfy topic '%s'" % topic_name
    url = "%s/%s" % (server_url.rstrip("/"), ntfy_topic)
    priority = NTFY_PRIORITY_MAP.get(notify_type, 3)
    headers = {
        "Title": title,
        "Priority": str(priority),
        "Tags": notify_type,
        "User-Agent": USER_AGENT,
    }
    if token:
        headers["Authorization"] = "Bearer %s" % token
    data = (message or "(no body)").encode()
    req = urllib.request.Request(url, data=data, headers=headers)
    try:
        resp = urllib.request.urlopen(req, timeout=10)
        logger.info(
            "ntfy sent: topic=%s ntfy_topic=%s tier=%s priority=%d status=%d",
            topic_name,
            ntfy_topic,
            tier,
            priority,
            resp.status,
        )
        return True, None
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        logger.error("ntfy HTTP %d: %s", exc.code, body)
        return False, "ntfy HTTP %d: %s" % (exc.code, body)
    except urllib.error.URLError as exc:
        logger.error("ntfy unreachable: %s", exc.reason)
        return False, "ntfy unreachable: %s" % exc.reason


def _dispatch_notification(config, tier, title, message, notify_type, topic):
    labelled_title = "[%s] %s" % (topic or TOPIC_FALLBACK.get(tier, "general"), title)

    apprise_ok = apprise_err = None
    ntfy_ok = ntfy_err = None

    apprise_ok, apprise_err = _send_apprise(
        config, labelled_title, message, notify_type, tier
    )
    if apprise_err:
        logger.error("apprise: %s", apprise_err)

    ntfy_cfg = config.get("ntfy")
    if ntfy_cfg and ntfy_cfg.get("server_url") and ntfy_cfg.get("topics"):
        ntfy_token = None
        ntf = ntfy_cfg.get("token_file")
        if ntf:
            try:
                ntfy_token = open(ntf).read().strip()
            except (FileNotFoundError, PermissionError) as exc:
                logger.warning("cannot read ntfy token: %s", exc)
        ntfy_ok, ntfy_err = _send_ntfy(
            server_url=ntfy_cfg["server_url"],
            topics=ntfy_cfg["topics"],
            token=ntfy_token,
            tier=tier,
            title=labelled_title,
            message=message,
            notify_type=notify_type,
            topic=topic,
        )
        if ntfy_err:
            logger.error("ntfy: %s", ntfy_err)

    errors = []
    if apprise_err:
        errors.append("apprise: %s" % apprise_err)
    if ntfy_err:
        errors.append("ntfy: %s" % ntfy_err)

    if errors:
        _self_notify(config, "dispatch failure: %s" % title, "; ".join(errors))

    return errors


@app.get("/health")
async def health():
    config = load_config()
    if config is None:
        return JSONResponse(
            {"status": "error", "detail": "config not found"}, status_code=503
        )
    return {"status": "ok"}


@app.post("/notify")
async def notify(request: Request):
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"error": "invalid JSON body"}, status_code=400)

    tier = body.get("tier", "info")
    title = body.get("title", "Notification")
    message = body.get("message", "")
    notify_type = body.get("type", "info")
    topic = body.get("topic")

    config = load_config()
    if config is None:
        return JSONResponse({"error": "notification config not found"}, status_code=503)

    errors = _dispatch_notification(config, tier, title, message, notify_type, topic)

    if errors:
        return JSONResponse({"status": "partial", "errors": errors}, status_code=500)

    return {"status": "ok"}


@app.post("/debug/test-notify")
async def test_notify(request: Request):
    config = load_config()
    if config is None:
        return JSONResponse({"error": "notification config not found"}, status_code=503)

    body = {}
    try:
        body = await request.json()
    except Exception:
        pass

    topic = body.get("topic", "system")
    tier = body.get("tier", "info")

    steps = []
    all_ok = True

    steps.append({"label": "config loaded", "ok": True, "detail": CONFIG_PATH})

    ntfy_cfg = config.get("ntfy", {})
    ntfy_enabled = bool(ntfy_cfg.get("server_url") and ntfy_cfg.get("topics"))
    steps.append(
        {
            "label": "ntfy configured",
            "ok": ntfy_enabled,
            "detail": (
                ntfy_cfg.get("server_url", "(not set)")
                if ntfy_enabled
                else "server_url or topics missing"
            ),
        }
    )

    apprise_cfg = (
        config.get("topics") and config.get("chat_id") and config.get("token_file")
    )
    steps.append(
        {
            "label": "telegram configured",
            "ok": bool(apprise_cfg),
            "detail": (
                "chat_id=%s" % config.get("chat_id", "(not set)")
                if apprise_cfg
                else "missing chat_id or token_file"
            ),
        }
    )

    if not ntfy_enabled:
        all_ok = False

    errors = _dispatch_notification(
        config,
        tier=tier,
        title="[test] notification pipeline",
        message="Daemon debug test notification (topic=%s, tier=%s)" % (topic, tier),
        notify_type="info",
        topic=topic,
    )

    steps.append(
        {
            "label": "dispatch",
            "ok": not errors,
            "detail": "; ".join(errors) if errors else "all channels succeeded",
        }
    )
    if errors:
        all_ok = False

    result = {"test_result": "ok" if all_ok else "fail", "steps": steps}
    if errors:
        result["errors"] = errors
    return JSONResponse(result, status_code=200 if all_ok else 500)


@app.get("/debug/ntfy-check")
async def ntfy_check(topic: str = "system"):
    """Step-by-step ntfy connectivity and auth diagnostics."""
    config = load_config()
    if config is None:
        return JSONResponse({"error": "config not found"}, status_code=503)

    steps = []
    all_ok = True

    ntfy_cfg = config.get("ntfy", {})
    server_url = ntfy_cfg.get("server_url", "")
    topics = ntfy_cfg.get("topics", {})
    token_file = ntfy_cfg.get("token_file", "")

    steps.append({"label": "config", "ok": True, "detail": CONFIG_PATH})

    steps.append(
        {
            "label": "server_url",
            "ok": bool(server_url),
            "detail": server_url or "(not set)",
        }
    )
    if not server_url:
        all_ok = False

    steps.append(
        {
            "label": "topics",
            "ok": bool(topics),
            "detail": (
                ", ".join("%s=%s" % (k, v) for k, v in topics.items())
                if topics
                else "(empty)"
            ),
        }
    )

    token = None
    if token_file:
        try:
            token = open(token_file).read().strip()
            steps.append(
                {
                    "label": "token_file",
                    "ok": True,
                    "detail": "%s (%d bytes)" % (token_file, len(token)),
                }
            )
        except (FileNotFoundError, PermissionError) as exc:
            steps.append({"label": "token_file", "ok": False, "detail": str(exc)})
            all_ok = False
    else:
        steps.append({"label": "token_file", "ok": False, "detail": "(not configured)"})
        all_ok = False

    if token:
        steps.append(
            {
                "label": "token format",
                "ok": token.startswith("tk_") and len(token) >= 10,
                "detail": "prefix=%s len=%d" % (token[:3], len(token)),
            }
        )

    ntfy_topic_name = topics.get(topic, topic)
    if not server_url or not ntfy_topic_name:
        steps.append(
            {
                "label": "topic resolve",
                "ok": False,
                "detail": "cannot resolve without server_url",
            }
        )
        all_ok = False
        return JSONResponse(
            {"result": "fail" if all_ok else "incomplete", "steps": steps},
            status_code=200 if all_ok else 500,
        )

    pub_url = "%s/%s" % (server_url.rstrip("/"), ntfy_topic_name)
    steps.append({"label": "publish url", "ok": True, "detail": pub_url})

    headers = {
        "Title": "[ntfy-check] connectivity test",
        "Priority": "1",
        "Tags": "white_check_mark",
        "User-Agent": USER_AGENT,
    }
    if token:
        headers["Authorization"] = "Bearer %s" % token

    try:
        resp = urllib.request.urlopen(
            urllib.request.Request(
                pub_url, data=b"ntfy connectivity check", headers=headers
            ),
            timeout=10,
        )
        steps.append(
            {
                "label": "publish",
                "ok": True,
                "detail": "HTTP %d" % resp.status,
            }
        )
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        steps.append(
            {
                "label": "publish",
                "ok": False,
                "detail": "HTTP %d: %s" % (exc.code, body.strip()),
            }
        )
        all_ok = False
    except urllib.error.URLError as exc:
        steps.append({"label": "publish", "ok": False, "detail": str(exc.reason)})
        all_ok = False

    return JSONResponse(
        {"result": "ok" if all_ok else "fail", "steps": steps},
        status_code=200,
    )
