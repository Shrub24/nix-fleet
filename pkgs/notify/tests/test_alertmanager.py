"""Offline tests for the Alertmanager webhook route and its payload mapping.

Run by `checks.notify-alertmanager`. Nothing leaves loopback: the daemon
handler under test and the ntfy stub it dispatches to are real HTTP servers,
and the stub records exactly what dispatch delivered, so the route's topic and
severity choices are asserted end to end rather than re-derived from the
mapping function.
"""

import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# notifylib resolves the config path at import time, so the seam is set before
# the package is imported; the file itself is written in setUpClass, once the
# ntfy stub's port is known.
_TEST_DIR = tempfile.mkdtemp(prefix="notify-alertmanager-test-")
os.environ["NOTIFY_CONFIG_FILE"] = os.path.join(_TEST_DIR, "config.json")

from notifylib import alertmanager, dispatch  # noqa: E402  (import after the env seam)
from notifylib.daemon import Handler  # noqa: E402


def firing_group(severities=("critical", "page"), name="FixtureHighLoad"):
    """A firing Alertmanager group: two alerts, the second resolving to info."""
    return {
        "version": "4",
        "status": "firing",
        "receiver": "notify",
        "commonLabels": {"alertname": name},
        "groupLabels": {"alertname": name},
        "commonAnnotations": {},
        "externalURL": "http://alertmanager.invalid:9093",
        "alerts": [
            {
                "status": "firing",
                "labels": {
                    "alertname": name,
                    "severity": severities[0],
                    "instance": "fixture-1",
                },
                "annotations": {"summary": "CPU pegged at 99%", "description": "ignored"},
                "startsAt": "2026-01-01T00:00:00Z",
                "fingerprint": "aaaa",
            },
            {
                "status": "firing",
                "labels": {
                    "alertname": name,
                    "severity": severities[1],
                    "instance": "fixture-2",
                },
                "annotations": {"description": "disk full"},
                "startsAt": "2026-01-01T00:00:00Z",
                "fingerprint": "bbbb",
            },
        ],
    }


class TestMapPayload(unittest.TestCase):
    def test_firing_group_is_one_message_at_its_worst_member_severity(self):
        severity, title, body = alertmanager.map_payload(firing_group())
        self.assertEqual(severity, "critical")
        self.assertEqual(title, "[firing] FixtureHighLoad")
        # The group mixes severities (critical + an unknown label -> info), so
        # each line carries its own weight; summary wins over description, and
        # description wins over alertname.
        self.assertEqual(
            body, "[critical] fixture-1: CPU pegged at 99%\n[info] fixture-2: disk full"
        )

    def test_resolved_group_is_info_whatever_the_labels_say(self):
        payload = firing_group()
        payload["status"] = "resolved"
        severity, title, body = alertmanager.map_payload(payload)
        self.assertEqual(severity, "info")
        self.assertEqual(title, "[resolved] FixtureHighLoad")
        # Every member is info here, so the lines carry no prefix.
        self.assertEqual(body, "fixture-1: CPU pegged at 99%\nfixture-2: disk full")

    def test_only_warning_and_critical_labels_carry_weight(self):
        for declared in ("warning", "critical", "info", "page", "", None):
            with self.subTest(severity=declared):
                payload = firing_group(severities=(declared, declared))
                severity, _, _ = alertmanager.map_payload(payload)
                self.assertEqual(severity, declared if declared in ("warning", "critical") else "info")

    def test_warning_group_stays_warning(self):
        severity, title, _ = alertmanager.map_payload(firing_group(severities=("warning", "info")))
        self.assertEqual(severity, "warning")
        self.assertEqual(title, "[firing] FixtureHighLoad")

    def test_alertname_falls_back_to_the_first_alert(self):
        payload = firing_group()
        del payload["commonLabels"]
        _, title, _ = alertmanager.map_payload(payload)
        self.assertEqual(title, "[firing] FixtureHighLoad")

    def test_summary_falls_back_to_the_alertname(self):
        payload = firing_group()
        payload["alerts"][0]["annotations"] = {}
        _, _, body = alertmanager.map_payload(payload)
        self.assertEqual(body.splitlines()[0], "[critical] fixture-1: FixtureHighLoad")

    def test_alert_without_an_instance_is_still_named(self):
        payload = firing_group()
        del payload["alerts"][0]["labels"]["instance"]
        _, _, body = alertmanager.map_payload(payload)
        self.assertEqual(body.splitlines()[0], "[critical] FixtureHighLoad: CPU pegged at 99%")

    def test_payloads_that_are_not_an_alertmanager_group_are_refused(self):
        cases = {
            "not a mapping": ["firing"],
            "unknown status": {"status": "pending", "alerts": [{"labels": {}}]},
            "missing status": {"alerts": [{"labels": {"alertname": "X"}}]},
            "missing alerts": {"status": "firing"},
            "empty alerts": {"status": "firing", "alerts": []},
            "alerts not objects": {"status": "firing", "alerts": ["X"]},
            "no alertname anywhere": {"status": "firing", "alerts": [{"labels": {"severity": "critical"}}]},
        }
        for description, payload in cases.items():
            with self.subTest(case=description):
                with self.assertRaises(alertmanager.PayloadError):
                    alertmanager.map_payload(payload)


class TestTopicRouting(unittest.TestCase):
    """Routing is declared by use case; nothing about it is severity-derived."""

    def test_explicit_topic_wins_over_the_default(self):
        settings = {"topics": {"infra": "infra-topic", "general": "general-topic"},
                    "default_topic": "general"}
        self.assertEqual(dispatch._resolve_topic(settings, "infra", "ntfy"), ("infra-topic", []))

    def test_untopiced_notification_uses_the_deployments_default(self):
        settings = {"topics": {"general": "general-topic"}, "default_topic": "general"}
        self.assertEqual(dispatch._resolve_topic(settings, None, "ntfy"), ("general-topic", []))

    def test_a_deployment_without_a_default_refuses_rather_than_drops(self):
        # The pre-realignment shape: a use-case map but no declared default.
        settings = {"topics": {"infra": "infra-topic"}}
        destination, errors = dispatch._resolve_topic(settings, None, "ntfy")
        self.assertIsNone(destination)
        self.assertEqual(
            errors,
            ["ntfy: notification carries no topic and the deployment declares no default_topic"],
        )

    def test_an_unknown_topic_is_named_by_transport(self):
        settings = {"topics": {"infra": "infra-topic"}, "default_topic": "infra"}
        self.assertEqual(
            dispatch._resolve_topic(settings, "absent", "telegram")[1],
            ["telegram: unknown topic 'absent'"],
        )

    def test_telegram_is_routed_by_the_same_rule(self):
        settings = {"topics": {"fleet": "4"}, "default_topic": "fleet"}
        self.assertEqual(dispatch._resolve_topic(settings, None, "telegram"), ("4", []))

    def test_the_validated_severity_vocabulary_is_three_valued(self):
        self.assertEqual(dispatch.SEVERITIES, ("info", "warning", "critical"))
        # Event kinds are not severities: nothing here maps them.
        self.assertNotIn("failure", dispatch.TYPE_MAP)
        self.assertNotIn("success", dispatch.NTFY_PRIORITY_MAP)


class _RecordingNtfy(BaseHTTPRequestHandler):
    """Stands in for the ntfy server: records the request, always accepts."""

    received = []

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length))
        _RecordingNtfy.received.append({"path": self.path, "body": body})
        reply = json.dumps({"id": "stub"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *args):
        pass


class TestAlertmanagerEndpoint(unittest.TestCase):
    """The real handler on loopback, dispatching to a recording ntfy stub."""

    @classmethod
    def setUpClass(cls):
        cls.ntfy = ThreadingHTTPServer(("127.0.0.1", 0), _RecordingNtfy)
        ntfy_port = cls.ntfy.server_address[1]
        threading.Thread(target=cls.ntfy.serve_forever, daemon=True).start()

        with open(os.environ["NOTIFY_CONFIG_FILE"], "w") as f:
            json.dump(
                {
                    "ntfy": {
                        "server_url": "http://127.0.0.1:%d" % ntfy_port,
                        # A use-case map plus the single default use case, as
                        # the notify aspect's options define them.
                        "topics": {"infra": "infra-topic", "general": "fleet-topic"},
                        "default_topic": "general",
                    }
                },
                f,
            )

        cls.daemon = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.base = "http://127.0.0.1:%d" % cls.daemon.server_address[1]
        threading.Thread(target=cls.daemon.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.daemon.shutdown()
        cls.daemon.server_close()
        cls.ntfy.shutdown()
        cls.ntfy.server_close()

    def setUp(self):
        _RecordingNtfy.received = []

    def post(self, path, payload):
        request = urllib.request.Request(
            self.base + path,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def last_delivery(self):
        self.assertEqual(len(_RecordingNtfy.received), 1)
        return _RecordingNtfy.received[0]

    def test_group_reaches_the_topic_named_by_the_receiver_url(self):
        status, reply = self.post("/alertmanager?topic=infra", firing_group())
        self.assertEqual((status, reply), (200, {"status": "ok"}))
        delivery = self.last_delivery()
        self.assertEqual(delivery["path"], "/infra-topic")
        self.assertEqual(delivery["body"]["priority"], 5)  # critical
        self.assertEqual(delivery["body"]["Tags"], "critical")
        self.assertEqual(delivery["body"]["title"], "[infra] [firing] FixtureHighLoad")
        self.assertEqual(
            delivery["body"]["body"],
            "[critical] fixture-1: CPU pegged at 99%\n[info] fixture-2: disk full",
        )

    def test_group_without_a_topic_uses_the_deployment_default(self):
        payload = firing_group(severities=("warning", "info"))
        status, reply = self.post("/alertmanager", payload)
        self.assertEqual((status, reply), (200, {"status": "ok"}))
        delivery = self.last_delivery()
        # The default use case resolves to its own ntfy topic. The title names
        # only a topic the caller asked for, so it carries no invented label.
        self.assertEqual(delivery["path"], "/fleet-topic")
        self.assertEqual(delivery["body"]["title"], "[firing] FixtureHighLoad")
        self.assertEqual(delivery["body"]["priority"], 3)  # warning
        self.assertEqual(delivery["body"]["Tags"], "warning")

    def test_resolved_group_is_delivered_at_info_weight(self):
        payload = firing_group()
        payload["status"] = "resolved"
        status, reply = self.post("/alertmanager?topic=infra", payload)
        self.assertEqual((status, reply), (200, {"status": "ok"}))
        delivery = self.last_delivery()
        self.assertEqual(delivery["body"]["priority"], 1)  # info
        self.assertEqual(delivery["body"]["title"], "[infra] [resolved] FixtureHighLoad")

    def test_unknown_topic_is_a_partial_delivery_not_a_silent_drop(self):
        status, reply = self.post("/alertmanager?topic=absent", firing_group())
        self.assertEqual(status, 500)
        self.assertEqual(reply["status"], "partial")
        self.assertIn("ntfy: unknown topic 'absent'", reply["errors"])

    def test_malformed_payload_is_refused_with_a_plain_english_error(self):
        status, reply = self.post("/alertmanager?topic=infra", {"hello": "world"})
        self.assertEqual(status, 400)
        self.assertIn("alertmanager payload status must be", reply["error"])
        self.assertEqual(_RecordingNtfy.received, [])

    def test_invalid_json_is_still_refused(self):
        request = urllib.request.Request(
            self.base + "/alertmanager",
            data=b"{not json",
            headers={"Content-Type": "application/json"},
        )
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request)
        self.assertEqual(caught.exception.code, 400)

    def test_an_unknown_severity_is_refused_not_downgraded(self):
        status, reply = self.post(
            "/notify", {"severity": "failure", "title": "event vocabulary as severity"}
        )
        self.assertEqual(status, 400)
        self.assertIn("unknown severity 'failure'", reply["error"])
        self.assertIn("info, warning, critical", reply["error"])
        self.assertEqual(_RecordingNtfy.received, [])

    def test_the_other_routes_still_route(self):
        status, reply = self.post("/notify", {"severity": "info", "title": "fixture"})
        self.assertEqual((status, reply), (200, {"status": "ok"}))
        self.assertEqual(self.last_delivery()["path"], "/fleet-topic")
        status, reply = self.post("/nowhere", {"severity": "info"})
        self.assertEqual((status, reply), (404, {"error": "not found"}))


if __name__ == "__main__":
    unittest.main()
