# Telemetry ingest (v1)

Telemetry is an **ingest capability on a service endpoint**, not a separate
registry, an agent deployment, or a backend catalog. `flakeModules.fleet`
provides the schema under the existing `fleet.services` catalog and
`lib.telemetry` provides pure projections. Only endpoints actually bound by a
consumer or declared as canonical facts are selectable. No collector is in the
canonical inventory yet; the fleet-render fixture uses invented sample
collectors solely to exercise this contract.

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

`otlpEnv { endpoint; service; hostId; extraAttributes?; }` emits
`OTEL_EXPORTER_OTLP_ENDPOINT` (the resolved URL),
`OTEL_EXPORTER_OTLP_PROTOCOL` (`http/protobuf` for `otlp-http`, `grpc` for
`otlp-grpc`), `OTEL_SERVICE_NAME` (the workload name), and
`OTEL_RESOURCE_ATTRIBUTES` (comma-separated `k=v` entries, including
`service.name=<service>` and `host.name=<hostId>`). Additional attributes are
an attrset of names to string values, rendered in attribute-name order;
reserved `service.name` and `host.name` cannot be overridden. Non-OTLP
protocols are rejected by name instead of being mapped to OTLP settings.

**Deferred:** the opposite `expose` direction, self-registration,
agent/local forwarding, collector deployment, and fan-out. Deployment and
routing policy remain consumer-owned. Backends are **never advertised** as
fleet ingest capabilities: only an actual collector ingress endpoint belongs
in this contract.
