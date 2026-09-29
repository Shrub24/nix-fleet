# Telemetry endpoint capabilities

Telemetry capabilities live on service endpoints, not in a separate registry.
`flakeModules.fleet` provides the schema under `fleet.services` and
`lib.telemetry` provides pure projections. Only endpoints actually bound by a
consumer or declared as canonical facts are selectable. The two directions
have different audiences: **ingest** advertises a producer-facing collector
receiver; **sink** advertises a backend to which a collector may export.
Backends are sinks, never ingest endpoints. No collector or backend is in the
canonical inventory yet; fleet-render checks use invented sample endpoints.

```nix
fleet.services.my-collector.endpoints.otlp = {
  tailnet = { host = "my-host-id"; port = 4318; }; # existing endpoint route
  telemetry.ingest = {
    protocol = "otlp-http";
    signals = [ "traces" "logs" ];
  };
};
```

`telemetry.ingest` is optional (null by default); its `protocol` is one of
`otlp-grpc`, `otlp-http`, `prometheus-remote-write`, `loki-push`, and `signals`
is a non-empty list drawn from `traces`, `metrics`, `logs`. A declared ingest
endpoint must have a tailnet route to be selected. The URL, hostname, and port
come from `lib.serviceEndpoints.resolveEndpoint` with `via = "tailnet"`;
there is no fallback to a public route. `telemetry` nests `ingest` so a future
`expose` direction can be introduced without confusing producers with
consumers. Import/selection is enablement; there is no top-level enable flag.

```nix
let
  ingest = inputs.nix-fleet.lib.telemetry;
  endpoint = ingest.resolveIngest config.fleet {
    signal = "logs";
    # protocol = "otlp-http";         # optional filter
    # collector = "my-collector";      # optional service ID
  };
  environment = ingest.otlpEnv {
    inherit endpoint;
    service = "my-app";
    hostId = "my-host-id";
    extraAttributes."deployment.environment" = "production";
  };
in environment
```

`resolveIngest fleet { signal; protocol?; collector?; }` returns exactly one
`{ url; service; hostname; port; protocol; signals; }` record. `collector`
is the `fleet.services` **service ID**, not the endpoint name: when given,
only its endpoints are considered; otherwise all advertised ingest endpoints
are candidates. Signal and optional protocol filter either selection. A
single collector can advertise several endpoints; if more than one fits,
selection is still ambiguous. Zero or multiple matches fail closed with
named `telemetry:` errors and candidate `service.endpoint` names. Unknown
signal, protocol, and collector also fail by name. No discovery fallback or
arbitrary first match occurs. `ingestTargets fleet { signal?; protocol?; }`
returns all matching records (all ingest endpoints when unfiltered), in
service/endpoint name order, for future data-driven selection; it does not
choose a preferred target. Missing tailnet routes fail through the endpoint
resolver rather than silently choosing a public URL.

A backend owner may declare `telemetry.sink = { protocol = "otlp-http";
signals = [ "traces" ]; };` on its endpoint. It has the same protocol enum
and non-empty signal list as ingest. `lib.telemetry.resolveSink fleet {
service; endpoint; signal?; protocol?; }` resolves that **explicitly named**
backend via its tailnet route to the same `{ url; service; hostname; port;
protocol; signals; }` record shape. There is no sink search or unique-match
default: collector configs name their targets. Unknown service/endpoint,
missing sink capability, and requested signal/protocol mismatch fail closed
by name. `resolveIngest` and `ingestTargets` never consider sinks, even if a
sink is the only endpoint accepting a given signal.

`otlpEnv { endpoint; service; hostId; extraAttributes?; }` emits
`OTEL_EXPORTER_OTLP_ENDPOINT` (the resolved URL),
`OTEL_EXPORTER_OTLP_PROTOCOL` (`http/protobuf` for `otlp-http`, `grpc` for
`otlp-grpc`), `OTEL_SERVICE_NAME` (the workload name), and
`OTEL_RESOURCE_ATTRIBUTES` (comma-separated `k=v` entries, including
`service.name=<service>` and `host.name=<hostId>`). Additional attributes are
an attrset of names to string values, rendered in attribute-name order;
reserved `service.name` and `host.name` cannot be overridden. Non-OTLP
protocols are rejected by name instead of being mapped to OTLP settings.

## Collector aspect

Select `flake.modules.nixos.otel-collector` to run nixpkgs' OpenTelemetry
Collector service. There is no aspect-level enable flag. A local **agent**
uses the default `services.otel-collector.ingest.address = "127.0.0.1"` and
receives OTLP gRPC on 4317 and OTLP HTTP on 4318. A **gateway** binds its
consumer-provided tailnet address through `ingest.address`; the consumer
also declares a `fleet.services.<service>.endpoints.<endpoint>.telemetry.ingest`
endpoint with the **same address and port** it exposes to producers. The
NixOS aspect cannot write flake-level fleet facts. Exposure and firewall
rules remain consumer-side.

```nix
services.otel-collector = {
  ingest.address = "127.0.0.1"; # or a gateway's tailnet address
  resourceAttributes."host.name" = "my-host-id";
  exporters.upstream = {
    type = "otlphttp";
    endpoint = "https://collector.invalid"; # consumer-supplied
    headers.Authorization = {
      secret = "upstreamToken";
      prefix = "Bearer ";
    };
  };
  secretFiles.upstreamToken = ./secrets/collector.yaml;
  secretKeys.upstreamToken = "collector/token";
};
```

`package` defaults to `pkgs.opentelemetry-collector-contrib` (overridable).
`processors` defaults to `memory_limiter` and `batch`; additional processors
are passed through. When `resourceAttributes` is non-empty, a `resource`
processor upserts those attributes. Processor order is memory_limiter,
resource (when present), batch, then other processor names alphabetically.
Consumers may derive an exporter URL from the catalog in their flake-level
wrapper, e.g. `endpoint = (resolveSink config.fleet { service = "latitude";
endpoint = "otlp"; signal = "traces"; }).url`. The NixOS aspect itself does
not read flake config. `exporters.<name>.type` accepts `otlp`, `otlphttp`,
`prometheusremotewrite`, or `debug`; all but debug require `endpoint`.
`extra` recursively overrides the generated exporter config. An `otlp`
exporter with an `http://` endpoint defaults `tls.insecure = true` unless
`extra` overrides it.

`pipelines.{traces,metrics,logs}` default to `null`, deriving each signal's
exporters from the declared exporter types: OTLP and debug support all three,
remote-write supports metrics only. Empty derived pipelines are omitted. An
explicit exporter-name list overrides the derivation and must be nonempty,
refer to declared exporters, and match the signal. With no exporters, the
consumer must add one before the collector config can validate at build time.

`secretFiles.<id>` (nullable path) and `secretKeys.<id>` (SOPS key path)
must have matching IDs. An unbound/null file registers nothing; referenced
unknown or unbound IDs fail closed. Bound secrets are registered under
`sops.secrets."otel-collector/<id>"`, then rendered into a root-owned
`sops.templates."otel-collector.env"` as `OTELCOL_<id>=<placeholder>`.
The nixpkgs-owned unit loads that file through `EnvironmentFile` and reads
headers as `"<prefix>${env:OTELCOL_<id>}"` at runtime. The aspect provides
matching build-time validation overrides without putting credentials into
the Nix store, and secret/template rotation restarts the collector. Secret
IDs use ASCII letters, digits, and underscores. Consumers own exporter URLs,
credentials, backend selection, exposure, firewall policy, and the matching
fleet ingest advertisement; backend owners declare sink endpoints in the
catalog, never ingest endpoints.

**Still deferred:** the opposite `expose` direction, self-registration,
automatic agent-to-gateway forwarding, and backend fan-out policy.
