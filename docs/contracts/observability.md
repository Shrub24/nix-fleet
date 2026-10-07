# Fleet observability policy

This is the fleet baseline for managed NixOS hosts, including workstations.
[Telemetry](telemetry.md) defines the mechanisms; this document defines which
lanes consumers compose and why. Selecting a mechanism is not evidence that a
host has adopted or deployed the baseline.

## Ownership

- **nix-fleet:** shared aspects, canonical service coordinates, host identity,
  delivery contracts and this baseline.
- **Consumer repositories:** host composition, listener bindings, tailnet grants,
  journal unit selection, credentials, backend retention, alert rules and
  deployment.
- **Applications:** instrumentation and application identity. An installed
  collector does not make an uninstrumented application emit traces.

Consumers resolve canonical endpoints through `lib.serviceEndpoints` in their
own flake-level modules. NixOS modules receive the resolved values; they do not
read flake-level `config.fleet`. Do not copy hostnames or ports into application
configuration. See [the service catalog](services.md).

## Canonical coordinates

The [service catalog](services.md) publishes the write routes every lane uses;
consumers resolve them with `lib.serviceEndpoints.url` and append nothing:

| Lane                     | Service / endpoint                 | Route                              |
| ------------------------ | ---------------------------------- | ---------------------------------- |
| Traces (agent → gateway) | `otel-collector` / `otlp`          | home-forge `:4318`, OTLP/HTTP      |
| Metrics remote write     | `victoriametrics` / `remote-write` | home-forge `:8428/api/v1/write`    |
| Journal JSON-line ingest | `victorialogs` / `jsonline`        | home-forge `:9428/insert/jsonline` |

The gateway's own trace backends are gateway-local policy and are not catalog
entries. These routes carry no credential: reachability is tailnet grants.
A catalog record declares a coordinate, not a deployed listener.

## The baseline lanes

| Lane                     | Host mechanism                                         | Destination                           | Purpose                                                |
| ------------------------ | ------------------------------------------------------ | ------------------------------------- | ------------------------------------------------------ |
| Host/container dashboard | `beszel-agent`                                         | Consumer-owned Beszel hub             | Lightweight operational view                           |
| Host metrics             | `node-exporter` + telemetry's vmagent provider         | Canonical metrics store               | Prometheus series, history and rule-based alerts       |
| Operational journal      | Telemetry's Vector provider                            | Canonical journal ingest              | Searchable evidence from explicitly selected units     |
| Application traces       | Local OTel agent, when an instrumented producer exists | OTel gateway, then trace backends     | Application/request diagnostics                        |
| Unit events              | `notify`                                               | Consumer-bound notification transport | Immediate registered systemd failure/completion events |
| Metric alerts            | Central vmalert → Alertmanager → notify                | Consumer-bound notification transport | Thresholds and conditions that do not stop a unit      |

Beszel and node-exporter overlap in some host statistics but are not substitutes.
Beszel supplies its own dashboard; node-exporter supplies the Prometheus lane
used by queries and alert rules. The baseline includes both. Avoid the actual
double-scrape: a node-exporter scraped locally through vmagent must not also be
scraped remotely by a central host-list job.

Central stores, the Beszel hub, vmalert and Alertmanager run only on their
consumer-selected infrastructure hosts. Their presence in this policy does not
mean every machine runs a database or an alert evaluator.

## Agent → gateway for traces

```text
instrumented application
  → host-local OTel agent (loopback, persistent exporter queue)
  → home-forge OTel gateway (tailnet ingress, persistent queues)
  → independently selected trace backends
```

Agent and gateway are compositions of the same `modules.nixos.telemetry` aspect
and Collector package. There is no separate role enum or second collector
catalog. A metrics/logs-only host needs no OTel process.

### Agent responsibilities

1. Admit only the signals its producers use, normally
   `services.telemetry.otlp.signals = [ "traces" ]`.
2. Select one gateway destination using protocol `otlp-http`, accepting traces.
   Remove old direct trace-backend legs when adopting the gateway; retaining
   both exports the same trace twice.
3. Stamp canonical host identity through
   `services.otel-collector.resourceAttributes`. Preserve application-supplied
   `service.name`; do not replace every application's name with the host name.
4. Hand producers `services.telemetry.otlp.httpUrl`, the stable loopback URL.
   Embedded Home Manager can obtain it through `osConfig`; standalone Home
   Manager and containers need explicit consumer wiring for their own network
   context. Do not hand an ordinary host-local producer the gateway URL.
5. Preserve queue state and monitor delivery health.

### Gateway responsibilities

The canonical gateway placement is **home-forge**. It retains its loopback
producer listener and binds a separate, explicit tailnet address through
`services.telemetry.otlp.ingress`. No wildcard listener or automatic firewall
opening is part of the mechanism.

The gateway admits the signals it actually serves and selects the downstream
trace destinations. It holds their credentials; relay hosts do not. Forwarded
resources retain their origin identity: the gateway's local resource enrichment
does not run on ingress pipelines. Each backend has its own persistent queue,
so one unavailable backend does not intentionally stop the other trace legs.
Fan-out is not transactional and retries can duplicate data.

Tailscale supplies device-level authorization, not application authentication.
Consumer grants must restrict which devices can reach each ingest port. Neither
loopback nor tailnet admission proves which process produced a trace. Backend
credentials and any stronger producer authentication remain consumer policy.

Metrics and journals do **not** detour through this trace gateway. vmagent writes
metrics directly to the metrics store; Vector writes journals directly to the
journal store. This keeps their distinct buffering and ingestion protocols and
avoids making all observability depend on the trace gateway.

## Journal shipping: required policy, explicit mechanism

**Every managed NixOS host ships an explicit operational-unit allowlist.** This
includes workstations. The consumer enables `services.telemetry.journald` and
selects the units relevant to that host; it does not export the whole journal by
accident.

Start with SSH, networking/tailnet, Nix/build services, the monitoring agents and
notification service, plus the infrastructure/application units the host owns.
Use actual systemd unit names, and review additions alongside the service that
produces the logs. User-session and unrelated desktop logs are not implicitly
included.

```nix
services.telemetry.journald = {
  enable = true;
  # Example only: the consumer selects the operational units this host runs.
  includeUnits = [ "sshd.service" "tailscaled.service" "nix-daemon.service" ];
  sink.endpoint = journalIngestUrl; # resolved from the canonical catalog
  buffer.whenFull = "block";
};
```

The mechanism still defaults shipping to disabled: selecting telemetry for
metrics or traces must not silently export logs. That safety default is not an
exemption from the fleet baseline. Consumers implement the policy through their
host compositions. `includeUnits = []` means **all units**, not none, and does
not meet the selected-unit baseline. Existing full-journal consumers need an
explicit allowlist when adopting this policy.

The rationale is scope and sensitivity, not lack of interest in logs. Journals
can contain request data, credentials and user activity. A unit allowlist reduces
collection scope; it is not redaction. Data that must never leave the host or
reach a persistent queue must be removed at the producer or before enqueueing.
Store access, retention, deletion and backups require consumer policy too.

Use a bounded disk buffer with `whenFull = "block"`. When full, Vector stops
reading while journald retains records locally; a long enough outage can still
lose records when the local journal rotates. A restart resumes from persisted
checkpoints. This is bounded recovery, not lossless-forever delivery.

## Notification and alert policy

Select `modules.nixos.notify` on baseline hosts and bind an explicit transport,
topic mapping/default and required secret files. Notification topics describe
use cases, not severities. Severities are `info`, `warning`, `critical`;
`success` and `failure` are events, not severity labels.

An aspect that owns a service registers that service's events. The consumer
registers otherwise-unowned host units. Fleet attaches native systemd
`OnFailure`/`OnSuccess` hooks without replacing existing hooks. Failure reporting
is the baseline; successful completion notifications are opt-in for jobs where
completion is useful, not a success message for every running daemon.

This detects unit transitions, not every unhealthy condition. Metric alert rules
run centrally in vmalert and route through Alertmanager to the notify daemon's
`POST /alertmanager` endpoint. Rules, thresholds, recipients, grouping and
silences stay consumer-owned. Grafana visualizes; it is not a competing fleet
alert evaluator. Beszel dashboard status does not replace either alert path.

## State, health and security

On impermanent hosts, persist the relevant service state directories:

- `/var/lib/opentelemetry-collector`: agent **and** gateway delivery queues;
- `/var/lib/vmagent`: pending remote-write metrics;
- `/var/lib/vector`: journal checkpoints and pending log batches.

These directories may hold the only copy of undelivered data. With systemd
`DynamicUser`, check whether the actual backing directory is under
`/var/lib/private` before configuring persistence; do not persist only a symlink
or replace service-managed ownership with a guessed static UID. Keep service-owned
permissions and plan disk headroom. Exporter IDs are persistent state identities;
do not rename them or delete queue files as a cosmetic rollout change. See the
[delivery guarantees and limits](telemetry.md#otlp-delivery-persistent-bounded-observable).

Collect the active Collector's loopback delivery metrics (default port 9464)
through the ordinary scrape contract, and inspect queue occupancy, enqueue/send
failures and disk pressure. Monitor the other agents' delivery/backlog signals
as well. A service being active is not proof that its destination accepts data.

## Adoption acceptance

Treat configured, deployed and delivering as separate milestones. For each host:

1. Evaluate the selected aspects, resolved destinations, journal allowlist,
   notification hooks and persistent-state mounts.
2. Confirm local node metrics arrive with a distinct `hostName:port` instance;
   remove obsolete central remote-scrape jobs.
3. Emit a unique journal marker from an allowed unit and observe it in the log
   store; verify an excluded unit is not shipped.
4. For a trace-producing host, send a uniquely identified trace through its
   local endpoint and observe origin identity at **each** gateway backend.
   GET/405, a TCP connection or an empty OTLP request is not this test.
5. Verify an allowed and a denied tailnet device against network ingress.
6. Exercise a controlled registered-unit failure and an alert-rule firing;
   observe delivery to the intended notification topic.
7. Exercise destination unavailability and agent restart, verifying queue
   recovery, independent trace fan-out and bounded backlog behavior.

Fleet's synthetic runtime checks establish mechanism behavior. They do not prove
production grants, backend credentials, retention policy or consumer deployment.
A missing producer, unresolved sink or unperformed live test is an adoption gap,
not permission to claim a healthy observability lane.
