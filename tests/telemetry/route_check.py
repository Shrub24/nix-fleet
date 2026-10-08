#!/usr/bin/env python3
"""Bounded offline route-isolation check for the telemetry OTel gateway.

Runs the real pinned collector binary against a rendered two-route config: a
loopback general producer listener whose traces go to one mock backend, and an
explicitly declared route listener whose traces go to a second mock backend
that starts down. Synthetic OTLP IDs, loopback listeners and local mock
receivers only: no live endpoint, no credential, no tailnet.

Verifies:
  * a trace reaches only the destinations its own route's policy names — the
    general listener never reaches the route's backend and the route listener
    never reaches the general backend, and the two listeners are distinct
    sockets;
  * route identity survives the pipeline batch processor: two traces posted back
    to back to the two listeners land only in their own backends;
  * a session carrying several spans in one resource arrives whole and only at
    its own route's backend;
  * one route's backend outage is isolated: a route trace is accepted and queued
    while that backend is down, the general route keeps delivering, the queued
    trace is delivered once the backend returns, and general-route traffic is
    never replayed to the recovered backend.

Environment:
  OTELCOL               path to the collector binary
  CONFIG                rendered collector config (@STATE@ already substituted)
  LOCAL_PORT            general (producer) OTLP/HTTP listener port
  ROUTE_ADDR            route listener bind address
  ROUTE_PORT            route OTLP/HTTP listener port
  GENERAL_BACKEND_PORT  general route's mock backend port
  AI_BACKEND_PORT       route's mock backend port (down for the first phase)
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
ROUTE_ADDR = os.environ["ROUTE_ADDR"]
ROUTE_PORT = int(os.environ["ROUTE_PORT"])
GENERAL_BACKEND_PORT = int(os.environ["GENERAL_BACKEND_PORT"])
AI_BACKEND_PORT = int(os.environ["AI_BACKEND_PORT"])


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
    print("telemetry-route-isolation: " + message, flush=True)


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


def new_id(prefix, index):
    """32 lowercase hex characters, unique per prefix/index."""
    return ("%s%02d" % (prefix, index)).ljust(32, "0")


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
                for scope_spans in resource_spans.get("scopeSpans", []):
                    for span in scope_spans.get("spans", []):
                        self.server.records.append(
                            {
                                "traceId": span.get("traceId"),
                                "spanId": span.get("spanId"),
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
        self._thread = threading.Thread(target=self.serve_forever, daemon=True)

    def start(self):
        self._thread.start()

    def span_ids(self, trace_id):
        with self.record_lock:
            return {record["spanId"] for record in self.records if record["traceId"] == trace_id}

    def await_trace(self, trace_id, deadline, expect=1):
        """Wait until the backend holds at least `expect` distinct spans of the
        trace, then return them. A bounded wait: the check never hangs on a
        delivery that never happens."""
        end = time.time() + deadline
        while True:
            spans = self.span_ids(trace_id)
            if len(spans) >= expect:
                return spans
            if time.time() >= end:
                fail(
                    "the backend on %d received %d of %d spans of trace %s within %ss"
                    % (self.server_port, len(spans), expect, trace_id, deadline)
                )
            time.sleep(0.1)


def absent(backend, trace_id, window, message):
    """Assert a trace never arrives: a destination that must receive nothing is
    watched for a bounded settle window rather than merely left unchecked."""
    end = time.time() + window
    while time.time() < end:
        if backend.span_ids(trace_id):
            fail(message)
        time.sleep(0.1)
    log("trace %s absent on backend %d after %.0fs" % (trace_id, backend.server_port, window))


def trace_payload(trace_id, span_count=1):
    return {
        "resourceSpans": [
            {
                "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "probe"}}]},
                "scopeSpans": [
                    {
                        "scope": {"name": "telemetry-check"},
                        "spans": [
                            {
                                "traceId": trace_id,
                                "spanId": "000000000000%04x" % (index + 1),
                                "name": "probe-%d" % (index + 1),
                                "kind": 1,
                                "startTimeUnixNano": "1700000000000000000",
                                "endTimeUnixNano": "1700000000000000001",
                            }
                            for index in range(span_count)
                        ],
                    }
                ],
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


def send(address, port, trace_id, span_count=1, context=""):
    status = post(address, port, "/v1/traces", trace_payload(trace_id, span_count))
    if status != 200:
        fail("%s was not accepted (HTTP %s)" % (context, status))
    return status


def main():
    for port in (GENERAL_BACKEND_PORT, AI_BACKEND_PORT):
        if bound("127.0.0.1", port):
            fail("mock backend port %d is already in use" % port)

    general = Backend(GENERAL_BACKEND_PORT)
    general.start()

    collector_log = open("collector.log", "a")
    collector = subprocess.Popen(
        [OTELCOL, "--config=file:" + CONFIG],
        stdout=collector_log,
        stderr=collector_log,
        start_new_session=True,
    )

    try:
        if not wait_for_bound("127.0.0.1", LOCAL_PORT, 30):
            fail("the general listener never bound 127.0.0.1:%d; collector log:\n%s" % (LOCAL_PORT, tail("collector.log")))
        if not wait_for_bound(ROUTE_ADDR, ROUTE_PORT, 30):
            fail(
                "the route listener never bound %s:%d; collector log:\n%s"
                % (ROUTE_ADDR, ROUTE_PORT, tail("collector.log"))
            )
        # Route identity is the listener: the two must be distinct sockets, not
        # one receiver reached under two names.
        if bound("127.0.0.1", ROUTE_PORT):
            fail("the route port %d is also reachable on the general producer address" % ROUTE_PORT)
        if bound(ROUTE_ADDR, LOCAL_PORT):
            fail("the general producer port %d is also reachable on the route address" % LOCAL_PORT)

        # Phase 1: the route's backend is down. Its queue must hold the route's
        # traffic without contaminating the general route, and the recovered
        # backend must not receive general-route traffic.
        log("phase 1: route backend down — accept, queue, isolate")
        queued = new_id("a1", 1)
        send(ROUTE_ADDR, ROUTE_PORT, queued, span_count=2, context="a route trace while its backend was down")
        live = new_id("a2", 1)
        send("127.0.0.1", LOCAL_PORT, live, context="a general trace while the route backend was down")
        general.await_trace(live, 30)
        absent(general, queued, 5, "the general backend received the route's queued trace")
        log("route trace accepted and queued; the general route kept delivering")

        ai = Backend(AI_BACKEND_PORT)
        ai.start()
        if not wait_for_bound("127.0.0.1", AI_BACKEND_PORT, 10):
            fail("the recovered route backend did not start")
        spans = ai.await_trace(queued, 60, expect=2)
        log("queued route trace delivered with %d spans once the backend recovered" % len(spans))
        absent(ai, live, 5, "the recovered route backend received general-route traffic")
        log("one route's outage stayed scoped: no queued or replayed trace crossed routes")

        # Phase 2: both backends healthy. Each listener's traffic reaches only
        # its own route's destinations.
        log("phase 2: explicit route isolation")
        general_trace = new_id("b1", 1)
        route_trace = new_id("b2", 1)
        send("127.0.0.1", LOCAL_PORT, general_trace, context="a general trace")
        send(ROUTE_ADDR, ROUTE_PORT, route_trace, context="a route trace")
        general.await_trace(general_trace, 30)
        ai.await_trace(route_trace, 30)
        absent(general, route_trace, 5, "the general backend received the route's trace")
        absent(ai, general_trace, 5, "the route backend received the general trace")

        # Phase 3: two traces posted back to back, inside the pipeline batch
        # window, must still land only in their own backends.
        log("phase 3: back-to-back traces under the pipeline batch processor")
        first = new_id("c1", 1)
        second = new_id("c2", 1)
        send("127.0.0.1", LOCAL_PORT, first, context="the first of a back-to-back pair")
        send(ROUTE_ADDR, ROUTE_PORT, second, context="the second of a back-to-back pair")
        general.await_trace(first, 30)
        ai.await_trace(second, 30)
        absent(general, second, 5, "the general backend received the route trace of a back-to-back pair")
        absent(ai, first, 5, "the route backend received the general trace of a back-to-back pair")

        # Phase 4: one resource carrying a whole session must arrive whole, and
        # only at its own route's backend.
        log("phase 4: a multi-span session stays whole and on its route")
        session = new_id("d1", 1)
        send(ROUTE_ADDR, ROUTE_PORT, session, span_count=3, context="a three-span route session")
        spans = ai.await_trace(session, 30, expect=3)
        log("the three-span session arrived at the route backend with %d spans" % len(spans))
        absent(general, session, 5, "the general backend received the route's session")

        log("OK")
    finally:
        try:
            os.killpg(os.getpgid(collector.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            collector.kill()
        collector.wait(timeout=30)
        collector_log.close()


if __name__ == "__main__":
    main()
