# Host telemetry

## Canonical identity describes origin, not the collection endpoint

**Id:** 07b04986-490c-4ad2-8918-3e7428f12c93
**Type:** decision
**Status:** active
**Evidence:** confirmed

Host and optional environment identity are shared contract values. Local OTLP resources, scrape defaults and journal fields project those values into their native representations. Forwarded OTLP keeps the sender's resource identity; explicit scrape-source labels override collector-local defaults. Application `service.name`, systemd unit names and existing Prometheus `instance` values remain independent.

**Reason:** an application, its owning unit and its scrape endpoint are different objects. A collector may also scrape another machine, so stamping its resource identity onto every pipeline would contradict the source's origin labels. The host name defaults from NixOS rather than creating another machine inventory; a consumer override derives from canonical fleet data.

**Rejected alternative:** reuse `instance` or the systemd unit as universal identity. Neither consistently identifies the originating machine or application.

**Rejected alternative:** apply gateway identity to every signal that passes through it. That attributes remote telemetry to the collector and fills missing sender identity with a false origin.

## Journal normalization promotes context without trusting the whole message

**Id:** a3b229cd-831f-4c16-b1ea-22e0cb5808a9
**Type:** decision
**Status:** active
**Evidence:** confirmed

Only supported trace/span keys are promoted from structured messages. Source-record keys take precedence even when invalid; invalid preferred context does not fall back to a different value in the message. The original message and journal metadata survive parsing failure. Correlation fields are searchable data, not log stream keys or metric labels.

**Reason:** arbitrary JSON merging lets an application message shadow journal host or unit metadata. Falling back after a malformed preferred key can attach a log to a different request rather than expose the malformed context. IDs identify individual operations and therefore have unsuitable cardinality for storage partitioning or metric labels.

**Rejected alternative:** merge parsed JSON into the record or guess context from arbitrary text. Both expand the trust boundary beyond explicit correlation carriers.

## Podman's temporary exporter adaptation uses the rootful socket deliberately

**Id:** edd366aa-2c6e-41fb-9ac9-77932c8e22b6
**Type:** workaround
**Status:** active
**Evidence:** confirmed

The package and module adaptation are pinned to nixpkgs PR #507097 at `b859cd0bd7be2b0ea7d5810dab7c537e9c650a59`. Its remote build uses the rootful local Podman socket. Selecting the producer composes the existing Podman aspect and grants the exporter engine-socket access; that access permits engine control, not just metric reads.

**Reason:** the current nixpkgs pin lacks the package/module. The adaptation keeps packaging and socket wiring reproducible without modifying the input. Replace it when the fleet pin includes the upstream implementation and the owned socket/registration integration still passes, not merely when the PR merges.

**Rejected alternative:** use the native libpod build interchangeably with the PR's remote build. They have different engine-access mechanisms; the socket-client adaptation must be verified with the package it actually runs.

**Revisit when:** the fleet's nixpkgs pin contains the merged Podman exporter package and module.

## Pi metrics go through deltatocumulative, local OTLP metrics only

**Id:** 3b8e1d52-9f0a-4c7e-a6b4-5d2c9e8f1a37
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `modules/telemetry/otel-collector.nix`, `lib/telemetry-otel-collector-common.nix`, `modules/telemetry/otel-collector-checks.nix`, 2026-10-12

Pi's OTLP metrics are delta by default, and the `prometheusremotewrite` exporter translates only cumulative sums and histograms, so every Pi series was dropped at translation. The local OTLP metrics pipeline runs `deltatocumulative` after identity enrichment (`memory_limiter → resource/telemetry-identity → deltatocumulative`), and traces, ingress, route and scrape pipelines do not carry it.

**Reason:** the processor is source-agnostic and a no-op for cumulative streams, so the fix belongs in the collector, not in Pi or the host environment. Placement after identity keeps the stream identity stable. Traces reject the processor, so it must stay metrics-only.

**Window:** `max_stale = "5m"` is explicit. A delta stream silent past that window restarts from zero, which matches short-lived Pi child processes whose counters restart per run.

**Rejected alternative:** `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative` on hosts or in pi-otel. It changes the producer for every consumer and would break the per-run counter model.

**Rejected alternative:** an OTTL or Lua transform. Temporality is the only defect, so a transform adds a second mechanism for no gain.

**Open:** ingress and named-route metrics pipelines can receive delta points from remote producers and would drop them the same way. They are not changed here; the fix would be the same placement there, decided with the gateway owner.
