#!/usr/bin/env python3
"""Bounded offline ingress check for the telemetry OTel adapter.

Runs the real pinned collector binary against the gateway settings the adapter
renders (loopback producer listener + separately addressed additional ingress,
one local mock backend, local `resourceAttributes` enrichment) with only test
plumbing changed. Synthetic OTLP IDs, local receivers only.

Verifies:
  * the two listeners are distinct: the producer listener is loopback, the
    ingress binds its own address and is not reachable on the producer address;
  * admission is enforced by both listeners — a trace-only gateway answers
    traces with 2xx and metrics/logs with a rejection, never an acknowledgement;
  * origin identity survives the gateway: forwarded telemetry keeps its own
    host/service attributes while locally received telemetry gets the gateway's
    local enrichment (and only that);
  * delivery health is exposed on the explicit loopback port and the implicit
    all-interface port 8888 is not created.

Environment:
  OTELCOL       path to the collector binary
  CONFIG        rendered collector config (with @STATE@ already substituted)
  LOCAL_PORT    local OTLP/HTTP receiver port
  INGRESS_ADDR  ingress host address
  INGRESS_PORT  ingress OTLP/HTTP port
  BACKEND_PORT  mock backend port
"""

import gzip
import http.server
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

OTELCOL = os.environ["OTELCOL"]
CONFIG = os.environ["CONFIG"]
LOCAL_PORT = int(os.environ["LOCAL_PORT"])
INGRESS_ADDR = os.environ["INGRESS_ADDR"]
INGRESS_PORT = int(os.environ["INGRESS_PORT"])
BACKEND_PORT = int(os.environ["BACKEND_PORT"])
METRICS_PORT = 9464
LEGACY_METRICS_PORT = 8888


def fail(message):
    print("FAIL: " + message, file=sys.stderr)
    sys.exit(1)


def tail(path, limit=2000):
    """Collector log tail, so a start-up failure is diagnosable from the build
    log alone (the check runs where the collector's own output is redirected)."""
    try:
        with open(path, "rb") as handle:
            return handle.read()[-limit:].decode(errors="replace").strip() or "<empty>"
    except OSError as error:
        return "<no log: %s>" % error


def log(message):
    print("telemetry-ingress: " + message, flush=True)


def bound(address, port, timeout=0.2):
    try:
        with socket.create_connection((address, port), timeout):
            return True
    except OSError:
        return False


def wait_for_bound(address, port, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if bound(address, port):
            return True
        time.sleep(0.05)
    return False


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        raw = self.rfile.read(length) if length else b""
        if self.headers.get("content-encoding") == "gzip":
            raw = gzip.decompress(raw)
        try:
            payload = json.loads(raw)
        except ValueError:
            payload = {}
        with self.server.record_lock:
            for resource_spans in payload.get("resourceSpans", []):
                resource = {
                    attribute["key"]: list(attribute["value"].values())[0]
                    for attribute in resource_spans.get("resource", {}).get("attributes", [])
                }
                for scope_spans in resource_spans.get("scopeSpans", []):
                    for span in scope_spans.get("spans", []):
                        self.server.records.append(
                            {
                                "traceId": span.get("traceId"),
                                "host": resource.get("host.name"),
                                "service": resource.get("service.name"),
                                "resource": resource,
                            }
                        )
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass


class Backend(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port):
        super().__init__(("127.0.0.1", port), _Handler)
        self.records = []
        self.record_lock = threading.Lock()
        threading.Thread(target=self.serve_forever, daemon=True).start()

    def find(self, trace_id):
        with self.record_lock:
            for record in self.records:
                if record["traceId"] == trace_id:
                    return record
        return None

    def await_trace(self, trace_id, deadline):
        end = time.time() + deadline
        while time.time() < end:
            record = self.find(trace_id)
            if record is not None:
                return record
            time.sleep(0.1)
        fail("backend never received trace %s" % trace_id)


def trace_payload(trace_id, host=None, service="probe"):
    attributes = []
    if host is not None:
        attributes.append({"key": "host.name", "value": {"stringValue": host}})
    if service is not None:
        attributes.append({"key": "service.name", "value": {"stringValue": service}})
    return {
        "resourceSpans": [
            {
                "resource": {"attributes": attributes},
                "scopeSpans": [
                    {
                        "scope": {"name": "telemetry-check"},
                        "spans": [
                            {
                                "traceId": trace_id,
                                "spanId": "00000000000000aa",
                                "name": "probe",
                                "kind": 1,
                                "startTimeUnixNano": "1700000000000000000",
                                "endTimeUnixNano": "1700000000000000001",
                            }
                        ],
                    }
                ],
            }
        ]
    }


METRICS_PAYLOAD = {
    "resourceMetrics": [
        {
            "scopeMetrics": [
                {
                    "metrics": [
                        {
                            "name": "probe",
                            "gauge": {
                                "dataPoints": [
                                    {"asInt": "1", "timeUnixNano": "1700000000000000000"}
                                ]
                            },
                        }
                    ]
                }
            ]
        }
    ]
}

LOGS_PAYLOAD = {
    "resourceLogs": [
        {
            "scopeLogs": [
                {
                    "logRecords": [
                        {"timeUnixNano": "1700000000000000000", "body": {"stringValue": "probe"}}
                    ]
                }
            ]
        }
    ]
}


def post(address, port, path, payload):
    request = urllib.request.Request(
        "http://%s:%d%s" % (address, port, path),
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code
    except OSError as error:
        return "connection-error: %s" % error


def fetch_metrics():
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/metrics" % METRICS_PORT, timeout=5) as response:
            return response.read().decode()
    except OSError:
        return ""


def main():
    if bound("127.0.0.1", BACKEND_PORT):
        fail("mock backend port %d is already in use" % BACKEND_PORT)
    backend = Backend(BACKEND_PORT)

    collector_log = open("collector.log", "a")
    collector = subprocess.Popen(
        [OTELCOL, "--config=file:" + CONFIG],
        stdout=collector_log,
        stderr=collector_log,
        start_new_session=True,
    )

    try:
        if not wait_for_bound("127.0.0.1", LOCAL_PORT, 30):
            fail("the producer listener never bound 127.0.0.1:%d; collector log:\n%s" % (LOCAL_PORT, tail("collector.log")))
        if not wait_for_bound(INGRESS_ADDR, INGRESS_PORT, 30):
            fail("the ingress listener never bound %s:%d; collector log:\n%s" % (INGRESS_ADDR, INGRESS_PORT, tail("collector.log")))
        if not wait_for_bound("127.0.0.1", METRICS_PORT, 30):
            fail("the explicit loopback metrics port %d never came up; collector log:\n%s" % (METRICS_PORT, tail("collector.log")))
        if bound("127.0.0.1", LEGACY_METRICS_PORT):
            fail("the collector created the implicit all-interface metrics listener on %d" % LEGACY_METRICS_PORT)
        # A distinct listener, not the same socket reached by another name.
        if bound("127.0.0.1", INGRESS_PORT):
            fail("the ingress port %d is also reachable on the producer address" % INGRESS_PORT)
        if bound(INGRESS_ADDR, LOCAL_PORT):
            fail("the producer port %d is also reachable on the ingress address" % LOCAL_PORT)

        # Traces are admitted; metrics and logs are not, on either listener.
        local_trace = "d1" + "0" * 30
        remote_trace = "d2" + "0" * 30
        status = post("127.0.0.1", LOCAL_PORT, "/v1/traces", trace_payload(local_trace, service="local-app"))
        if status != 200:
            fail("the producer listener rejected an admitted trace (HTTP %s)" % status)
        status = post(
            INGRESS_ADDR,
            INGRESS_PORT,
            "/v1/traces",
            trace_payload(remote_trace, host="relay-a", service="svc-a"),
        )
        if status != 200:
            fail("the ingress rejected an admitted trace (HTTP %s)" % status)

        for address, port, label in (
            ("127.0.0.1", LOCAL_PORT, "producer"),
            (INGRESS_ADDR, INGRESS_PORT, "ingress"),
        ):
            for path, payload, signal_name in (
                ("/v1/metrics", METRICS_PAYLOAD, "metrics"),
                ("/v1/logs", LOGS_PAYLOAD, "logs"),
            ):
                status = post(address, port, path, payload)
                if status == 200:
                    fail("%s listener acknowledged an unadmitted %s request" % (label, signal_name))
                collector_log.write("%s listener rejected %s with %s\n" % (label, signal_name, status))
                print(
                    "telemetry-ingress: %s listener rejected %s with %s" % (label, signal_name, status),
                    flush=True,
                )

        local_record = backend.await_trace(local_trace, 45)
        remote_record = backend.await_trace(remote_trace, 45)
        if local_record["host"] != "gateway":
            fail("local telemetry was not enriched with the gateway host (%r)" % local_record["host"])
        if remote_record["host"] != "relay-a":
            fail("forwarded telemetry was relabelled as %r instead of relay-a" % remote_record["host"])
        if remote_record["service"] != "svc-a":
            fail("forwarded telemetry lost its service identity (%r)" % remote_record["service"])
        if "relay-a" not in json.dumps(remote_record["resource"]):
            fail("forwarded resource attributes were rewritten: %s" % remote_record["resource"])

        metrics = fetch_metrics()
        if "otelcol_exporter_queue_capacity" not in metrics:
            fail("delivery-health metrics exposed no exporter queue capacity")
        collector_log.write("identity preserved: local=%s remote=%s\n" % (local_record["host"], remote_record["host"]))
        print("telemetry-ingress: OK", flush=True)
    finally:
        try:
            os.killpg(os.getpgid(collector.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            collector.kill()
        collector.wait(timeout=30)
        collector_log.close()


if __name__ == "__main__":
    main()
