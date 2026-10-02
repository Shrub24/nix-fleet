#!/usr/bin/env python3
"""Bounded offline delivery check for the telemetry OTel adapter.

Runs the real pinned collector binary against the settings the adapter renders,
with only test plumbing changed (loopback test ports, JSON wire encoding the
local mock receivers can read, sub-second retry intervals, build-directory
delivery state). Synthetic OTLP trace IDs and local mock receivers only: no live
endpoint, no credential, no tailnet.

Phases:
  1. durability  - every backend down, N unique traces accepted (HTTP 200), the
                   collector SIGKILLed, backends started, collector restarted
                   with the same state: all N IDs must arrive on all backends
                   without the producer resending anything.
  2. fan-out     - with one backend down, further accepted IDs must reach the
                   healthy backends and, once that backend returns, its own
                   backlog must arrive with no further producer send.
  3. overflow    - a deliberately tiny persistent queue against a dead backend
                   must reject the request (non-2xx) inside the deadline and
                   record the enqueue failure, never report durable acceptance.
  4. startup     - unusable persistent storage must stop startup, not silently
                   fall back to a volatile queue.
  5. batch timer - acceptance followed by a kill inside a deliberately long
                   batch window must still survive restart.
  6. storage     - a child-only file-growth limit exhausts storage after startup;
                   enqueue fails and is counted while the collector stays live.

Environment:
  OTELCOL        path to the collector binary
  CONFIG         rendered collector config (with @STATE@ already substituted)
  RECEIVE_PORT   local OTLP/HTTP receiver port
  BACKEND_PORTS  comma-separated mock backend ports
  SMALL_CONFIG   config with a tiny queue size, used for the overflow phase
  SMALL_BACKEND  backend port for the overflow phase (never listening)
  BLOCKED_CONFIG config whose delivery storage path cannot be created
  LATE_CONFIG    config whose queue-batch flush interval is deliberately long
  LATE_BACKEND   backend port for the late-flush phase
  LATE_FLUSH_SECONDS  the batch flush interval that config sets
  EXHAUSTED_CONFIG    config for live file-growth exhaustion
  EXHAUSTED_STATE     that config's persistent queue directory
"""

import gzip
import http.server
import json
import os
import resource
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
SMALL_CONFIG = os.environ["SMALL_CONFIG"]
BLOCKED_CONFIG = os.environ["BLOCKED_CONFIG"]
LATE_CONFIG = os.environ["LATE_CONFIG"]
LATE_BACKEND = int(os.environ["LATE_BACKEND"])
LATE_FLUSH_SECONDS = float(os.environ["LATE_FLUSH_SECONDS"])
RECEIVE_PORT = int(os.environ["RECEIVE_PORT"])
BACKEND_PORTS = [int(port) for port in os.environ["BACKEND_PORTS"].split(",")]
SMALL_BACKEND = int(os.environ["SMALL_BACKEND"])
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
    print("telemetry-delivery: " + message, flush=True)


def free_port(port):
    """True when nothing is listening (used to prove absence of a listener)."""
    try:
        with socket.create_connection(("127.0.0.1", port), 0.2):
            return False
    except OSError:
        return True


def wait_for_port(port, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), 0.2):
                return True
        except OSError:
            time.sleep(0.05)
    return False


def wait_for_free(port, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if free_port(port):
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
                                "name": span.get("name"),
                                "host": resource.get("host.name"),
                                "service": resource.get("service.name"),
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

    def stop(self):
        self.shutdown()
        self.server_close()
        self._thread.join(timeout=5)

    def ids(self):
        with self.record_lock:
            return [record["traceId"] for record in self.records]


def trace_payload(trace_id, host=None, service="probe", name="probe"):
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
                                "name": name,
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


def post(port, path, body, timeout=5):
    request = urllib.request.Request(
        "http://127.0.0.1:%d%s" % (port, path),
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code
    except OSError:
        return None


def send_trace(port, trace_id, host=None, service="probe", path="/v1/traces"):
    return post(port, path, json.dumps(trace_payload(trace_id, host, service)).encode())


def fetch_metrics(port, timeout=5):
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/metrics" % port, timeout=timeout) as response:
            return response.read().decode()
    except OSError:
        return ""


def new_id(prefix, index):
    """32 hex characters, unique per prefix/index."""
    return ("%s%02d" % (prefix, index)).ljust(32, "0")


class Collector:
    def __init__(self, config, log_path):
        self.log_path = log_path
        self.log = open(log_path, "ab")
        self.process = subprocess.Popen(
            [OTELCOL, "--config=file:" + config],
            stdout=self.log,
            stderr=self.log,
            start_new_session=True,
        )

    def kill(self):
        try:
            os.killpg(os.getpgid(self.process.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            self.process.kill()
        self.process.wait(timeout=30)
        self.log.close()

    def wait_ready(self, port, timeout=30):
        if not wait_for_port(port, timeout):
            fail("collector did not bind 127.0.0.1:%d within %ds; collector log:\n%s" % (port, timeout, tail(self.log_path)))
        # The receiver socket exists slightly before the pipelines are ready;
        # a probe trace with an unused ID is not sent, so poll the HTTP route.
        deadline = time.time() + timeout
        while time.time() < deadline:
            status = post(port, "/v1/traces", b"{}")
            if status == 200:
                return
            time.sleep(0.1)
        fail("collector receiver on 127.0.0.1:%d never answered 200; collector log:\n%s" % (port, tail(self.log_path)))


def await_ids(backend, expected, deadline, label):
    """Poll until the backend has seen every expected ID (duplicates allowed)."""
    end = time.time() + deadline
    while time.time() < end:
        seen = set(backend.ids())
        if expected <= seen:
            return
        time.sleep(0.1)
    missing = sorted(expected - set(backend.ids()))
    fail("%s never received %s" % (label, missing))


def phase_durability():
    log("phase 1: acceptance survives an abrupt kill (all backends down)")
    ports = BACKEND_PORTS
    for port in ports:
        if not free_port(port):
            fail("mock backend port %d is already in use" % port)
    collector = Collector(CONFIG, "collector-1.log")
    collector.wait_ready(RECEIVE_PORT)

    if not free_port(LEGACY_METRICS_PORT):
        fail("the collector bound the implicit all-interface metrics port %d" % LEGACY_METRICS_PORT)
    if not wait_for_port(METRICS_PORT, 10):
        fail("the explicit loopback metrics port %d never came up" % METRICS_PORT)

    ids = {new_id("a1", index) for index in range(6)}
    for trace_id in sorted(ids):
        status = send_trace(RECEIVE_PORT, trace_id)
        if status != 200:
            fail("trace %s was not accepted while the backends were down (HTTP %s)" % (trace_id, status))
    metrics = fetch_metrics(METRICS_PORT)
    if "otelcol_exporter_queue_capacity" not in metrics:
        fail("delivery-health metrics exposed no exporter queue capacity")
    if '"otlphttp/backendA"' not in metrics and "otlphttp/backendA" not in metrics:
        fail("delivery-health metrics did not name the active exporter")
    log("accepted %d traces with every backend down" % len(ids))

    collector.kill()

    backends = []
    for port in ports:
        backend = Backend(port)
        backend.start()
        backends.append(backend)
        if not wait_for_port(port, 10):
            fail("mock backend %d did not start" % port)

    collector = Collector(CONFIG, "collector-2.log")
    collector.wait_ready(RECEIVE_PORT)
    for backend in backends:
        await_ids(backend, ids, 45, "backend on port %d after restart" % backend.server_port)
    log("all %d traces recovered on %d backends after restart" % (len(ids), len(backends)))
    return collector, backends, ids


def phase_fanout(collector, backends, known):
    log("phase 2: independent fan-out while one backend is unavailable")
    unavailable = backends[1]
    unavailable_port = unavailable.server_port
    unavailable.stop()
    if not wait_for_free(unavailable_port, 10):
        fail("mock backend %d did not stop" % unavailable_port)

    fresh = {new_id("b2", index) for index in range(3)}
    for trace_id in sorted(fresh):
        status = send_trace(RECEIVE_PORT, trace_id)
        if status != 200:
            fail("trace %s was not accepted while one backend was down (HTTP %s)" % (trace_id, status))
    for backend in (backends[0], backends[2]):
        await_ids(backend, fresh, 30, "healthy backend on port %d" % backend.server_port)
    time.sleep(1.0)
    already = set(unavailable.ids())
    if already & fresh:
        fail("the stopped backend received %s" % sorted(already & fresh))

    restarted = Backend(unavailable_port)
    restarted.start()
    wait_for_port(unavailable_port, 10)
    await_ids(restarted, fresh, 45, "recovered backend on port %d" % unavailable_port)
    log("the unavailable backend recovered its backlog without a producer resend")


def phase_overflow():
    log("phase 3: a full queue fails closed within the deadline")
    if not free_port(SMALL_BACKEND):
        fail("overflow backend port %d is already in use" % SMALL_BACKEND)
    collector = Collector(SMALL_CONFIG, "collector-3.log")
    collector.wait_ready(RECEIVE_PORT)

    # Pad each span so the persistent queue (which the config sizes in serialized
    # bytes) can be exhausted in a bounded number of sends.
    filler = "x" * 60000
    deadline = time.time() + 90
    status = None
    attempts = 0
    while time.time() < deadline and attempts < 400:
        attempts += 1
        body = json.dumps(trace_payload(new_id("c3", attempts % 100), name=filler)).encode()
        status = post(RECEIVE_PORT, "/v1/traces", body, timeout=15)
        if status != 200:
            break
    if status is None or status == 200:
        fail("a full persistent queue never rejected a request within 90s")
    metrics = fetch_metrics(METRICS_PORT)
    failures = [
        float(line.rsplit(None, 1)[-1])
        for line in metrics.splitlines()
        if line.startswith("otelcol_exporter_enqueue_failed")
    ]
    if not failures or sum(failures) <= 0:
        fail("enqueue failure was not recorded in the delivery-health metrics")
    log("queue overflow rejected the request with HTTP %s after %d sends and was counted" % (status, attempts))
    collector.kill()


def phase_storage_failure():
    """Unusable persistent storage must stop the collector, not degrade to
    volatile acceptance."""
    log("phase 4: unusable delivery storage fails closed instead of degrading")
    # The configured queue path's parent is a regular file, so the extension
    # cannot create its directory. Privilege-independent: this fails for root too.
    with open("blocker", "w") as handle:
        handle.write("not a directory\n")
    completed = subprocess.run(
        [OTELCOL, "--config=file:" + BLOCKED_CONFIG],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=120,
    )
    if completed.returncode == 0:
        fail("the collector started with unusable delivery storage")
    output = (completed.stdout + completed.stderr).decode(errors="replace")
    if "file_storage" not in output or "problem accessing configured directory" not in output:
        fail("the collector failed for an unexpected reason: %s" % output.strip()[-400:])
    # And nothing was accepted in the meantime: no success without a queue.
    status = send_trace(RECEIVE_PORT, new_id("d4", 0))
    if status == 200:
        fail("a request was accepted while the persistent queue was unusable (HTTP %s)" % status)
    log("the collector refused to run with unusable delivery storage (exit %d)" % completed.returncode)


def phase_batch_timer_independence():
    """Acknowledgement must be durable at accept time, not at a batch flush.

    The config used here sets a deliberately long queue-batch flush interval and
    a byte threshold no single request reaches, so the only way an accepted
    trace can survive an immediate kill is that acceptance already reached the
    persistent queue. Nothing is waited for before the kill: a persistence wait
    would test the wait, not the contract.
    """
    log(
        "phase 5: acceptance is durable before the %ss batch flush interval fires" % LATE_FLUSH_SECONDS
    )
    if not free_port(LATE_BACKEND):
        fail("late-flush backend port %d is already in use" % LATE_BACKEND)
    collector = Collector(LATE_CONFIG, "collector-5.log")
    collector.wait_ready(RECEIVE_PORT)

    ids = {new_id("e5", index) for index in range(4)}
    accepted_at = time.monotonic()
    for trace_id in sorted(ids):
        status = send_trace(RECEIVE_PORT, trace_id)
        if status != 200:
            fail("trace %s was not accepted (HTTP %s)" % (trace_id, status))
    collector.kill()
    # Bound the whole acceptance/kill window, not just the wait for termination.
    # Otherwise an earlier request might already have reached the batch timer.
    window = time.monotonic() - accepted_at
    if window >= LATE_FLUSH_SECONDS:
        fail(
            "acceptance and kill took %.2fs, outside the %ss flush interval; "
            "the phase cannot distinguish persisted acceptance from a timer flush"
            % (window, LATE_FLUSH_SECONDS)
        )

    backend = Backend(LATE_BACKEND)
    backend.start()
    if not wait_for_port(LATE_BACKEND, 10):
        fail("late-flush backend %d did not start" % LATE_BACKEND)
    collector = Collector(LATE_CONFIG, "collector-6.log")
    collector.wait_ready(RECEIVE_PORT)
    await_ids(backend, ids, LATE_FLUSH_SECONDS + 45, "backend after a restart inside the batch window")
    log(
        "all %d traces accepted/killed within %.3fs survived and were delivered "
        "(batch flush interval %ss)" % (len(ids), window, LATE_FLUSH_SECONDS)
    )
    collector.kill()
    backend.stop()


def phase_storage_exhaustion():
    """Exhaust file growth after startup without filling the builder's disk.

    RLIMIT_FSIZE makes the storage engine return a write error while the queue
    still has payload capacity. This tests live failure, unlike the separate
    unusable-directory startup test, and leaves the limit on this child only.
    """
    log("phase 6: live persistent storage exhaustion rejects enqueue")
    collector = Collector(os.environ["EXHAUSTED_CONFIG"], "collector-7.log")
    try:
        collector.wait_ready(RECEIVE_PORT)
        state_dir = os.environ["EXHAUSTED_STATE"]
        sizes = [
            os.stat(os.path.join(state_dir, name)).st_size
            for name in os.listdir(state_dir)
            if os.path.isfile(os.path.join(state_dir, name))
        ]
        if not sizes:
            fail("no persistent storage files were created before the exhaustion probe")
        limit = max(sizes) + 65536
        resource.prlimit(collector.process.pid, resource.RLIMIT_FSIZE, (limit, limit))
        status = 200
        for index in range(20):
            body = json.dumps(trace_payload(new_id("f6", index), name="x" * 65536)).encode()
            status = post(RECEIVE_PORT, "/v1/traces", body, timeout=5)
            if status != 200:
                break
        if status not in (500, 503):
            fail("storage exhaustion did not return an enqueue failure (HTTP %r)" % status)
        metrics = fetch_metrics(METRICS_PORT)
        failures = [
            float(line.rsplit(None, 1)[-1])
            for line in metrics.splitlines()
            if line.startswith("otelcol_exporter_enqueue_failed")
        ]
        if not failures or sum(failures) <= 0:
            fail("live storage exhaustion did not increment the enqueue-failure counter")
        if collector.process.poll() is not None:
            fail("storage exhaustion killed the collector instead of rejecting enqueue")
        log("live storage exhaustion returned HTTP %s and incremented failures (file limit %d bytes)" % (status, limit))
    finally:
        collector.kill()


def main():
    collector, backends, known = phase_durability()
    phase_fanout(collector, backends, known)
    collector.kill()
    for backend in backends:
        backend.stop()
    phase_overflow()
    phase_batch_timer_independence()
    phase_storage_failure()
    phase_storage_exhaustion()
    log("OK")



if __name__ == "__main__":
    main()
