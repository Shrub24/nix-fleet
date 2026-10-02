# Design

## Context

See `proposal.md` for motivation and the three delta specs for required behaviour.

Read-only reconnaissance found:

- `modules/telemetry/telemetry.nix` exposes one public aspect but manually imports plain NixOS modules under `_providers/` and `_contract.nix`.
- `_contract.nix` already validates destinations, protocol/signal pairs, fan-out and orphan registrations. Its OTLP URL guard checks realization and destination count, not actual OTLP input work.
- `_providers/otel-collector.nix` enables OTel whenever any destination exists, renders every declared exporter, supplies an OTLP receiver to every resolved signal pipeline, and puts a memory-only `batch` processor before export. It globally upserts `resourceAttributes`.
- `_providers/vmagent.nix` already activates only for scrape work, enforces remote-write fan-out, uses a persistent 1 GiB-per-destination queue and guards parser-sensitive credentials. Vector already activates only for journald work and uses persistent checkpoints and a bounded disk buffer.
- `modules/flake/fixture.nix` explicitly expects a vmagent-only metrics configuration to retain an OTel OTLP metrics pipeline. That expectation must change, not be preserved as accidental compatibility. Other checks cover the OTel scrape override, orphan registrations, Vector-only operation and credentials.
- `modules/observability/node-exporter.nix` and fixture modules import the existing registration fragment directly; moving it requires updating these call sites and the documented producer pattern.
- `docs/contracts/telemetry.md` excludes cross-host routing as well as discovery and says a gateway replaces the local receiver's host. Explicit destination chaining is already representable. The revised contract will allow that explicit routing and separate ingress while continuing to exclude discovery and implicit forwarding.
- The inspected working-tree `lib/service-inventory.nix` advertises `otel-collector.otlp` on OCI:4318. This is an existing working-tree fact, not evidence that a home-forge listener exists.
- Pinned nixpkgs provides Collector Contrib 0.155.0. Its NixOS module already owns config validation, `DynamicUser`, `StateDirectory=opentelemetry-collector` and restart handling. No replacement unit is needed.

There are no main OpenSpec capability specs yet. The new deltas establish behavioural authority for the affected surface; they do not supersede an existing capability under a different name.

## Goals / Non-Goals

**Goals:**

- Make input work, export routing and network exposure independent declarations.
- Keep the producer interface stable across collector implementations and gateway relocation.
- Pay for each capability only on hosts using it.
- Define a testable persistent-delivery boundary and preserve source identity across it.
- Keep implementation configuration in the upstream service options or existing provider-specific tuning namespace.

**Non-Goals:**

- Moving Langfuse/Latitude, editing homelab/dotfiles, distributing secrets or changing live network policy in this repo-local change.
- A collector graph resolver, automatic nearest-gateway selection, agent/gateway role enums, public external-device ingress or a new authentication PKI.
- Routing Prometheus remote write or Vector JSON-line traffic through an OTLP relay.
- Alloy implementation, custom Collector builds, Kafka, HA gateways, tail sampling or a generic redaction/alert policy engine.
- Folding the deferred node-instance default correction into this change.

## Decisions

### 1. Keep one interface and derive provider work explicitly

Retain `services.telemetry.providers`, `scrape`, `journald`, `destinations` and `pipelines`. Add `otlp.signals`, a list of unique signals defaulting to `[]`. Every admitted signal must have a valid nonempty resolved pipeline. Declaring a destination alone does not claim an input.

An OTel instance is needed when its selected OTLP capability has admitted signals, or its selected Prometheus scrape capability has registered sources. vmagent and Vector keep their existing work predicates. OTel's active signals are the admitted OTLP signals plus metrics when it owns scrape work; active exporters are the union of destinations those signals actually select. Secret binding and validation overrides follow that union. Shared secret-ID and pairing invariants belong in the reusable contract, so disabling OTel does not disable validation vmagent relies on.

The explicit OTel scrape override remains valid with no OTLP admission. If both OTLP metrics and scraped metrics use different providers, they still carry different input data; no provider acquires another provider's sources implicitly.

**Alternative rejected:** infer activation from destination protocol or evaluation of `httpUrl`. A destination does not declare an input, and evaluating a value cannot safely cause module activation.

### 2. Add ingress without moving the local interface

Keep `otlp.host`, `httpPort`, `grpcPort` and derived producer URLs for the local receiver; require its host to be loopback. Add nullable `otlp.ingress`, absent by default, containing a required consumer-bound host and nullable HTTP/gRPC ports. Default its HTTP port to 4318 and its gRPC port to null. At least one transport is required. It inherits `otlp.signals`; it is not another routing or signal-selection surface.

Reject wildcard/empty ingress addresses and identical local/ingress transport bindings. The consumer supplies the actual tailnet bind address, startup ordering/retry posture and interface-specific firewall policy. The mechanism adds no public firewall opening or network authentication secret. DNS/address availability at service start remains a deployment check.

Render separate local and ingress OTLP receiver IDs. Both feed the selected destinations, but source-specific processing uses distinct signal pipelines sharing exporter IDs. This lets one collector serve home-forge's local applications and remote relays without a second relay process.

**Alternative rejected:** change the existing local `host` to the gateway address. That moves the producer interface onto the network and prevents source-specific identity handling. A general named-listener registry is unnecessary for the single additional listener we need.

### 3. Relay and gateway are destination compositions

A relay selects a single named OTLP destination in `pipelines.traces`; a gateway selects VictoriaTraces, Langfuse and Latitude. The adapter treats them alike. No role switch or collector-type catalog is introduced.

Metrics remain vmagent to VictoriaMetrics; journald remains Vector to VictoriaLogs. home-forge runs local vmagent/Vector only to collect its own data, not to receive other hosts' metrics/logs. Backend services receive those protocols directly.

Consumers close over the ordinary `lib.serviceEndpoints.resolveEndpoint` result when binding the relay destination. Preserve the existing `otel-collector.otlp` catalog key during relocation rather than combining an endpoint rename with this change. Publish home-forge coordinates only after its network listener is deployed and tested. Backend placement and addresses can stay homelab-local because agents need only the gateway address.

**Alternative rejected:** a fleet-wide collector search or direct backend export from every host. The former adds discovery ambiguity; the latter distributes credentials and fan-out policy.

### 4. Persist before acknowledging asynchronous delivery

Use the existing nixpkgs service state directory for `file_storage`, with restrictive permissions and `fsync=true`. Default each active exporter to a persistent sending queue sized in serialized bytes: 256 MiB payload capacity per exporter. Set bounded export attempts, retryable failures with `max_elapsed_time=0`, non-blocking overflow rejection and queue-integrated batching. Validate these defaults with the pinned binary, not the latest documentation alone.

Remove the default pre-export `batch` processor. Queue-integrated batching is supported by the pinned release and avoids making successful acceptance depend solely on that volatile batch. Explicit custom processors remain an escape hatch, but asynchronous custom processors can weaken the default guarantee and must be documented as such.

Each backend leg gets its own stable exporter ID and queue. Gateway unavailability accumulates agent backlog; backend unavailability accumulates the corresponding gateway backlog. If a queue cannot accept a request, return an error and record enqueue failure. Fan-out is not transactional: partial success followed by upstream retry can duplicate data at healthy destinations.

The queue capacity bounds buffered serialized payload, not physical database size. Version 0.155.0's file-storage documentation does not expose the later `max_size` database cap. Configure supported compaction, retain headroom for database overhead/compaction and monitor disk pressure; do not generate an unsupported setting or advertise a hard filesystem quota. Raw upstream settings and `exporterExtra` remain tuning escape hatches rather than adding a parallel generic queue configuration language.

**Alternatives rejected:** memory-only retry queues, indefinite retry without finite capacity, or Kafka for this fleet's initial traces volume.

### 5. Separate local enrichment from forwarded identity

Apply existing `services.otel-collector.resourceAttributes` enrichment to local receiver/scrape pipelines only. Consumers bind canonical host identity there; the mechanism does not guess it from the system hostname. Additional-ingress pipelines preserve remote resource attributes by default and do not inherit gateway-local enrichment.

This narrows the existing globally applied tuning behaviour and must be called out in migration documentation. Explicit consumer transformations remain possible through provider/upstream settings. Gateway filtering is not sufficient to protect relay queues: content that must never be stored requires producer or local pre-queue redaction.

Tailscale grants authorize device access to the ingress port, not the correctness of `host.name` or the process sending the trace. No routing or authorization decision depends on claimed resource labels.

**Alternative rejected:** blanket gateway resource upserts, which relabel remote traces as home-forge traffic.

### 6. Make delivery health inspectable without reviving port 8888

Configure the active collector's own Prometheus metrics explicitly on loopback, default port 9464 with an upstream override. Expose exporter queue/capacity, enqueue-failure and send-failure metrics. Do not enable the implicit 8888 listener that previously collided with Hindsight.

Document registration of this endpoint through the existing local scrape interface when a consumer wants collection. A trace-only host must not acquire vmagent merely to host the operational endpoint. OTel owns its failure registration only while its service exists. Collector metrics, packet admission and end-to-end delivery are separate validation signals; green config validation is not proof of live delivery.

### 7. Use sibling Dendritic contributors

Convert telemetry's primary implementation files into auto-discovered flake-parts siblings contributing to `flake.modules.nixos.telemetry`, for example `telemetry.nix`, `otel-collector.nix`, `vmagent.nix` and `vector.nix` under `modules/telemetry/`. They merge the same deferred module; no provider is exported as another aspect and siblings do not import one another.

Put the reusable option/orphan fragment under `lib/telemetry-contract.nix`, outside the flake-parts discovery tree. The telemetry contributor and producer aspects can import that genuine helper. Update all existing direct telemetry-fragment users; delete the old files rather than leaving compatibility shims. Keep this restructuring confined to telemetry.

**Alternative rejected:** extending the private provider directory as the primary feature structure, which leaves plain NixOS modules under a tree required to contain flake-parts modules.

## Risks / Trade-offs

- [Finite queues and permanent failures still lose telemetry] → Document limits, exercise overflow and expose delivery metrics; do not promise exactly-once delivery.
- [Persistent trace payload contains prompts or credentials] → Restrict state permissions, keep it out of configuration artifacts and require capture/redaction policy before storage where needed.
- [Fsync and serialized-byte sizing add I/O/CPU cost] → Start with modest trace volume and measure; upstream overrides permit deliberate tuning without changing producer registrations.
- [Physical database growth exceeds queued payload] → Use supported compaction, disk-pressure monitoring and storage headroom; no unsupported database cap.
- [Multiple fan-out branches can partially accept a request] → Test independent progress and permit duplicate replay; no atomic fan-out claim.
- [A single observability host is a failure domain] → Agents buffer within capacity; consumers retain an availability check outside home-forge.
- [Tailnet grants are broader than intended or the address is unavailable at boot] → Consumer deployment checks allowed/denied devices, existing broad grants and cold-boot listener recovery.
- [Explicit admission breaks implicit OTLP consumers] → Publish the migration together with the mechanism; no compatibility auto-enable or hostname heuristic.
- [Changing exporter IDs abandons pending queues] → Keep IDs stable, drain queues before incompatible renames and retain state during rollout/rollback.

## Migration Plan

1. Land fleet mechanisms and checks without relocating any live endpoint or editing consumer repositories.
2. Consumers add `otlp.signals = [ "traces" ]` where they deploy trace ingestion. Existing scrape/journald declarations remain unchanged. Migrate gateway host rebinding to the new additional ingress option and move local identity enrichment onto local pipelines.
3. Homelab relocates the backends and deploys the home-forge gateway with explicit backend fan-out, credentials, tailnet listener and network policy. Verify local ingest, remote ingest and each backend independently. This is a separately authorized consumer deployment.
4. Publish the existing catalog endpoint's home-forge coordinates only after verification; align any endpoint-value checks and contract examples with the verified address.
5. Relock consumers and replace agent trace fan-out with only the named gateway destination. Remove their direct VictoriaTraces/backend trace legs to avoid duplicate exports. Keep metrics/log paths unchanged. Containers and standalone Home Manager receive explicit endpoints appropriate to their actual network context.
6. Exercise an agent-to-gateway outage/restart and a single-backend outage/recovery in deployment. Inspect origin identity and queue pressure before calling adoption complete.

Rollback: revert consumer destinations/catalog pins to the last verified endpoint, retain state directories and stable exporter IDs, and drain queues using a compatible collector configuration. Rolling back to the old memory-only adapter does not replay persistent state automatically; drain first or disclose stranded/lost backlog. Do not delete queue state as a routine rollback step.

## Verification

Extend fixture evaluation with a capability matrix: vmagent-only, Vector-only, OTLP traces-only, combined capabilities, OTel scrape override with OTLP disabled, and local-plus-network gateway. Mutation checks must assert named errors for missing admission, empty admitted-signal export, unsupported fan-out, inactive URL reads and listener conflicts.

Add a bounded offline real-collector integration check using synthetic OTLP payloads with unique IDs and local receivers. Establish collector-process readiness; block downstream delivery; observe successful acceptance; kill/restart the collector with the same state; recover downstream; assert every accepted test ID arrives, allowing duplicates. Repeat with three exporters and one unavailable leg. Verify unadmitted-signal rejection, overflow failure and original host/service identities. No tailnet, real backend credentials or live services are needed for this check.

Validate generated configs using nixpkgs' existing build-time path. Keep `nix fmt`, all-systems flake evaluation and the native fixture/integration builds green. Network grants, backend relocation and live end-to-end receipt remain consumer acceptance gates, not results inferred from these offline checks.

## References

- Current contract: `docs/contracts/telemetry.md`; current adapters and fixtures identified in Context.
- Pinned exporter helper: https://github.com/open-telemetry/opentelemetry-collector/blob/v0.155.0/exporter/exporterhelper/README.md
- Pinned storage extension: https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.155.0/extension/storage/filestorage/README.md
- Agent/gateway deployment: https://opentelemetry.io/docs/collector/deploy/other/agent-to-gateway/
