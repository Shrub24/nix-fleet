# Telemetry (host-local)

Scope: one NixOS host's telemetry. A **single** public aspect,
`flake.modules.nixos.telemetry`, owns the implementation-agnostic
`services.telemetry` contract: a service registers a Prometheus scrape source,
admits OTLP signals on the local endpoint, opts into journald shipping, or binds
a remote destination without knowing which implementation serves it. Selection
is enablement — no top-level enable flag.

A host can also act as an explicit relay or gateway: it forwards only to the
destinations its pipelines select, and it can bind a separate, explicitly
addressed network ingress next to its loopback producer listener. Discovery,
implicit forwarding and a `agent`/`gateway` role switch are out of scope.

```nix
# the host's aspect list: one import
imports = [ inputs.nix-fleet.modules.nixos.telemetry ];
```

## One aspect, implementations as sibling contributors

Implementations are **not** separate aspects, and telemetry has no private
module tree. The aspect is composed from sibling flake-parts contributors that
all merge the same `flake.modules.nixos.telemetry` deferred module:

```text
modules/telemetry/
  telemetry.nix      # the aspect: contract import + realization marker
  otel-collector.nix # OpenTelemetry Collector (OTLP ingest, scrape override)
  vmagent.nix        # VictoriaMetrics vmagent (default Prometheus scrape)
  vector.nix         # Vector (journald shipping)
lib/telemetry-contract.nix  # registration fragment: services.telemetry + guards
```

Siblings never import one another and no implementation is exported as a second
public aspect: swapping or splitting an implementation is a
`services.telemetry.providers.*` value, never an imports-list edit. Selection is
per capability:

```nix
services.telemetry.providers = {
  otlpIngest = "otel-collector"; # default
  prometheusScrape = "vmagent"; # default
  journaldIngest = "vector"; # default
};
```

The capability axis (not the host, not the signal) is the unit of selection, so
metrics and logs can use different implementations later without touching any
registration. The enum lists the implemented set: an unimplemented value is a
contract edit, not a host typo. `prometheusScrape = "otel-collector"` remains
the override for a host whose scraped metrics go to an OTLP destination instead
of a Prometheus remote-write store.

## Providers run only for declared work

A provider starts only when a declared **input** uses it and that input has a
valid destination pipeline. A destination or a provider selection on its own
starts nothing:

| Declared work                                        | vmagent | Vector | OTel collector                              |
| ---------------------------------------------------- | ------- | ------ | ------------------------------------------- |
| scrape source + metrics fanout                       | yes     | no     | no                                          |
| `otlp.signals` + valid pipeline                      | no      | no     | yes                                         |
| `journald.enable` + sink                             | no      | yes    | no                                          |
| scrape source, `prometheusScrape = "otel-collector"` | no      | no     | yes (Prometheus receiver, no OTLP receiver) |
| OTel admission + scrape override                     | no      | no     | yes (both receivers)                        |
| a destination or provider selection alone            | no      | no     | no                                          |

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

**A destination is not admission.** A metrics destination alone no longer starts
the collector and no longer advertises an OTLP receiver.

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

### Shipped producer aspect: node-exporter

`flake.modules.nixos.node-exporter` is a normal aspect a host selects next to
`telemetry`: it enables nixpkgs' node exporter on `127.0.0.1` (no firewall
rule), registers `services.telemetry.scrape.node` for the same port, and
registers its own unit's failure. It names no backend: the host's selected
implementation carries those metrics to whatever metrics destination the
consumer declares.
Selecting it **without** `telemetry` is an orphan registration and fails closed
by name. `services.node-exporter.port` is the only option — one value, so the
listener and the registration cannot disagree; anything else about the exporter
is reachable through nixpkgs' own `services.prometheus.exporters.node`.
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
(4318/4317); the URLs are derived read-only, and `otlp.host` is
**loopback-only**. The network-facing listener is the separate
`otlp.ingress` below, so the advertised producer endpoint and the loopback
listener cannot drift apart.

**Orphan guard.** Registration here is deliberately _not_ declaration-only (the
`notify` idiom). A scrape source, a destination, or a journald sink written on a
host that did not select `flake.modules.nixos.telemetry` fails closed by name:

```text
telemetry: scrape source(s) my-app configured without the host selecting
flake.modules.nixos.telemetry; select that aspect (it realizes the
registration) or remove it. A registration is never silently dropped.
```

A contributing aspect imports the reusable fragment
`lib/telemetry-contract.nix` to write a registration; the fragment carries the
guard. Reliance is on the host selecting the aspect, not on the fragment alone.

The same holds for a **push-only** consumer: it registers nothing, so there is
no orphan to catch, and an endpoint nothing binds would be a dead address.
Reading `otlp.httpUrl` / `otlp.grpcUrl` on a host that did not select the
aspect fails closed by name instead:

```text
telemetry: services.telemetry.otlp.httpUrl was read on a host that did not
select flake.modules.nixos.telemetry; no implementation binds the local OTLP
endpoint. Select the host aspect or drop the read.
```

The read also requires an **admitted signal**, because the endpoint promises an
input the host actually accepts:

```text
telemetry: services.telemetry.otlp.httpUrl was read without admitting any OTLP
signal; the local endpoint promises an input this host accepts, so declare
services.telemetry.otlp.signals (for example [ "traces" ]) before reading it.
Binding a destination alone admits nothing.
```

Admission alone is not enough either: the admitted input must have a destination
pipeline to carry it, or the URL advertises a listener that would acknowledge
what it silently drops.

```text
telemetry: services.telemetry.otlp.httpUrl was read while OTLP admits logs with
no destination pipeline to carry them; an admitted input is only a realized
input once a destination accepts it. Bind a destination accepting the signal or
remove it from services.telemetry.otlp.signals.
```

All three guards are read-time errors: the failure happens where the URL is read,
not when some other value is forced, so a producer that never reads the endpoint
is unaffected by a host that has nothing to serve.

Selecting the aspect with neither a destination nor journald shipping also fails
by name. A host can still use Vector alone for journald shipping.

## Local relay and gateway ingress

A gateway keeps its loopback producer listener and optionally binds a second,
explicitly addressed OTLP listener for other hosts:

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

Log shipping is **opt-in per host** and has its own typed sink: a machine that
selected telemetry for metrics or traces must not start shipping its journal as
a side effect.

```nix
services.telemetry.journald = {
  enable = true;
  includeUnits = [ "nginx" ]; # empty = every unit; _SYSTEMD_UNIT filter
  sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
  # streamFields = [ "_HOSTNAME" "_SYSTEMD_UNIT" ];  # low-cardinality grouping
  # buffer.maxSizeMb = 512; buffer.whenFull = "block";
};
```

`sink.endpoint` is the backend's HTTP JSON-line ingest URL — consumer policy,
never a fleet default. The provider reads the journal locally, writes one JSON
event per line with gzip, and buffers on disk. `streamFields` selects the
backend's stream grouping and is deliberately low-cardinality by default.

**Why this does not go through the local collector.** Journald shipping is a
separate capability with its own provider and its own binding: a host that ships
logs need not admit OTLP logs or run a collector at all. Vector's disk buffer
plus its persistent journal read checkpoints cover journal → Vector → backend: a
backend outage or a Vector restart does not drop what is already buffered, and a
restart resumes after the last checkpoint instead of re-reading. It is
**bounded**, not lossless-forever: the buffer has a capacity, `whenFull = "block"`
stops reading the journal when it is full (the journal keeps its own records, so
nothing is lost until journald rotates) while `drop_newest` discards, and once a
record is accepted by the backend its durability is the backend's business.
Vector's `current_boot_only` default is left in place, so a first start ships the
current boot rather than replaying older ones.

Both mistakes fail closed by name: shipping enabled with no `sink.endpoint`
(`telemetry: journald shipping is enabled but
services.telemetry.journald.sink.endpoint is not set`), and an endpoint that is
not an http(s) URL. An endpoint set while shipping is disabled is the same
class of error as an orphan registration. The provider also rejects a buffer
below Vector's disk-buffer floor rather than letting the service fail at
startup.

## OTLP delivery: persistent, bounded, observable

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
and configured capacity, and enqueue/send failure counters, are visible there.

```nix
# collect them through the ordinary producer interface when you want them
services.telemetry.scrape.otel-collector-health = {
  target = "127.0.0.1";
  port = 9464;
};
```

That registration is a scrape source like any other: it does **not** start a
scraper, a collector or a second provider. A host with no OTel input work has no
operational listener and no OTel failure registration at all. The metrics
endpoint is loopback and is never opened by a firewall rule.

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

The implementation binds the OTLP receiver to `services.telemetry.otlp`, renders
`services.telemetry.scrape` into
`receivers.prometheus.config.scrape_configs` **only when it is the selected
scrape provider** (metrics pipeline only), adds the `otlp/ingress` receiver and
`<signal>/ingress` pipelines when `otlp.ingress` is configured, and validates
the config at build time with the real binary. When a scrape source is
registered but no metrics destination can carry it, it fails closed
(`telemetry: N scrape source(s) are registered but the metrics pipeline has no
destination to carry them`).

## Implementation tuning: vmagent (Prometheus scrape)

vmagent is the default `prometheusScrape` implementation and has no separate
public namespace: its whole surface is the contract's `services.telemetry.scrape`
plus the metrics fanout. The provider renders

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
which the scrape provider vmagent cannot write to — vmagent speaks
prometheus-remote-write only. Repoint those destinations or select
services.telemetry.providers.prometheusScrape = "otel-collector".
```

A scrape source with no metrics destination fails the same way
(`telemetry: N scrape source(s) are registered but the metrics pipeline has no
destination to carry them`). Either way the host gets **no** vmagent unit, so an
unsupported fanout can never be realized as a push to a destination the contract
did not select. A host with no scrape work installs no agent at all.

**Bounded durability, not lossless.** The queue lives under the unit's
`StateDirectory` (`/var/lib/vmagent`, `%S` in the argument), so it is persistent
across reboots rather than working-directory state, and each remote-write
destination is bounded at 1 GiB
(`-remoteWrite.maxDiskUsagePerURL=1073741824`). When that bound is reached
vmagent drops the **oldest** buffered data to make room for newly scraped
samples, and it flushes its file-based queue to a destination before newly
ingested samples go there — a long outage past the bound loses data and lags
the remote store. The management/inspection HTTP endpoint binds loopback
(`-httpListenAddr=127.0.0.1:8429`) and `openFirewall` keeps its false default.
The provider registers the `vmagent` unit's failure on the notification
contract.

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
underscores, `~`, `+`, `/`, `=` — are unaffected. Selecting
`providers.prometheusScrape = "otel-collector"` avoids the restriction entirely,
because OTel reads header values through its own `${env:...}` expansion instead
of vmagent's argument array. The guard itself is exercised by
`checks.vmagent-secret-guard`.

## Implementation tuning: Vector (journald)

Vector is the `journaldIngest` implementation and has no separate public
namespace: its whole surface is the contract's `services.telemetry.journald`
(source filters, sink endpoint, stream fields, buffer bounds). The rendered
`services.vector.settings` is the nixpkgs module's own — the provider sets
`data_dir = "/var/lib/vector"` (the unit's `StateDirectory`, where checkpoints
and the disk buffer live), `journaldAccess = true`, and the JSON-line sink
fields, and the module validates the config at build time through its own
`vector validate` step. Secrets never enter the store: this path needs none (a
private ingest route is authenticated by the network it sits on) and no value in
the generated config is env-interpolated. The provider registers the `vector`
unit's failure on the notification contract.

## Secrets

`services.telemetry.secretFiles.<id>` (nullable path) and
`services.telemetry.secretKeys.<id>` (SOPS key path) must have matching IDs. An
unbound/null file registers nothing; referenced unknown or unbound IDs fail
closed. Secret IDs use ASCII letters, digits, and underscores. The ID/pairing
vocabulary and the "unknown secret reference" check live in the reusable
contract fragment, so they hold whether or not an OTel instance runs — a vmagent
host validates its credentials exactly the same way. Each provider binds only
the secrets its own **active** exporters need, so a host can run both without
duplicating the binding, and a declared-but-unused destination contributes no
exporter, no secret and no validation override:

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

Destination targets are consumer policy, not a fleet contract. Point
`services.telemetry.destinations.<name>.endpoint` at the backend explicitly. A
consumer that owns canonical service-endpoint facts can derive the URL in its
own flake-level wrapper — the NixOS module cannot read flake-level fleet config:

```nix
# consumer flake-level module closing over config.fleet
endpoint = (inputs.nix-fleet.lib.serviceEndpoints.resolveEndpoint config.fleet {
  service = "latitude";
  endpoint = "otlp";
  via = "tailnet";
}).url;
```

The canonical `otel-collector.otlp` route names OCI's gateway listener for
cross-host producers outside a host's NixOS evaluation. Host-local producers
continue using `services.telemetry.otlp.httpUrl`.

**Catalog transition is gated by deployment.** A planned relocation does not
move the published coordinates. The sequence for the home-forge gateway is:

1. deploy the home-forge listener and verify local ingest, remote ingest and each
   backend independently (separately authorized consumer work);
2. only then publish home-forge coordinates for the **existing**
   `otel-collector.otlp` endpoint — no rename combined with the move;
3. relock consumers and replace each agent's direct backend trace legs with the
   single named gateway destination (removing the old legs, or traces are
   exported twice);
4. exercise an agent-to-gateway outage and a single-backend outage in
   deployment, inspecting origin identity and queue pressure.

No canonical coordinate is changed, and no consumer service is moved, solely on
the basis of a plan.

## Adoption and rollback

**Adopting.** Add `services.telemetry.otlp.signals` for every host that pushes
OTLP to its local endpoint; existing scrape and journald declarations keep their
shape. A host that only scrapes or only ships journald needs no admission. A
gateway binds `otlp.ingress` instead of pointing `otlp.host` at a network
address, and moves host identity into `resourceAttributes` knowing that it now
applies to local inputs only.

**Verifying what is local and what is consumer-owned.** `nix flake check` and
`checks.telemetry-*` validate configuration, mutation failures and offline
delivery semantics (acceptance, restart recovery, independent fan-out, overflow,
source identity) against the real collector binary with synthetic payloads and
local receivers. They are **not** live acceptance: tailnet grants, backend
relocation, credential scope and end-to-end receipt are consumer deployment
gates. Verify at least: local push and remote push, each backend separately, an
allowed device and a denied device, and origin identity at the backend.

**Rolling back.** Revert the consumer's destinations and the catalog pins to the
last verified endpoint, keep the state directory and the stable exporter IDs,
and drain the queues with a compatible configuration. Rolling back to an
older memory-only adapter does not replay persistent state: drain first, or
disclose the stranded backlog. Do not delete queue state as a routine rollback
step; it is the only copy of undelivered telemetry.

**Container / standalone instances** set their endpoint explicitly for their own
network context; they never inherit the host's loopback URL.
