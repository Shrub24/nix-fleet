# Telemetry (host-local)

Scope: one NixOS host's telemetry. A **single** public aspect,
`flake.modules.nixos.telemetry`, owns the implementation-agnostic
`services.telemetry` contract: a service registers a Prometheus scrape source,
reads the local OTLP endpoint, or binds a remote destination without knowing
which collector serves it. Selection is enablement — no top-level enable flag.
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
  prometheusScrape = "otel-collector"; # default
  journaldIngest = "vector"; # default
};
```

The capability axis (not the host, not the signal) is the unit of selection, so
metrics and logs can use different implementations later without touching any
registration. The enum lists the implemented set: an unimplemented value is a
contract edit, not a host typo — there is no provider registry and no
second-import gate.

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
labels. Two independent registrations merge into one receiver and reach the
metrics pipeline.

### Shipped producer aspect: node-exporter

`flake.modules.nixos.node-exporter` is a normal aspect a host selects next to
`telemetry`: it enables nixpkgs' node exporter on `127.0.0.1` (no firewall
rule), registers `services.telemetry.scrape.node` for the same port, and
registers its own unit's failure. It names no backend: the host's collector
carries those metrics to whatever metrics destination the consumer declares.
Selecting it **without** `telemetry` is an orphan registration and fails closed
by name. `services.node-exporter.port` is the only option — one value, so the
listener and the registration cannot disagree; anything else about the exporter
is reachable through nixpkgs' own `services.prometheus.exporters.node`.

**Migration, not coexistence.** A consumer that already scrapes every host's
node exporter over the network from a central store is running a different
design, and the two must not run together: delete those remote jobs (and the
host lists that feed them) when adopting this aspect, or every host is scraped
twice — once locally through its own collector, once remotely. A store's
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

The collector's backends are contract-level, so replacing the implementation or
repointing a backend never reshapes a registration:

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
`receivers.prometheus.config.scrape_configs` (metrics pipeline only), maps each
destination protocol onto its exporter, and validates the config at build time.
When a scrape source is registered but no metrics destination can carry it, it
fails closed (`telemetry: N scrape source(s) are registered but the metrics
pipeline has no destination to carry them`) — the collector accepts an unused
receiver silently, so it rejects instead.

## Secrets

`services.telemetry.secretFiles.<id>` (nullable path) and
`services.telemetry.secretKeys.<id>` (SOPS key path) must have matching IDs. An
unbound/null file registers nothing; referenced unknown or unbound IDs fail
closed. Bound secrets are registered under `sops.secrets."otel-collector/<id>"`,
then rendered into a root-owned `sops.templates."otel-collector.env"` as
`OTELCOL_<id>=<placeholder>`. The nixpkgs-owned unit loads that file through
`EnvironmentFile` and reads headers as `"<prefix>${env:OTELCOL_<id>}"` at
runtime. Matching build-time validation overrides are generated without putting
credentials into the Nix store, and secret/template rotation restarts the
collector. Secret IDs use ASCII letters, digits, and underscores. The
implementation registers its own unit's failure on the notification contract.

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
