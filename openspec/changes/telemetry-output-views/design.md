# Design

## Context

See proposal.md for motivation. The current realization in `modules/telemetry/otel-collector.nix` generates a receiver and one pipeline per route/signal. It renders one exporter per route/destination through `lib/telemetry-otel-collector-common.nix`, preserving destination credentials, `exporterExtra`, persistent queues and retry policy.

Native `services.opentelemetry-collector.settings` already merges into that configuration. By contrast, `services.otel-collector.processors` is automatically included in generated pipelines, including metrics: it is not the place for branch-specific redaction or normalization.

Pinned-source findings relevant to the design:

- [Hindsight 0.10.0 tracing](https://github.com/vectorize-io/hindsight/blob/5d46f9c8c8eb4fb96f549aa63abe1191b82a7840/hindsight-api-slim/hindsight_api/tracing.py) emits one OTLP stream, with LLM spans constructed after calls finish and rich inference-detail events.
- [Reflect tool execution](https://github.com/vectorize-io/hindsight/blob/5d46f9c8c8eb4fb96f549aa63abe1191b82a7840/hindsight-api-slim/hindsight_api/engine/reflect/agent.py) also stores raw tool arguments on spans. Removing inference events alone is not sufficient redaction.
- Async retain continues request context, but several other background task families start new traces. Recall's embedding/reranking spans have no GenAI attributes. Excluding embedding-only traces is acceptable policy, but no trace selector is part of this baseline.
- Langfuse 4.43.0 consumes inference-detail events. Latitude 0.3.118 extracts messages from span attributes; its parser accepts supported JSON message representations. Both ingest ordinary spans. These are source findings, not observed live ingestion.

## Goals / Non-Goals

**Goals:** verify native composition against the pinned Collector, preserve received structure, make content processing independent across outputs, and give downstream owners a checked recipe rather than another option namespace.

**Non-Goals:** deploy homelab, choose backend retention, reconstruct missing spans, promise exactly-once delivery, add authentication, build selective deletion, or automatically discover AI traffic on the general ingress.

## Decisions

### 1. Routes select an input audience; native pipelines shape its outputs

Keep `services.telemetry.routes.<name>` unchanged. A consumer can reuse `ai` when the destination and payload policy are shared with AI-native producers, or use a separate mixed-stream route when those policies differ. A third route is not required by the view mechanism, and a route per application is not the default.

All traffic on the chosen receiver sees its view profiles. Conditional OTTL processing on resource attributes can specialize payload treatment without another listener, but that is not audience selection or authenticated identity. A separate listener is clearer when output policy actually differs.

**Rejected:** a `routes.*.views` DSL or automatic GenAI classification. Both add fleet API surface before native composition has been exhausted.

### 2. Partition existing route exporters between output pipelines

The checked example declares all destinations on its route so the fleet materializes their exporters and credentials. It keeps the generated route pipeline name for the unmodified rich output, replacing its exporter list with `lib.mkForce`. It adds lean and Latitude-adapted sibling trace pipelines consuming the same route receiver and referencing the existing route-scoped exporters.

Each declared destination appears in exactly one effective output path. Checks compare the union of effective exporter assignments with the declaration, reject duplicated assignments, and inspect processor order. Exporter names and storage identities do not change. The recipe must not copy credentials or renderer internals.

Branch-only processors live in native `settings.processors` and are explicitly referenced by their pipelines. Processor lists on generated pipelines use an intentional override, not list concatenation. Retain the memory limiter, preserve forwarded resource identity, and keep the default pipeline free of volatile batching before durable export.

**Rejected:** whole-settings `mkForce`, new connectors, and hand-built exporters. The native receiver can fan out directly, while the fleet remains responsible for credential and delivery rendering.

### 3. Lean is a tested content profile, not a universal privacy promise

The example retains an explicit set of useful span metadata: causal IDs, timing/status, model/provider, usage counts, operation/scope, HTTP/RPC outcome fields and tool names. Its content policy removes inference/tool payloads, query text, raw tool arguments and content-bearing exception fields while retaining useful non-content error metadata. Resource identity is preserved; the documentation identifies resource attributes, status descriptions and unknown instrumentation fields as additional privacy surfaces requiring consumer review.

Synthetic fixtures put distinct content sentinels into each known carrier. Assert forbidden sentinels are absent from the lean export and present where permitted in the rich export. Also assert metadata and received span structure survive, rather than considering an empty output successful redaction.

The profile is an illustrative consumer-owned choice, not an automatically enabled fleet policy. Redaction happens before the lean export queue; richer data may already exist in producer/relay queues and Hindsight's separate `llm_requests` database.

### 4. Latitude adaptation has its own pipeline

Copy supported inference-detail message content into the pinned parser's accepted span-attribute representation only in the Latitude output. Existing canonical message attributes take precedence. Preserve event content and trace structure on the rich side; do not overwrite Langfuse's input carrier or introduce a message carrier into the lean side.

Validate emitted attributes with the actual pinned Latitude 0.3.118 parsing code or an isolated test importing that code, not a hand-reimplemented parser. This is the consumer's deployed version, not a newer target. No live backend is required for this offline compatibility check. Failure to validate the mapping blocks claiming message compatibility.

The consumer reports two additional deployed 0.3.118 constraints: its API key is organization-scoped, so the exporter needs an explicit `X-Latitude-Project` header; gzipped OTLP protobuf is rejected, so its destination-scoped `exporterExtra` sets `compression = "none"`. The checked example must preserve both settings on the existing route exporter and use synthetic project data, not a fleet default or the consumer's project slug. These transport findings are consumer-reported live evidence, separate from the offline parser probe.

### 5. Full-stream fanout is the initial policy, not the end state for sparse apps

Do not buffer traces waiting for a GenAI marker. Slow calls and queued continuation make retrospective whole-trace selection a bounded best-effort operation; exporter WALs do not make a selector's earlier trace buffer durable.

For later sparse-LLM applications, use a separately chosen mixed-stream policy when useful. First measure ordinary-only versus LLM-containing trace volume and bytes, and assess the UI cost. Early producer-declared operation eligibility is preferable when available. A bounded tail selector can later be added only to the rich branch, with explicit late-span/restart/capacity behaviour. The lean operational branch remains structurally complete. Backend garbage collection is not assumed to remove irrelevant traces automatically.

**Rejected for now:** increasing tail wait until it appears reliable, filtering isolated LLM spans, or deleting traces after ingestion. Each introduces a new correctness or maintenance problem absent from full-stream fanout.

## Risks / Trade-offs

- Full rich copies include ordinary-only requests -> explicit stream choice and backend retention; measure before adding selection.
- Native overrides can bypass the apparent route declaration -> guard effective rendered pipelines, not just destination declarations.
- Shared receiver processing can expose mutation mistakes between branches -> runtime checks assert both redacted and rich copies from the same input.
- Normalization may retain content twice in a rich view -> document representation duplication and keep it out of the lean view; do not claim zero duplication.
- Policy drift across producer upgrades -> pin representative carrier fixtures and require consumer review when instrumentation changes.
- Retry can duplicate records -> preserve the existing bounded at-least-once delivery limits; one output path per backend avoids additional configured duplication.

## Migration Plan

1. Land the checked recipe, contract wording and regression checks without changing default production pipelines.
2. Homelab applies the recipe to its chosen route, retaining existing exporter identities and destination-scoped options. It binds Hindsight's single exporter deliberately to that listener.
3. Verify synthetic live delivery in Victoria, Langfuse and Latitude, including effective pipelines and parsed messages. Until then, report source/parser checks separately from deployed behaviour.
4. Roll back native pipeline overrides and sibling pipelines to restore the original same-payload fanout; producer endpoints and exporter queue identities remain unchanged.

The separately pending `ai-otlp` inventory record is not part of this change. Publishing a coordinate does not demonstrate that a listener is deployed; consumer rollout must verify availability before switching producers.
