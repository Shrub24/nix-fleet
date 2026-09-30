# Telemetry (host-local)

Scope: one NixOS host's telemetry. A **single** public aspect,
`flake.modules.nixos.telemetry`, owns the implementation-agnostic
`services.telemetry` contract: a service registers a Prometheus scrape source,
reads the local OTLP endpoint, or binds a remote destination without knowing
which implementation serves it. Selection is enablement — no top-level enable
flag.
Cross-host routing, a fleet-wide DAG, self-discovery, and implicit forwarding
are out of scope.

```nix
# the host's aspect list: one import
imports = [ inputs.nix-fleet.modules.nixos.telemetry ];
```

## One aspect, implementations as private modules

Implementations are **not** separate aspects. The aspect imports a private
module per implemented backend (`modules/telemetry/telemetry/_providers/`);
swapping or splitting an implementation is a value change, never an
imports-list edit. Selection is per capability:

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
contract edit, not a host typo — there is no provider registry and no
second-import gate. `prometheusScrape = "otel-collector"` remains the override
for a host whose scraped metrics go to an OTLP destination instead of a
Prometheus remote-write store.

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

`services.telemetry.otlp.{host,grpcPort,httpPort}` default to loopback
(4317/4318); the URLs are derived read-only. A gateway overrides `host` to a
consumer-provided address — the implementation binds where the contract says,
so the advertised endpoint cannot drift from the listener.

**Orphan guard.** Registration here is deliberately _not_ declaration-only (the
`notify` idiom). A scrape source, a destination, or a journald sink written on a
host that did not select `flake.modules.nixos.telemetry` fails closed by name:

```text
telemetry: scrape source(s) my-app configured without the host selecting
flake.modules.nixos.telemetry; select that aspect (it realizes the
registration) or remove it. A registration is never silently dropped.
```

A contributing aspect imports the fragment
`modules/telemetry/telemetry/_contract.nix` to write a registration; the
fragment carries the guard. Reliance is on the host selecting the aspect, not
on the fragment alone.

The same holds for a **push-only** consumer: it registers nothing, so there is
no orphan to catch, and an endpoint nothing binds would be a dead address.
Reading `otlp.httpUrl` / `otlp.grpcUrl` on a host that did not select the
aspect fails closed by name instead:

```text
telemetry: services.telemetry.otlp.httpUrl was read on a host that did not
select flake.modules.nixos.telemetry; no implementation binds the local OTLP
endpoint. Select the host aspect or drop the read.
```

A host must also bind a destination before advertising either OTLP URL. With
none, the OTel collector has no exporter pipeline and stays off; a read fails
with `telemetry: ... was read without any destinations` instead of producing a
dead endpoint or a collector build error. Selecting the aspect with neither a
destination nor journald shipping also fails by name. The same host can still
use Vector alone for journald shipping.

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

**Why this does not go through the local collector.** The OTel pipeline is
memory-only, so routing journald through it would advertise a durability it does
not have. Vector's disk buffer plus its persistent journal read checkpoints
cover journal → Vector → backend: a backend outage or a Vector restart does not
drop what is already buffered, and a restart resumes after the last checkpoint
instead of re-reading. It is **bounded**, not lossless-forever: the buffer has a
capacity, `whenFull = "block"` stops reading the journal when it is full (the
journal keeps its own records, so nothing is lost until journald rotates) while
`drop_newest` discards, and once a record is accepted by the backend its
durability is the backend's business. Vector's `current_boot_only` default is
left in place, so a first start ships the current boot rather than replaying
older ones.

Both mistakes fail closed by name: shipping enabled with no `sink.endpoint`
(`telemetry: journald shipping is enabled but
services.telemetry.journald.sink.endpoint is not set`), and an endpoint that is
not an http(s) URL. An endpoint set while shipping is disabled is the same
class of error as an orphan registration. The provider also rejects a buffer
below Vector's disk-buffer floor rather than letting the service fail at
startup.

## Implementation tuning: OpenTelemetry Collector

`services.otel-collector` is the OpenTelemetry implementation's own namespace —
the only place that speaks in collector terms:

- `package` (defaults to `pkgs.opentelemetry-collector-contrib`, overridable);
- `resourceAttributes` — upserted into all signals via a `resource` processor;
- `processors` — extra processors, ordered memory_limiter → resource → batch →
  others;
- `exporterExtra.<destination>` — raw exporter override escape hatch.

The implementation binds the OTLP receiver to `services.telemetry.otlp`, renders
`services.telemetry.scrape` into
`receivers.prometheus.config.scrape_configs` **only when it is the selected
scrape provider** (metrics pipeline only), maps each destination protocol onto
its exporter, and validates the config at build time. When a scrape source is
registered but no metrics destination can carry it, it fails closed
(`telemetry: N scrape source(s) are registered but the metrics pipeline has no
destination to carry them`) — the collector accepts an unused receiver
silently, so it rejects instead.

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
closed. Secret IDs use ASCII letters, digits, and underscores. Each provider
binds the secrets its own transport needs, so a host can run both without
duplicating the binding:

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
contract.

## Loopback and other configuration classes

The contract is a NixOS host interface. A container, a standalone Home Manager
instance, or any process outside the host's NixOS evaluation does not share this
host's loopback address or its option tree: it cannot read
`services.telemetry`, and its OTLP endpoint is not automatically the
collector's loopback port. Such an instance sets its exporter endpoint
explicitly (a literal, or a value the consumer's own flake-level module hands
it). Cross-class access is documented rather than faked — there is no bridge
from Home Manager into `services.telemetry`.

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

The earlier fleet-level `telemetry.ingest` / `telemetry.sink` endpoint
capabilities and the `lib.telemetry` resolver were removed: they advertised
collector endpoints in the flake catalog that no host-local registration
consumed. Cross-fleet coordinates stay as generic `fleet.services` endpoint
facts resolved by `lib.serviceEndpoints`.

**Still deferred:** an `expose` direction, external authenticated ingress
(public collector endpoints with auth), automatic agent-to-gateway forwarding,
and cross-host destination discovery.
