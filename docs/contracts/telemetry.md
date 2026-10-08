# Telemetry (host-local)

[Fleet observability policy](observability.md) defines the required host lanes,
the agent → gateway topology and their rationale. This document specifies the
host-local mechanism; its safe opt-in defaults are not the fleet adoption policy.

Scope: one NixOS host's telemetry. `flake.modules.nixos.telemetry` is the
**contract** — the implementation-agnostic `services.telemetry` vocabulary: a
service registers a Prometheus scrape source, admits OTLP signals on the local
endpoint, opts into journald shipping, or binds a remote destination without
knowing which realization serves it. The contract declares types and validates
values; it starts no unit, listener or provider.

Capabilities are **selected by composing lanes**. A lane aspect composes the
contract and the fleet's default realization for one signal, so a host reads as
the signals it ships:

```nix
# the host's aspect list: the signals this host ships
imports = [
  inputs.nix-fleet.modules.nixos.telemetry-metrics
  inputs.nix-fleet.modules.nixos.telemetry-logs
  inputs.nix-fleet.modules.nixos.telemetry-otlp
  inputs.nix-fleet.modules.nixos.node-exporter
];
```

Composing a lane is enablement — there is no top-level enable flag.

Two migration consequences follow from that split. Importing the bare
`telemetry` aspect selects no realization, so it contributes the vocabulary and
its validation while leaving every provider disabled — select the lanes the host
ships instead. And a realization owns the health registration that belongs to its
own listener: `vmagent-health` (`:8429`) is registered by `telemetry-vmagent`,
`vector-health` (`:9598`) by `telemetry-vector` while journald shipping is
active, and `otel-collector-health` by whichever collector realization is
composed. A host that registered one of those jobs itself under the older
single-aspect composition must drop its own definition when it selects the lane:
the registration is a plain value owned by the provider, so two definitions of
one job name conflict by design rather than merging. Overriding the provider's
job is possible with `lib.mkForce`, and it deliberately repoints a health scrape
away from the listener the provider bound.

A host can also act as an explicit relay or gateway: it forwards only to the
destinations its pipelines select, and it can bind a separate, explicitly
addressed network ingress next to its loopback producer listener. Discovery,
implicit forwarding and a `agent`/`gateway` role switch are out of scope.

## Contract, lanes and realizations

The contract, the signal lanes and the realizations are separate public aspects.
A signal lane selects a signal and composes its default realization; a
realization carries exactly one signal. No realization imports a lane, and a
host never names an implementation to get a default.

| Surface               | Aspect                            | Composes                                   | Ships                                     |
| --------------------- | --------------------------------- | ------------------------------------------ | ----------------------------------------- |
| Contract (vocabulary) | `telemetry`                       | `services.telemetry`, value validation     | nothing — no unit, listener or provider   |
| Metrics lane          | `telemetry-metrics`               | contract + `telemetry-vmagent`             | Prometheus scrape → metrics destinations  |
| Logs lane             | `telemetry-logs`                  | contract + `telemetry-vector`              | journald records → the JSON-line sink     |
| OTLP lane             | `telemetry-otlp`                  | contract + `telemetry-otel-collector-otlp` | admitted OTLP signals → OTLP destinations |
| Scrape realization    | `telemetry-vmagent`               | contract                                   | Prometheus scrape (metrics-lane default)  |
| Journald realization  | `telemetry-vector`                | contract                                   | journald records (logs-lane default)      |
| OTLP realization      | `telemetry-otel-collector-otlp`   | contract                                   | admitted OTLP signals (OTLP-lane default) |
| Scrape realization    | `telemetry-otel-collector-scrape` | contract                                   | Prometheus scrape through the Collector   |

A lane is the whole opt-in for its signal. One valid composition per lane:

**Metrics** — node-exporter registers the scrape source, the lane carries it:

```nix
imports = [
  inputs.nix-fleet.modules.nixos.telemetry-metrics
  inputs.nix-fleet.modules.nixos.node-exporter
];
```

**Logs** — the lane composes the shipper; the consumer enables it and binds a
sink:

```nix
imports = [ inputs.nix-fleet.modules.nixos.telemetry-logs ];
services.telemetry.journald = {
  enable = true;
  includeUnits = [ "sshd.service" ];
  sink.endpoint = journalIngestUrl;
};
```

**OTLP** — the lane binds the loopback endpoint local producers push to:

```nix
imports = [ inputs.nix-fleet.modules.nixos.telemetry-otlp ];
services.telemetry.otlp.signals = [ "traces" ];
```

`telemetry-otel-collector-scrape` and `telemetry-otel-collector-otlp` configure
**one** host collector service: a host that composes both gets a single
collector with both pipelines, and a host that composes one gets only that
pipeline. A host whose scraped metrics go to an OTLP destination instead of a
Prometheus remote-write store composes the OTel scrape realization **instead
of** the metrics lane, which replaces that lane's default bundle rather than
adding a second scraper:

```nix
# alternate scrape realization; do not also compose telemetry-metrics
imports = [ inputs.nix-fleet.modules.nixos.telemetry-otel-collector-scrape ];
```

### One scrape realization

Compose either vmagent or the collector's scrape realization, not both. Two
scrape realizations fail with a named telemetry conflict rather than collecting
every source twice. To replace the metrics lane's default, import the alternate
realization instead of that lane.

Scraping and admitting OTLP metrics are different inputs and may coexist. The
collector keeps them in separate `metrics/scrape` and `metrics` pipelines, with
shared exporters and delivery state.

## Capability selection determines what runs

A realization runs because its aspect is composed — never because a
destination, pipeline or registration happens to exist. The contract reads no
configuration to decide whether a capability is present: **a destination is
where data goes, never evidence that an input exists.** Binding a destination,
admitting a signal or registering a scrape source therefore starts nothing on
its own; the lane that carries the signal is the declaration, and `imports` is
where Nix expects a dependency.

The OTel adapter renders only the exporters the **active** signals actually
select, and binds only their credentials.

## Explicit OTLP admission

OTLP input is opt-in per host. `services.telemetry.otlp.signals` is a unique
list of admitted signals, empty by default:

```nix
services.telemetry.otlp.signals = [ "traces" ]; # traces | metrics | logs
```

Every admitted signal must have a nonempty destination pipeline, or evaluation
fails by name (`telemetry: OTLP admits logs with no destination pipeline to
carry them; …`): a receiver never acknowledges what it cannot export. Duplicate
entries fail the same way (`… otlp.signals names traces more than once`).

**A destination is not admission.** A metrics destination alone composes no OTLP
realization and advertises no OTLP receiver; only the OTLP lane binds one.

### Explicit named routes

`services.telemetry.routes.<name>` declares an additional OTLP listener and its
own audience policy. Producers select a route by sending to that route's
listener; the route is never inferred from span names, resource attributes,
destination presence or backend credentials. A route is a routing input, not an
authorization boundary — the consumer owns any admission and firewall policy in
front of it.

```nix
services.telemetry.routes.aiSession = {
  signals = [ "traces" ];
  ingress = {
    host = "<consumer bind address>";
    httpPort = 4320;
    grpcPort = null;
  };
  pipelines.traces = [ "langfuse" ];
};
```

The route's `pipelines.<signal>` names only the destinations for that route;
`null` means no destination (not the general route's derivation), and a signal
that the route admits must name at least one destination. The general
`otlp.signals`, `pipelines.<signal>` and `otlp.ingress` remain the existing
general input and policy. Thus a general producer remains general even when
AI-specific destinations are configured, and an AI stream reaches the general
store only if the AI route's own policy names it.

Every route has a separate receiver and pipeline, and every (route,
destination) pair has its own exporter identity, persistent queue/retry scope
and remote-write WAL path. A shared destination explicitly selected by two
routes therefore receives both streams through separate exporters; a backend
failure cannot redirect one route's backlog to another audience. Listener
addresses/ports must not collide with the loopback producer, general ingress or
another route. Route-specific credentials remain destination-owned, and
selecting a route does not authenticate or authorize its sender.

Routes are additive: declaring one leaves the general input, policy and listener
untouched, so a host gains a route without changing what it already ships.
Removing the declaration removes that route's listener, receiver, pipeline and
exporters in the same edit; producers still sending to it must be repointed at
the general ingress or another route, and a destination that other routes also
name keeps receiving from them. Nothing falls back to a specialized destination
when a route is removed, and a destination named by no route's pipeline receives
nothing at all.

## Producer registrations

Prometheus scrape sources — the self-registration case:

```nix
services.telemetry.scrape.my-app = {
  target = "127.0.0.1"; # host-local address; fleet host IDs are not resolved
  port = 9100;
  # metricsPath = "/metrics"; scheme = "http"; interval = "30s"; labels = { };
};
```

The attribute name is the scrape job name; `labels` become static target
labels. Two independent registrations merge into one scrape configuration and
reach the metrics pipeline.

**A registration is a dormant declaration, not activation.** Like the `notify`
event registrations, a scrape source, admitted signal, destination or journald
sink is fixed-point data: it neither starts a realization nor fails when none is
composed. It is realized only while the lane that carries its signal is
composed, and _a registration is never silently dropped while its lane is
composed_. A host that registers a scrape source and composes no metrics
realization evaluates and ships nothing — that is its composition's statement,
and consumer-side host policy is where "this host should ship these signals" is
checked.

### Shipped producer aspect: node-exporter

`flake.modules.nixos.node-exporter` is a normal aspect a host selects next to
`telemetry-metrics`: it enables nixpkgs' node exporter on `127.0.0.1` (no
firewall rule), registers `services.telemetry.scrape.node` for the same port,
and registers its own unit's failure. It names no backend: the composed metrics
realization carries those metrics to whatever metrics destination the consumer
declares, and composing the producer alone starts no scraper.
`services.node-exporter.port` is the only option — one value, so the
listener and the registration cannot disagree; anything else about the exporter
is reachable through nixpkgs' own `services.prometheus.exporters.node`.
The scrape registration defaults `labels.instance` to `hostName:port`, so local
loopback targets on different hosts do not merge into one series. Consumers may
override `services.telemetry.scrape.node.labels.instance` normally.
**Migration, not coexistence.** A consumer that already scrapes every host's
node exporter over the network from a central store is running a different
design, and the two must not run together: delete those remote jobs (and the
host lists that feed them) when adopting this aspect, or every host is scraped
twice — once locally through its own implementation, once remotely. A store's
self-scrape job is unaffected, because it does not target other hosts.

OTLP push producers obtain a stable local endpoint instead of registering:

```nix
environment.OTEL_EXPORTER_OTLP_ENDPOINT = config.services.telemetry.otlp.httpUrl; # http://127.0.0.1:4318
# grpcUrl is http://127.0.0.1:4317
```

`services.telemetry.otlp.{host,httpPort,grpcPort}` default to loopback
(4318/4317); the OTLP realization derives the URLs, and `otlp.host` is
**loopback-only**. The network-facing listener is the separate
`otlp.ingress` below, so the advertised producer endpoint and the loopback
listener cannot drift apart.

A contributing aspect imports the reusable fragment
`lib/telemetry-contract.nix` to declare into the contract, so a producer is
composable by a host that ships no telemetry lane at all; the fragment carries
the value validation below, not an activation guard.

**The local URL promises a realized input.** A push-only consumer registers
nothing, so an endpoint nothing binds would be a dead address. Reading
`otlp.httpUrl` / `otlp.grpcUrl` fails closed by name unless the host composes
the OTLP realization:

```text
telemetry: services.telemetry.otlp.httpUrl was read without composing an OTLP
realization; no implementation binds the local OTLP endpoint. Compose
telemetry-otlp or telemetry-otel-collector-otlp, or drop the read.
```

The read also requires an **admitted signal**, because the endpoint promises an
input the host actually accepts:

```text
telemetry: local OTLP URL was read without admitting any OTLP signal
```

Admission alone is not enough either: the admitted input must have a destination
pipeline to carry it, or the URL advertises a listener that would acknowledge
what it silently drops.

```text
telemetry: local OTLP URL was read while admitted signals have no destination
pipeline to carry them
```

All three guards are read-time errors: the failure happens where the URL is read,
not when some other value is forced, so a producer that never reads the endpoint
is unaffected by a host that has nothing to serve. A host can compose the logs
lane alone for journald shipping.

## Local relay and gateway ingress

Relay and gateway hosts compose the OTLP lane; the role is entirely a matter of
which destinations the pipelines select. A gateway keeps its loopback producer
listener and optionally binds a second, explicitly addressed OTLP listener for
other hosts:

```nix
services.telemetry.otlp.signals = [ "traces" "metrics" "logs" ];

services.telemetry.otlp.ingress = {
  host = "<consumer tailnet bind address>"; # required, explicit, never wildcard
  # httpPort = 4318; # default; null disables the HTTP transport
  # grpcPort = null; # default; set a port to enable gRPC
};
```

- `ingress` is absent by default: admitting signals creates **no** network
  listener and **no** firewall opening. The mechanism adds no public management
  port and no authentication.
- The ingress carries the host's `otlp.signals` — it is not a second routing or
  signal-selection surface. An ingress with nothing admitted, with no transport,
  with a wildcard/empty address, or colliding with the local listener fails
  closed by name. Collisions are decided on socket identity, not on spelling:
  `localhost` counts as either loopback address and a bracketed IPv6 literal is
  the same bind address as the unbracketed form, so those collisions are named
  here instead of surfacing as a collector bind failure — while a genuinely
  different loopback address (for example `127.0.0.2` next to a `127.0.0.1`
  producer listener) stays legal and is what a host-local ingress uses.
- Admission is enforced by the collector's own routing, not by the adapter:
  a signal with no pipeline has no route, and the OTLP/HTTP listener answers
  such a request with `404 page not found` rather than acknowledging it. The
  offline gateway check asserts that a trace-only host rejects metrics and logs
  on **both** listeners while traces succeed. The gRPC transport is
  render-asserted only: an unadmitted signal is rejected through the collector's
  own routing, but the offline check binds HTTP ingress and does not exercise a
  gRPC ingress listener.
- Local producers keep using `otlp.httpUrl` / `grpcUrl`: configuring network
  ingress does not move the loopback endpoints.
- The consumer owns the actual bind address, cold-boot address availability,
  retry posture and interface-specific Tailscale/firewall policy.

**Relay and gateway are destination compositions.** A relay selects a single
named OTLP destination in `pipelines.traces`; a gateway selects several backend
destinations. There is no role enum and no collector catalog.

```nix
# relay: resolve the gateway in the consumer's flake-level wrapper
endpoint = (inputs.nix-fleet.lib.serviceEndpoints.resolveEndpoint config.fleet {
  service = "otel-collector";
  endpoint = "otlp";
  via = "tailnet";
}).url;
```

**Origin identity is preserved.** `services.otel-collector.resourceAttributes`
is applied to locally received telemetry (the loopback listener and local scrape
pipelines) only. The ingress pipeline shares the selected exporter IDs but never
inherits that enrichment, so a forwarded trace keeps the resource attributes the
relay gave it. This narrows the previous globally-applied behaviour — see
Migration below.

Adding OTLP gateway ingress never enables remote scraping or journald shipping,
and never routes metrics or journal logs through OTLP: those keep their own
destinations.

## Remote destinations and per-signal fanout

The implementation's backends are contract-level, so replacing the
implementation or repointing a backend never reshapes a registration:

```nix
services.telemetry.destinations.latitude = {
  protocol = "otlp-http"; # otlp-grpc | otlp-http | prometheus-remote-write
  endpoint = "https://latitude.invalid"; # repoint an endpoint here, alone
  signals = [ "traces" ]; # an LLM-observability backend: traces only
  headers.Authorization = {
    secret = "latitudeToken";
    prefix = "Bearer ";
  };
};
services.telemetry.secretFiles.latitudeToken = ./secrets/latitude.yaml;
services.telemetry.secretKeys.latitudeToken = "latitude/token";

# pipelines.traces defaults to [ "latitude" ]; logs/metrics omit this destination.
```

`protocol` is a narrow wire-protocol vocabulary, not a collector component
name; it bounds what a destination could ever carry (`otlp-grpc` and
`otlp-http`: traces, metrics, logs; `prometheus-remote-write`: metrics only).
`signals` is required, non-empty, and **authoritative** — it is what the
destination actually accepts, and it must be a subset of what the protocol can
carry. It is never inferred from the protocol: an OTLP endpoint that carries
traces alone (Langfuse, Latitude) must not silently receive metrics and logs
just because OTLP could carry them.

`pipelines.<signal> = null` (the default) fans out only to the destinations
that list that signal; an explicit list overrides it. Every mistake fails
closed by name (`telemetry: …`): an unknown destination, a destination listed
for a signal it does not accept, a destination accepting a signal its protocol
cannot carry (checked for every destination, even one no pipeline names), and
an explicit empty list. Repointing a backend edits `endpoint` and nothing else;
no registration and no implementation name changes. A scrape source whose
metrics have no destination to land in is rejected by the implementation rather
than dropped.

```text
telemetry: destination 'latitude' does not accept logs (accepts traces)
telemetry: destination 'metricsWire' accepts logs, which protocol
prometheus-remote-write cannot carry
```

## Local log shipping: journald

Log shipping is **explicitly enabled in the mechanism** and has its own typed
sink: composing the metrics or OTLP lane must not export a journal as a side
effect, and the logs lane is what carries it. The [fleet policy](observability.md#journal-shipping-required-policy-explicit-mechanism)
requires shipping an operational-unit allowlist on every managed NixOS host,
including workstations. The logs realization sets `journald.enable = true`;
consumers bind its sink and a nonempty `includeUnits`. The empty list is not
silently "everything" but a fail-closed
mistake, and `includeAll` is the deliberate whole-journal decision the rare
exception needs.

```nix
services.telemetry.journald = {
  enable = true;
  includeUnits = [ "nginx.service" ];
  sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
  # streamFields = [ "_HOSTNAME" "_SYSTEMD_UNIT" ];  # low-cardinality grouping
  # buffer.maxSizeMb = 512; buffer.whenFull = "block";
};
```

- `includeUnits` filters on `_SYSTEMD_UNIT`, matched **exactly and
  case-sensitively**. This is not `journalctl -u`: records the kernel or
  PID 1 logs about a service usually carry `init.scope`, not the service's
  own name, so selecting a service's name does not include its lifecycle
  transitions — include them via `init.scope` only with an explicit decision,
  since that scope sees every unit. A template instance needs its own exact
  name (`foo@bar.service`, never `foo@.service`): template base names and
  globs match nothing. Records carrying no included unit are excluded, and
  `excludeUnits` wins outright: a unit in both lists is rejected by the
  reader, so an overlapping pair fails at the unit, not silently in one
  direction.
- The baseline is **the service's own output**, not everything associated
  with the service: no fleet default pulls in kernel or manager-scope records
  to "complete" a unit's story, for exactly the trusted-origin and
  sweep reasons that make `init.scope` dangerous as a blanket selection.
  Broader service-associated diagnostics would need narrow selectors the
  contract does not offer today.
- System units only: there is no per-user-unit selector. A unit named in the
  user manager's transient scope (for example `user@1000.service`)
  still shows `_SYSTEMD_UNIT=user@1000.service`, so selecting that sweeps every
  user service on the host. Individual `_SYSTEMD_USER_UNIT` export is an
  optional extension, deliberately not offered: the present baseline is
  system units, and no shortcut around the user manager is recommended.
- `includeUnits = [ ]` with `includeAll = false` fails closed by name
  (`telemetry: journald shipping is enabled with an empty includeUnits …`):
  an absent allowlist is a missing selection, not a licence to export every
  unit's records. `includeAll = true` is the whole-journal opt-in for the
  deliberate case — it renders no `include_units` filter at all — and it is
  contradictory with a non-empty list (`… includeAll is true …`). A host
  passing this gate by inertia (an empty list it never looked at) is exactly
  what the gate exists to stop; adopting this patch is **breaking for
  empty-list journald consumers**, who must pick a side.

`sink.endpoint` is the backend's HTTP JSON-line ingest URL — consumer policy,
never a fleet default. The realization reads the journal locally, writes one JSON
event per line with gzip, and buffers on disk. `streamFields` selects the
backend's stream grouping and is deliberately low-cardinality by default.

**Why this does not go through the local collector.** Journald shipping is a
separate lane with its own realization and its own binding: a host that ships
logs need not admit OTLP logs or compose an OTel realization at all. Vector's disk buffer
plus its persistent journal read checkpoints cover journal → Vector → backend: a
backend outage or a Vector restart does not drop what is already buffered, and a
restart resumes after the last checkpoint instead of re-reading. It is
**bounded**, not lossless-forever: the buffer has a capacity, `whenFull = "block"`
stops reading the journal when it is full (the journal keeps its own records, so
nothing is lost until journald rotates) while `drop_newest` discards, and once a
record is accepted by the backend its durability is the backend's business.
**Scope is the current boot, stated in the render** (`current_boot_only = true`,
Vector's own default): the reader ships from a saved checkpoint first,
`since_now` when there is none, and otherwise this host's boot — it does not
replay. Concretely: an offline host that reboots with previous-boot records
still sitting unread in its journal does **not** ship them — already-buffered
replay and unread-history replay are different recovery obligations, and the
reader only honours the first. Losing unread history on an offline reboot is
therefore documented behaviour, not a buffer bug; maximum replay is not
offered, because it would also replay logs a consumer's allowlist and
retention policy were never meant to keep. Cover first enable with and without
a checkpoint, same-boot restart, host reboot and a rotated or unavailable
cursor only when such a fixture exists: current-boot scope is corroborated and
invalid-cursor recovery is not.

The scope mistakes fail closed by name alongside the wiring mistakes: shipping
enabled with no `sink.endpoint` (`telemetry: journald shipping is enabled but
services.telemetry.journald.sink.endpoint is not set`), an endpoint that is
not an http(s) URL, an empty allowlist without the deliberate opt-in
(`telemetry: journald shipping is enabled with an empty includeUnits …`), and
an `includeAll = true` paired with a non-empty `includeUnits` (`telemetry:
services.telemetry.journald.includeAll is true …`). An endpoint set while
shipping is disabled is rejected the same way. The realization also rejects a
buffer below Vector's disk-buffer floor rather than letting the service fail at
startup.

## OTLP delivery: persistent, bounded, observable

Exporter IDs are persistent state identities. The adapter retains the legacy
`otlphttp` and `prometheusremotewrite` aliases despite upstream deprecation
warnings. A real Collector 0.155 probe showed that renaming `otlphttp/probe` to
`otlp_http/probe` opens a new queue file and leaves the old backlog undelivered;
a same-ID restart recovers it. An exporter rename needs an explicit drain or
state migration, not just a configuration spelling change.

Active OTel exporters do not accept into a volatile batch and hope. Each
exporter has its own delivery state under the nixpkgs unit's StateDirectory
(`/var/lib/opentelemetry-collector`), so a collector restart resumes the
backlog:

- the file_storage extension (`queue/`) runs with `fsync = true`,
  `create_directory = true`, `directory_permissions = "0700"` and compaction
  enabled on start and on rebound;
- each OTLP (`otlp`, `otlphttp`) exporter gets an exporterhelper queue with
  `sizer = "bytes"`, `queue_size = 268435456` (256 MiB of **serialized
  payload**), `storage = file_storage`, `block_on_overflow = false` and
  queue-integrated `batch` — so a successful acceptance is committed to the
  persistent queue, not to a pre-export `batch` processor (the adapter no longer
  emits one by default);
- `retry_on_failure.max_elapsed_time = 0`: a retryable failure keeps its place
  instead of expiring at the upstream five-minute default. A permanent
  rejection is still permanent.
- The **Prometheus remote-write** exporter rejects `sending_queue` in Collector
  Contrib 0.155.0 (verified: `'prometheusremotewriteexporter.Config' has invalid
keys: sending_queue`), so it persists through its own WAL
  (`queue/wal-<destination>`) and keeps its own finite queue
  (`remote_write_queue.queue_size = 10000`, in queued metrics — this exporter
  cannot express a serialized-byte cap). The offline delivery check uses OTLP
  destinations only, so the WAL branch is covered by configuration validation
  and by the same state-directory coupling, **not** by a runtime recovery test;
  a metrics-durability harness of its own is separate work.

Fan-out is **independent and not transactional**: every destination has its own
exporter ID, queue and WAL, so one unavailable backend fills only its own
backlog while the others keep flowing; a grouped request that partially reached
its destinations can be retransmitted and **duplicate** data.

**Accepted means persisted, not batched.** `sending_queue.batch` is
queue-integrated, and acceptance commits to the persistent queue _before_ any
batch flush: the batch's `flush_timeout` governs how long an already-durable
record waits for company before export, never whether it survives. The offline
delivery check proves the distinction rather than assuming it — it runs a config
with a deliberately long flush interval (15 s) and a byte threshold no single
request reaches, acknowledges traces, kills the collector within milliseconds,
and requires every accepted trace to be delivered after a restart on unchanged
state. It also asserts the production queue path against the unit's own state
directory (`/var/lib/<StateDirectory>/queue`) with `DynamicUser`, so an upstream
state-directory change fails the fixture instead of silently leaving the queue
in a location the unit cannot write.

Bounds, honestly stated:

- `queue_size` bounds buffered serialized payload, **not** physical database
  size. The persistent queue's own floor in this pin is 1 MiB of serialized
  payload (an implicit `min_size`; a smaller `exporterExtra` override is rejected
  by the collector: `min_size must be less than or equal to queue_size`), so
  256 MiB is a capacity choice, not a limit the collector is free to raise and
  not a filesystem quota. Collector Contrib 0.155.0's file_storage exposes no
  database cap (`max_size` is rejected as an invalid key), so the adapter never
  generates it. Plan headroom for bbolt
  overhead and compaction, and monitor disk pressure.
- Unusable delivery storage is a **startup failure**, not a silent fallback:
  the collector validates the configured storage path and exits
  (`extensions::file_storage: problem accessing configured directory …`)
  rather than accepting into a queue that has nowhere durable to land. The
  offline check exercises this against the real binary. A separate live check
  bounds file growth after startup with a child-only `RLIMIT_FSIZE`, without
  filling the builder's disk: persistent enqueue returns HTTP 503 and increments
  its failure counter while the collector remains running. This is controlled
  storage-write exhaustion, not a claim to have filled a production filesystem.
- Queued trace/log content can be **sensitive** (prompts, credentials in
  attributes). Restrict access (0700 state, service-managed user), and treat
  relay _and_ gateway queue storage as sensitive: gateway-only redaction does
  not protect a relay's own queue. Redaction that must never reach disk belongs
  before the queue (producer or local pre-queue processing).
- Retries can duplicate data; delivery is neither exactly-once nor lossless-forever:
  exhausted capacity, permanent rejection with retry disabled, storage failure
  or a deliberately incompatible exporter rename can lose or strand backlog.
  Keep exporter IDs stable across rollouts; drain queues before an incompatible
  rename.

### Delivery health

An active collector exposes its own operational metrics on **loopback 9464**
(`services.otel-collector.metricsPort`), which replaces the implicit all-interface
`:8888` listener that the collector would otherwise create. Exporter queue size
and configured capacity, and enqueue/send failure counters, are visible there,
and the collector publishes that listener as a scrape registration like any
other producer.

A published health registration is a scrape source like any other: it does
**not** start a scraper, a collector or a second realization. A host with no
OTel work has no operational listener and no OTel failure registration at all.
The metrics endpoint is loopback and is never opened by a firewall rule.

Every active realization publishes its own health source the same way, and
collection follows the metrics realization the host composes: with no metrics
realization composed, the sources are published and simply not scraped — a
composition statement, not an orphan failure.

- **vmagent**, while composed, scrapes its own loopback `:8429` management
  endpoint as the `vmagent-health` job.
- **Vector**, while journald shipping is active, exposes its internal metrics
  through an `internal_metrics` source feeding a loopback
  `prometheus_exporter` sink at `127.0.0.1:9598` (Vector's documented port for
  this sink), registered as the `vector-health` job. The exporter carries
  only internal metrics, so it is never a second path for log records, and
  the log sink keeps its `inputs = [ "journald" ]`.

Names verified locally against the pinned binaries: 1.153.0 `vmagent` started
with an unreachable destination exposed all nine `vmagent_*` series at its
loopback endpoint, with the destination masked (`url="1:secret-url"`), and
Vector 0.58.0's `vector validate --no-environment` accepted the rendered
`journald` / `internal_metrics` / `prometheus_exporter` config; the `vector_*`
series follow the component metric names compiled into that binary
(`size_bytes`, `size_events`, `sent_events_total`, `errors_total`,
`discarded_events_total`) under the pinned `default_namespace = "vector"`.
Vector exports a counter series only once it first increments, so these are the
shapes to alert on, not a promise that every one is present on a healthy sink:

| Signal                            | vmagent (`vmagent-health`)                                                                                                       | Vector (`vector-health`, per sink via `component_id`)   |
| --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| Queued / pending work             | `vmagent_remotewrite_pending_data_bytes`, `vmagent_remotewrite_pending_inmemory_blocks`, `vmagent_remotewrite_queue_blocked`     | `vector_buffer_size_bytes`, `vector_buffer_size_events` |
| Send / enqueue errors and retries | `vmagent_remotewrite_errors_total`, `vmagent_remotewrite_retries_count_total`, `vmagent_remotewrite_send_duration_seconds_total` | `vector_component_errors_total`                         |
| Dropped data                      | `vmagent_remotewrite_packets_dropped_total`, `vmagent_remotewrite_samples_dropped_total`                                         | `vector_buffer_discarded_events_total`                  |
| Delivered (presence is the proof) | `vmagent_remotewrite_bytes_sent_total`                                                                                           | `vector_component_sent_events_total`                    |

Self-health rides the same transport it reports on, so it is **not** an
independent witness: an absent `vector_component_sent_events_total` series at
the store — or a flat `vmagent_remotewrite_pending_data_bytes` on a host that
should be shipping — is observed from the center, which is where absence is
actually detectable. Keep availability policy (a laptop is not an always-on
server) and alert thresholds out of these defaults; they stay consumer-owned
central rules (see the [notification and alert
policy](observability.md#notification-and-alert-policy)).

## Implementation tuning: OpenTelemetry Collector

`services.otel-collector` is the OpenTelemetry implementation's own namespace —
the only place that speaks in collector terms:

- `package` (defaults to `pkgs.opentelemetry-collector-contrib`, overridable);
- `resourceAttributes` — upserted into **locally received** signals via a
  `resource` processor (local pipelines only; the ingress pipeline is exempt);
- `processors` — extra processors, ordered memory_limiter → resource → batch →
  others. A custom processor is an escape hatch: an **asynchronous** one placed
  before export weakens the "accepted means queued" guarantee, so prefer the
  queue-integrated defaults;
- `metricsPort` — the loopback delivery-health port (default 9464);
- `exporterExtra.<destination>` — raw exporter override escape hatch, recursively
  merged over the generated exporter (including its queue settings).

The OTel realizations bind the OTLP receiver to `services.telemetry.otlp` when
the OTLP realization is composed, render `services.telemetry.scrape` into
`receivers.prometheus.config.scrape_configs` **only when the scrape realization
is composed** (metrics pipeline only), add the `otlp/ingress` receiver and
`<signal>/ingress` pipelines when `otlp.ingress` is configured, and validate
the config at build time with the real binary. When a scrape source is
registered but no metrics destination can carry it, it fails closed
(`telemetry: N scrape source(s) are registered but the metrics pipeline has no
destination to carry them`).

## Implementation tuning: vmagent (Prometheus scrape)

`telemetry-vmagent` is the metrics lane's default realization and has no
separate public namespace: its whole surface is the contract's
`services.telemetry.scrape` plus the metrics fanout. It renders

- the registered jobs into `services.vmagent.prometheusConfig.scrape_configs`
  (job name = registration name; target, port, `metricsPath`, `scheme`,
  `interval`, and static `labels` all translated), validated at build time by
  nixpkgs' `checkConfig`, which runs the real `vmagent -dryRun` over the
  rendered YAML;
- one `-remoteWrite.url` per destination the metrics pipeline selects, in
  pipeline order.

`-remoteWrite.*` is adapter-owned, not a second option namespace: remote-write
targets come from `services.telemetry.pipelines.metrics`, so ordinary consumers
write no `services.vmagent` configuration at all. The upstream
`services.vmagent` options stay the escape hatch — `extraArgs` merges _after_
the adapter's arguments, so an explicit scalar override (the disk bound, the
queue path) wins, and `package`, `checkConfig`, and `openFirewall` are untouched.
One caveat: vmagent's array flags accumulate, so adding a second
`-httpListenAddr` in `extraArgs` adds a listener rather than replacing the
loopback one.

**Scraped metrics go where the metrics fanout points, or nowhere.** vmagent
speaks Prometheus remote write and nothing else, so every destination the
metrics pipeline selects must be `prometheus-remote-write`. A fanout naming any
other protocol fails closed by name rather than silently narrowing:

```text
telemetry: the metrics pipeline selects 'gateway' (otlp-grpc) for metrics,
which the composed scrape realization vmagent cannot write to — vmagent speaks
prometheus-remote-write only. Repoint those destinations or compose
telemetry-otel-collector-scrape instead of the metrics lane.
```

A scrape source with no metrics destination fails the same way
(`telemetry: N scrape source(s) are registered but the metrics pipeline has no
destination to carry them`). Either way an unsupported fanout can never be
realized as a push to a destination the contract did not select, and a metrics
destination bound without a composed metrics realization starts nothing.

**Bounded durability, not lossless.** The queue lives under the unit's
`StateDirectory` (`/var/lib/vmagent`, `%S` in the argument), so it is persistent
across reboots rather than working-directory state, and each remote-write
destination is bounded at 1 GiB
(`-remoteWrite.maxDiskUsagePerURL=1073741824`). When that bound is reached
vmagent drops the **oldest** buffered data to make room for newly scraped
samples, and it flushes its file-based queue to a destination before newly
ingested samples go there — a long outage past the bound loses data and lags
the remote store. The management/inspection HTTP endpoint binds loopback
(`-httpListenAddr=127.0.0.1:8429`) and `openFirewall` keeps its false default;
the `vmagent-health` scrape registration names that same endpoint, so the bound
port and the scraped target cannot drift apart. That endpoint reports the queue
itself — `vmagent_remotewrite_pending_data_bytes` and
`vmagent_remotewrite_queue_blocked`, with the destination URL masked
(`url="1:secret-url"`) — and it opened **one queue directory per destination**,
named for the destination's position and a hash of its URL (observed in
1.153.0's own startup log and metric labels; the layout is vmagent's, not a
contract). Pointing a destination at a different URL therefore opens a fresh
queue and leaves the old backlog on disk unread, and reordering
`destinations.metrics` does the same because position is part of the name —
same rule as an exporter rename on the OTLP side. Drain before a store move: a
stable Nix attribute name is not proof of a migrated queue. The realization
registers the `vmagent` unit's failure on the notification contract.

**Credentials.** vmagent expands `%{ENV_VAR}` placeholders in its own
command-line flags (its documented substitution syntax — not OTel's
`${env:...}`), so a destination header is rendered as
`<Header>: <prefix>%{VMAGENT_<secret-id>}`: the argument carries only a
reference, and the credential reaches the unit through an `EnvironmentFile`
rendered from SOPS. Nothing enters the Nix store or the process command line.
Bound secrets are registered under `sops.secrets."vmagent/<id>"` and rendered
into `sops.templates."vmagent.env"`; rotating either restarts the unit. Only
destinations that actually carry headers bind a secret, and the empty header
entry vmagent needs as a positional placeholder is emitted for the headerless
ones — headers align with their own URL, not with their position in the
registration.

**A value is data only if it cannot change the parse.** vmagent expands
`%{ENV_VAR}` in its arguments _before_ parsing them, and `-remoteWrite.*` are
comma-separated positional arrays whose elements are `^^`-separated header
lists. A `,` in an expanded value therefore adds an array element and shifts
every later element onto the **next** destination, and `^^` splits one
destination's headers in two — so a credential could be delivered to a
destination that was never bound to it. Neither is left to chance:

- literal values the adapter renders (a destination `endpoint`, a header name,
  a header `prefix`) are rejected at build time with a named error, since they
  are visible during evaluation;
- a **secret's** value exists only once the unit's environment is loaded, so the
  unit runs a guard as `ExecStartPre` and refuses to start when the value contains
  any character vmagent treats as structure (comma, caret, bracket, brace,
  parenthesis, quote, carriage return, newline):

```text
telemetry: VMAGENT_<id> contains a character that vmagent's remote-write
argument parser treats as structure (comma, caret, bracket, brace, parenthesis,
quote or newline); refusing to start rather than risk sending a credential to a
destination that was not given one
```

Refusing to start is deliberate: a credential that cannot be represented safely
is a configuration error, and a stopped exporter is visible while a leaked
credential is not. Bearer and basic-auth credentials — `base64url`, dots,
underscores, `~`, `+`, `/`, `=` — are unaffected. Composing
`telemetry-otel-collector-scrape` instead of the metrics lane avoids the
restriction entirely, because OTel reads header values through its own
`${env:...}` expansion instead of vmagent's argument array. The guard itself is
exercised by `checks.vmagent-secret-guard`.

## Implementation tuning: Vector (journald)

`telemetry-vector` is the logs lane's default realization and has no separate
public namespace: its whole surface is the contract's
`services.telemetry.journald` (source filters, `sink.endpoint`, stream fields,
buffer bounds) plus one realization-owned loopback endpoint — the
`prometheus_exporter` sink at `127.0.0.1:9598`, fed by an `internal_metrics`
source, which it registers as the `vector-health` scrape job whenever journald
shipping is active. That registration starts no scraper and ships nothing to
the log backend: the exporter sink's only input is the internal metrics, and
the log sink keeps `inputs = [ "journald" ]`. The metric names are pinned in
[delivery health](#delivery-health); alert rules on them stay consumer-owned.

The rendered `services.vector.settings` is the nixpkgs module's own — the
realization sets `data_dir = "/var/lib/vector"` (the unit's `StateDirectory`,
where checkpoints and the disk buffer live), `journaldAccess = true`, the
explicit `current_boot_only = true`, and the JSON-line sink fields, and the
module validates the config at build time through its own `vector validate`
step. Secrets never enter the store: this path needs none (a private ingest
route is authenticated by the network it sits on) and no value in the generated
config is env-interpolated. The realization registers the `vector` unit's failure
on the notification contract.

**Local state is keyed by the identifiers in the rendered config.** The log
sink's disk buffer, the journald read checkpoints and the health exporter's own
state all live under `data_dir`, named by the component (`logs`, `journald`,
`vector-health`). Repointing `sink.endpoint` at a different backend is a config
edit and does **not** move the queue: the old records drain to the new URL,
which is a delivery and retention decision — records buffered under one policy
arrive at a store chosen under another. Renaming a component abandons its state
instead: the old buffer and checkpoint are no longer read. Treat a rename like
an exporter rename on the OTLP side — drain first, or disclose the stranded
backlog — and keep the stable name across a rollout. Rolling the host's whole
state back does the same thing in reverse: restoring a root snapshot from before
the change restores the state the old names expect. Who drains is consumer-owned:
the fleet publishes coordinates, the consumer that binds them performs the drain.
The queue layout under `data_dir` is Vector's own and is not a documented
interface here.

## Secrets

`services.telemetry.secretFiles.<id>` (nullable path) and
`services.telemetry.secretKeys.<id>` (SOPS key path) must have matching IDs. An
unbound/null file registers nothing; referenced unknown or unbound IDs fail
closed. Secret IDs use ASCII letters, digits, and underscores. The ID/pairing
vocabulary and the "unknown secret reference" check live in the reusable
contract fragment, so they hold whether or not an OTel instance runs — a vmagent
host validates its credentials exactly the same way. Each realization binds only
the secrets its own **active** exporters need, so a host can compose both
without duplicating the binding, and a declared-but-unused destination
contributes no exporter, no secret and no validation override:

- **otel-collector** registers `sops.secrets."otel-collector/<id>"`, then
  renders a root-owned `sops.templates."otel-collector.env"` as
  `OTELCOL_<id>=<placeholder>`. The nixpkgs-owned unit loads that file through
  `EnvironmentFile` and reads headers as `"<prefix>${env:OTELCOL_<id>}"` at
  runtime. Matching build-time validation overrides are generated without
  putting credentials into the Nix store, and secret/template rotation restarts
  the collector.
- **vmagent** registers `sops.secrets."vmagent/<id>"` for the secrets its
  remote-write headers reference, then renders
  `sops.templates."vmagent.env"` as `VMAGENT_<id>=<placeholder>`. The unit loads
  it through `EnvironmentFile` and the argument reads
  `"<prefix>%{VMAGENT_<id>}"`, expanded by vmagent itself at startup.

Each implementation registers its own unit's failure on the notification
contract, and only while the unit exists.

## Loopback and other configuration classes

The contract is a NixOS host interface. A container, a standalone Home Manager
instance, or any process outside the host's NixOS evaluation does not share this
host's loopback address or its option tree: it cannot read
`services.telemetry`, and its OTLP endpoint is not automatically the
collector's loopback port. Such an instance sets its exporter endpoint
explicitly (a literal, or a value the consumer's own flake-level module hands
it). Cross-class access is documented rather than faked — there is no bridge
from Home Manager into `services.telemetry`. A container that must push to a
gateway uses the gateway's network ingress address, not a loopback URL.

## Remote backends and the fleet catalog

Destination selection, credentials and fan-out are consumer policy. Shared
service coordinates are canonical fleet facts in [the service catalog](services.md),
not duplicated consumer literals. Consumers derive those URLs in their own
flake-level wrappers — a NixOS module cannot read flake-level fleet config:

```nix
# consumer flake-level module closing over config.fleet
endpoint = (inputs.nix-fleet.lib.serviceEndpoints.resolveEndpoint config.fleet {
  service = "otel-collector";
  endpoint = "otlp";
  via = "tailnet";
}).url;
```

The canonical `otel-collector.otlp` route names the **home-forge gateway**.
Agents resolve that route for their single trace forwarding destination.
Host-local producers continue using `services.telemetry.otlp.httpUrl`, never
that remote gateway address. Metrics and journals use their direct store routes.
The catalog declares coordinates; it does not attest that a listener has been
deployed or that a backend has received a trace.

**Deployment acceptance is separate from catalog declaration.** A resolved
address is not proof of a working gateway. For the home-forge rollout:

1. deploy the home-forge listener and verify local ingest, remote ingest and each
   backend independently (separately authorized consumer work);
2. reconcile the **existing** `otel-collector.otlp` endpoint with that placement
   and publish the catalog change — no rename combined with the move;
3. relock consumers and replace each agent's direct backend trace legs with the
   single named gateway destination (removing the old legs, or traces are
   exported twice);
4. exercise an agent-to-gateway outage and a single-backend outage in
   deployment, inspecting origin identity and queue pressure.

A catalog update does not move or enable a consumer service. Do not report the
rollout as delivering until the live acceptance gates pass, and retain or drain
pending data before retiring an old listener.

## Adoption and rollback

**Adopting.** Replace `imports = [ …modules.nixos.telemetry ]` with the lane
aspects the host ships (`telemetry-metrics`, `telemetry-logs`, `telemetry-otlp`),
and replace any `services.telemetry.providers.*` override with the realization
aspect that replaces the lane's default. Add `services.telemetry.otlp.signals`
for every host that pushes OTLP to its local endpoint; existing scrape and
journald declarations keep their shape. A host that only scrapes or only ships
journald needs no admission. A gateway composes the OTLP lane and binds
`otlp.ingress` instead of pointing `otlp.host` at a network address, and moves
host identity into `resourceAttributes` knowing that it now applies to local
inputs only.

**Verifying what is local and what is consumer-owned.** `nix flake check` and
`checks.telemetry-*` validate configuration, mutation failures and offline
delivery semantics (acceptance, restart recovery, independent fan-out, overflow,
source identity) against the real collector binary with synthetic payloads and
local receivers. They are **not** live acceptance: tailnet grants, backend
relocation, credential scope and end-to-end receipt are consumer deployment
gates. The remote-write and JSON-line lanes carry configuration validation and
realization-published health scrapes; only the OTLP path proves outage/restart recovery
below capacity today, and a deterministic outage/restart harness for those two
lanes is deferred, not claimed. Verify at least: local push and remote push,
each backend separately, an allowed device and a denied device, and origin
identity at the backend.

**Rolling back.** Revert the consumer's destinations and the catalog pins to the
last verified endpoint, keep the state directory and the stable exporter IDs,
and drain the queues with a compatible configuration. Rolling back to an
older memory-only adapter does not replay persistent state: drain first, or
disclose the stranded backlog. Do not delete queue state as a routine rollback
step; it is the only copy of undelivered telemetry.

**Container / standalone instances** set their endpoint explicitly for their own
network context; they never inherit the host's loopback URL.
