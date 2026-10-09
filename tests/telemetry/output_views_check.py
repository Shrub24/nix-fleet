#!/usr/bin/env python3
"""Bounded runtime check for the native Collector output-view recipe.

Runs the pinned Collector against loopback mock OTLP/HTTP backends. It verifies
that the selected route sends independent lean/rich copies, ordinary-only and
late-continuation spans remain whole, general traffic stays general, and the
Latitude view exposes parser-compatible attributes for the separate pinned
Latitude 0.3.118 parser probe. No live endpoint, credential or tail sampler.
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
GENERAL_PORT = int(os.environ["GENERAL_PORT"])
ROUTE_ADDR = os.environ["ROUTE_ADDR"]
ROUTE_PORT = int(os.environ["ROUTE_PORT"])
GENERAL_BACKEND_PORT = int(os.environ["GENERAL_BACKEND_PORT"])
STORE_BACKEND_PORT = int(os.environ["STORE_BACKEND_PORT"])
LANGFUSE_BACKEND_PORT = int(os.environ["LANGFUSE_BACKEND_PORT"])
LATITUDE_BACKEND_PORT = int(os.environ["LATITUDE_BACKEND_PORT"])
LATITUDE_ATTRS_OUT = os.environ["LATITUDE_ATTRS_OUT"]


def fail(message):
    print("FAIL: " + message, file=sys.stderr)
    sys.exit(1)


def log(message):
    print("telemetry-output-view-isolation: " + message, flush=True)


def tail(path, limit=3000):
    try:
        with open(path, "rb") as handle:
            return handle.read()[-limit:].decode(errors="replace").strip() or "<empty>"
    except OSError as error:
        return "<no log: %s>" % error


def bound(address, port, timeout=0.2):
    try:
        with socket.create_connection((address, port), timeout):
            return True
    except OSError:
        return False


def wait_bound(address, port, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if bound(address, port):
            return True
        time.sleep(0.05)
    return False


def any_value(value):
    if "stringValue" in value:
        return value["stringValue"]
    if "intValue" in value:
        return int(value["intValue"])
    if "boolValue" in value:
        return value["boolValue"]
    if "doubleValue" in value:
        return value["doubleValue"]
    return value


def attributes_map(attributes):
    return {item["key"]: any_value(item.get("value", {})) for item in attributes or []}


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
                resource = attributes_map(resource_spans.get("resource", {}).get("attributes"))
                for scope_spans in resource_spans.get("scopeSpans", []):
                    for span in scope_spans.get("spans", []):
                        self.server.records.append(
                            {
                                "traceId": span.get("traceId"),
                                "spanId": span.get("spanId"),
                                "parentSpanId": span.get("parentSpanId"),
                                "name": span.get("name"),
                                "startTimeUnixNano": span.get("startTimeUnixNano"),
                                "endTimeUnixNano": span.get("endTimeUnixNano"),
                                "status": span.get("status"),
                                "attributes": attributes_map(span.get("attributes")),
                                "events": span.get("events", []),
                                "resource": resource,
                            }
                        )
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *_args):
        pass


class Backend(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port):
        super().__init__(("127.0.0.1", port), _Handler)
        self.records = []
        self.record_lock = threading.Lock()
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)

    def start(self):
        self.thread.start()

    def stop(self):
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=5)

    def records_for(self, trace_id):
        with self.record_lock:
            return [record for record in self.records if record["traceId"] == trace_id]

    def await_trace(self, trace_id, span_count, timeout=30):
        deadline = time.time() + timeout
        while time.time() < deadline:
            records = self.records_for(trace_id)
            if len({record["spanId"] for record in records}) >= span_count:
                return records
            time.sleep(0.1)
        fail("backend %d received %d/%d spans of trace %s; records=%r" % (
            self.server_port,
            len({record["spanId"] for record in self.records_for(trace_id)}),
            span_count,
            trace_id,
            self.records_for(trace_id),
        ))


def absent(backend, trace_id, seconds, message):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if backend.records_for(trace_id):
            fail(message)
        time.sleep(0.1)
    log("trace %s absent on backend %d" % (trace_id, backend.server_port))


def otlp_attr(key, value):
    if isinstance(value, bool):
        encoded = {"boolValue": value}
    elif isinstance(value, int):
        encoded = {"intValue": str(value)}
    else:
        encoded = {"stringValue": value}
    return {"key": key, "value": encoded}


def make_span(trace_id, span_id, parent, name, start, end, attrs=None, events=None, status=None):
    return {
        "traceId": trace_id,
        "spanId": span_id,
        "parentSpanId": parent,
        "name": name,
        "kind": 1,
        "startTimeUnixNano": str(start),
        "endTimeUnixNano": str(end),
        "attributes": [otlp_attr(key, value) for key, value in (attrs or {}).items()],
        "events": events or [],
        "status": status or {"code": 1},
    }


def make_event(name, attrs):
    return {
        "name": name,
        "timeUnixNano": "1700000000000000100",
        "attributes": [otlp_attr(key, value) for key, value in attrs.items()],
    }


def message_arrays(prefix):
    input_messages = json.dumps([
        {"role": "system", "content": prefix + "-SYSTEM-SENTINEL"},
        {"role": "user", "content": prefix + "-INPUT-SENTINEL"},
    ])
    output_messages = json.dumps([{"role": "assistant", "content": prefix + "-OUTPUT-SENTINEL"}])
    return input_messages, output_messages


# The precedence fixture: a span that already carries the current message
# carriers, and one that carries a producer-set legacy carrier. Both also carry
# an inference event, so the bridge has something to copy in either case.
CANONICAL_INPUT = json.dumps([{"role": "user", "content": "CANONICAL-INPUT-SENTINEL"}])
CANONICAL_OUTPUT = json.dumps([{"role": "assistant", "content": "CANONICAL-OUTPUT-SENTINEL"}])
PRODUCER_PROMPT = json.dumps([{"role": "user", "content": "PRODUCER-PROMPT-SENTINEL"}])
CANONICAL_SPAN = "bb00000000000001"
PRODUCER_SPAN = "bb00000000000002"


def precedence_payload(trace_id):
    input_messages, output_messages = message_arrays("MIXED")
    event = make_event("gen_ai.client.inference.operation.details", {
        "gen_ai.input.messages": input_messages,
        "gen_ai.output.messages": output_messages,
        "gen_ai.system_instructions": "MIXED-SYSTEM-SENTINEL",
    })
    spans = [
        make_span(trace_id, CANONICAL_SPAN, "", "hindsight.reflect", 1700000000000000000, 1700000000000000900,
                  {"gen_ai.input.messages": CANONICAL_INPUT, "gen_ai.output.messages": CANONICAL_OUTPUT,
                   "gen_ai.usage.input_tokens": 5},
                  [event]),
        make_span(trace_id, PRODUCER_SPAN, "", "hindsight.reflect", 1700000000000000300, 1700000000000000400,
                  {"gen_ai.prompt": PRODUCER_PROMPT}, [event]),
    ]
    return {"resourceSpans": [{
        "resource": {"attributes": [otlp_attr("service.name", "hindsight-probe")]},
        "scopeSpans": [{"scope": {"name": "hindsight.synthetic", "version": "0.10.0"}, "spans": spans}],
    }]}


def mixed_payload(trace_id, prefix):
    input_messages, output_messages = message_arrays(prefix)
    spans = [
        make_span(trace_id, "0000000000000001", "", "hindsight.reflect", 1700000000000000000, 1700000000000000900,
                  {"hindsight.operation": "reflect", "http.request.method": "POST", "http.response.status_code": 200}),
        make_span(trace_id, "0000000000000002", "0000000000000001", "hindsight.reflect", 1700000000000000100, 1700000000000000800,
                  {"hindsight.scope": "reflect", "gen_ai.provider.name": "openai", "gen_ai.request.model": "synthetic-model", "gen_ai.usage.input_tokens": 17, "gen_ai.usage.output_tokens": 11, "hindsight.private_marker": prefix + "-USEFUL-SENTINEL"},
                  [
                      make_event("gen_ai.client.inference.operation.details", {
                          "gen_ai.input.messages": input_messages,
                          "gen_ai.output.messages": output_messages,
                          "gen_ai.system_instructions": prefix + "-SYSTEM-SENTINEL",
                          "gen_ai.response.finish_reasons": '["stop"]',
                      }),
                      make_event("gen_ai.tool_call.0", {"tool.name": "recall", "tool.arguments": '{"query":"' + prefix + '-TOOL-ARG-SENTINEL"}'}),
                      make_event("exception", {"exception.type": "ValueError", "exception.message": prefix + "-EXCEPTION-SENTINEL", "exception.stacktrace": "stack " + prefix + "-EXCEPTION-SENTINEL"}),
                  ],
                  {"code": 2, "message": prefix + "-STATUS-SENTINEL"}),
        make_span(trace_id, "0000000000000003", "0000000000000002", "hindsight.reflect_tool_exec.done", 1700000000000000200, 1700000000000000700,
                  {"hindsight.tool.name": "done", "hindsight.tool.arguments": '{"answer":"' + prefix + '-TOOL-ARG-SENTINEL"}', "hindsight.tool.duration_ms": 19}),
    ]
    return {"resourceSpans": [{
        "resource": {"attributes": [otlp_attr("service.name", "hindsight-probe"), otlp_attr("deployment.environment.name", "synthetic")]},
        "scopeSpans": [{"scope": {"name": "hindsight.synthetic", "version": "0.10.0"}, "spans": spans}],
    }]}


def simple_payload(trace_id, span_id, name, resource="probe-general"):
    return {"resourceSpans": [{
        "resource": {"attributes": [otlp_attr("service.name", resource)]},
        "scopeSpans": [{"scope": {"name": "telemetry-output-view-check"}, "spans": [
            make_span(trace_id, span_id, "", name, 1700000000000000000, 1700000000000000100,
                      {"http.route": "/ordinary-only", "app.marker": "ordinary"})
        ]}],
    }]}


def post(address, port, payload):
    request = urllib.request.Request(
        "http://%s:%d/v1/traces" % (address, port),
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


def send(address, port, payload, label):
    status = post(address, port, payload)
    if status != 200:
        fail("%s was not accepted (HTTP %s)" % (label, status))


def assert_structure(records, trace_id, expect_content):
    by_id = {record["spanId"]: record for record in records if record["traceId"] == trace_id}
    expected = {"0000000000000001", "0000000000000002", "0000000000000003"}
    if set(by_id) != expected:
        fail("trace %s did not preserve its full span set: %r" % (trace_id, sorted(by_id)))
    root, llm, tool = (by_id[name] for name in sorted(expected))
    if llm["parentSpanId"] != "0000000000000001" or tool["parentSpanId"] != "0000000000000002":
        fail("trace %s changed parent IDs" % trace_id)
    if (llm["startTimeUnixNano"], llm["endTimeUnixNano"]) != ("1700000000000000100", "1700000000000000800"):
        fail("trace %s changed timing" % trace_id)
    if llm["status"] != {"code": 2, "message": "MIXED-STATUS-SENTINEL"}:
        fail("trace %s changed status: %r" % (trace_id, llm["status"]))
    if llm["resource"] != root["resource"] or llm["resource"].get("service.name") != "hindsight-probe":
        fail("trace %s changed resource identity" % trace_id)
    attrs = llm["attributes"]
    if attrs.get("gen_ai.provider.name") != "openai" or attrs.get("gen_ai.usage.input_tokens") != 17:
        fail("trace %s lost useful GenAI metadata" % trace_id)
    if tool["attributes"].get("hindsight.tool.name") != "done":
        fail("trace %s lost useful tool metadata" % trace_id)
    wire = json.dumps(records, sort_keys=True)
    markers = ["INPUT-SENTINEL", "OUTPUT-SENTINEL", "SYSTEM-SENTINEL", "TOOL-ARG-SENTINEL", "EXCEPTION-SENTINEL"]
    if expect_content:
        for marker in markers:
            if marker not in wire:
                fail("rich trace %s is missing %s" % (trace_id, marker))
    else:
        for marker in markers:
            if marker in wire:
                fail("lean trace %s retained forbidden marker %s" % (trace_id, marker))
        if attrs.get("gen_ai.usage.input_tokens") != 17 or llm["status"].get("code") != 2:
            fail("lean trace %s lost useful operational metadata" % trace_id)


def main():
    ports = [GENERAL_BACKEND_PORT, STORE_BACKEND_PORT, LANGFUSE_BACKEND_PORT, LATITUDE_BACKEND_PORT]
    if any(bound("127.0.0.1", port) for port in ports):
        fail("a mock backend port is already in use")

    general = Backend(GENERAL_BACKEND_PORT)
    store = Backend(STORE_BACKEND_PORT)
    langfuse = Backend(LANGFUSE_BACKEND_PORT)
    latitude = Backend(LATITUDE_BACKEND_PORT)
    backends = [general, store, langfuse, latitude]
    for backend in [general, store, langfuse]:
        backend.start()

    log_file = open("collector.log", "ab")
    collector = subprocess.Popen([OTELCOL, "--config=file:" + CONFIG], stdout=log_file, stderr=log_file, start_new_session=True)
    try:
        if not wait_bound("127.0.0.1", GENERAL_PORT):
            fail("general receiver failed to bind; collector log:\n" + tail("collector.log"))
        if not wait_bound(ROUTE_ADDR, ROUTE_PORT):
            fail("selected receiver failed to bind; collector log:\n" + tail("collector.log"))
        if bound("127.0.0.1", ROUTE_PORT) or bound(ROUTE_ADDR, GENERAL_PORT):
            fail("general and route listeners are not isolated sockets")

        # Rich Latitude unavailable: queue that destination only while the lean
        # store and the other rich destination continue independently.
        trace = "a1000000000000000000000000000001"
        log("phase 1: Latitude outage leaves lean and Langfuse exports live")
        send(ROUTE_ADDR, ROUTE_PORT, mixed_payload(trace, "MIXED"), "mixed trace while Latitude is down")
        lean = store.await_trace(trace, 3)
        rich_lang = langfuse.await_trace(trace, 3)
        assert_structure(lean, trace, expect_content=False)
        assert_structure(rich_lang, trace, expect_content=True)
        absent(general, trace, 2, "general backend received selected-route traffic")

        latitude.start()
        if not wait_bound("127.0.0.1", LATITUDE_BACKEND_PORT, 10):
            fail("Latitude mock backend did not recover")
        rich_lat = latitude.await_trace(trace, 3, 45)
        assert_structure(rich_lat, trace, expect_content=True)
        absent(general, trace, 2, "general backend received selected-route traffic after recovery")

        # Actual parser probe input: the harness writes the final span-attribute
        # map; the independent worker imports Latitude's real pinned parser.
        llm = next(record for record in rich_lat if record["spanId"] == "0000000000000002")
        attrs = llm["attributes"]
        if attrs.get("gen_ai.prompt") is None or attrs.get("gen_ai.completion") is None:
            fail("Latitude view did not set parser-supported legacy message attributes")
        if attrs.get("gen_ai.input.messages") is not None or attrs.get("gen_ai.output.messages") is not None:
            fail("Latitude view created canonical keys that could shadow the legacy carrier")
        if attrs.get("gen_ai.system_instructions") != "MIXED-SYSTEM-SENTINEL":
            fail("Latitude view lost system instructions")
        # The artifact handed to the Latitude parser probe has to carry the
        # event's arrays verbatim: a parser run over an empty or unrelated
        # carrier would look like a success but prove nothing.
        expected_input, expected_output = message_arrays("MIXED")
        if attrs.get("gen_ai.prompt") != expected_input:
            fail("Latitude view did not carry the inference event's input messages verbatim: %r" % attrs.get("gen_ai.prompt"))
        if attrs.get("gen_ai.completion") != expected_output:
            fail("Latitude view did not carry the inference event's output messages verbatim: %r" % attrs.get("gen_ai.completion"))
        with open(LATITUDE_ATTRS_OUT, "w", encoding="utf-8") as output:
            json.dump([{"spanId": llm["spanId"], "attributes": attrs}], output, ensure_ascii=False, indent=2)
        log("Latitude attribute artifact written to %s" % LATITUDE_ATTRS_OUT)

        # Shared-input mutation must remain branch-local: Langfuse keeps its
        # original event and does not gain Latitude-specific legacy carriers.
        lang_llm = next(record for record in rich_lang if record["spanId"] == "0000000000000002")
        if "gen_ai.prompt" in lang_llm["attributes"] or "gen_ai.completion" in lang_llm["attributes"]:
            fail("Latitude adapter mutated Langfuse attributes")
        if not any(event.get("name") == "gen_ai.client.inference.operation.details" for event in lang_llm["events"]):
            fail("Latitude adapter removed the rich inference event")

        log("phase 2: ordinary-only selected-route trace")
        ordinary = "a2000000000000000000000000000002"
        send(ROUTE_ADDR, ROUTE_PORT, simple_payload(ordinary, "0000000000000011", "ordinary-only"), "ordinary-only selected trace")
        for backend in [store, langfuse, latitude]:
            records = backend.await_trace(ordinary, 1)
            if len(records) != 1:
                fail("ordinary-only trace duplicated at backend %d" % backend.server_port)
        absent(general, ordinary, 2, "ordinary-only selected trace reached general backend")

        log("phase 3: late continuation in a later export request")
        late = "a3000000000000000000000000000003"
        first = mixed_payload(late, "LATE")
        first["resourceSpans"][0]["scopeSpans"][0]["spans"] = first["resourceSpans"][0]["scopeSpans"][0]["spans"][:1]
        send(ROUTE_ADDR, ROUTE_PORT, first, "trace root")
        continuation = mixed_payload(late, "LATE")
        continuation["resourceSpans"][0]["scopeSpans"][0]["spans"] = continuation["resourceSpans"][0]["scopeSpans"][0]["spans"][1:2]
        send(ROUTE_ADDR, ROUTE_PORT, continuation, "late continuation")
        for backend in [store, langfuse, latitude]:
            records = backend.await_trace(late, 2)
            if {record["spanId"] for record in records} != {"0000000000000001", "0000000000000002"}:
                fail("late continuation changed the received span set at backend %d" % backend.server_port)
            child = next(record for record in records if record["spanId"] == "0000000000000002")
            if child["parentSpanId"] != "0000000000000001":
                fail("late continuation changed its parent ID at backend %d" % backend.server_port)
        absent(general, late, 2, "late selected-route continuation reached general backend")

        log("phase 4: adjacent general-route traffic stays general")
        general_trace = "a4000000000000000000000000000004"
        send("127.0.0.1", GENERAL_PORT, simple_payload(general_trace, "0000000000000044", "general-adjacent"), "general adjacent trace")
        general.await_trace(general_trace, 1)
        for backend in [store, langfuse, latitude]:
            absent(backend, general_trace, 3, "general-route traffic crossed into backend %d" % backend.server_port)

        log("phase 5: existing canonical and producer-set legacy carriers take precedence")
        precedence = "a5000000000000000000000000000005"
        send(ROUTE_ADDR, ROUTE_PORT, precedence_payload(precedence), "mixed-precedence trace")
        expected_input, expected_output = message_arrays("MIXED")
        latitude_spans = {record["spanId"]: record["attributes"] for record in latitude.await_trace(precedence, 2)}
        canonical = latitude_spans[CANONICAL_SPAN]
        if canonical.get("gen_ai.input.messages") != CANONICAL_INPUT or canonical.get("gen_ai.output.messages") != CANONICAL_OUTPUT:
            fail("Latitude view rewrote the span's canonical message carriers: %r" % canonical)
        if "gen_ai.prompt" in canonical or "gen_ai.completion" in canonical:
            fail("Latitude view added a legacy carrier beside the span's canonical messages: %r" % canonical)
        if canonical.get("gen_ai.system_instructions") != "MIXED-SYSTEM-SENTINEL":
            fail("Latitude view did not bridge system instructions for the canonical span: %r" % canonical)
        producer = latitude_spans[PRODUCER_SPAN]
        if producer.get("gen_ai.prompt") != PRODUCER_PROMPT:
            fail("Latitude view overwrote a producer-set gen_ai.prompt: %r" % producer.get("gen_ai.prompt"))
        if producer.get("gen_ai.completion") != expected_output:
            fail("Latitude view did not bridge completion where the canonical counterpart is absent: %r" % producer.get("gen_ai.completion"))
        shared = next(
            record["attributes"] for record in langfuse.await_trace(precedence, 2) if record["spanId"] == CANONICAL_SPAN
        )
        if (
            shared.get("gen_ai.input.messages") != CANONICAL_INPUT
            or "gen_ai.prompt" in shared
            or "gen_ai.system_instructions" in shared
        ):
            fail("the Latitude bridge reached the Langfuse view of the same span: %r" % shared)
        log("OK")
    finally:
        try:
            os.killpg(os.getpgid(collector.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            collector.kill()
        collector.wait(timeout=30)
        log_file.close()
        for backend in backends:
            try:
                backend.stop()
            except Exception:
                pass


if __name__ == "__main__":
    main()
