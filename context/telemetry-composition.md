# Telemetry composition

## Capability presence is declared by the selected lane

**Id:** 4479ca81-13bc-4cdb-a729-970b6767f5d9
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `openspec/changes/telemetry-capability-aspects/design.md`, decisions 4, 6 and 11, 2026-10-08

Telemetry and notification registrations are dormant declarations. They describe producers, destinations and credentials; they do not infer that a runtime capability exists or should be enabled. Selecting a signal lane composes the realization that delivers that signal.

**Reason:** Nix's module graph expresses dependencies through `imports`. Reading merged configuration to infer which sibling aspects were selected reconstructs that graph indirectly and creates an orphan guard whose logic can diverge from actual composition. The selected lane is the explicit host statement: while composed, its contract is guaranteed to be delivered. A producer registration with no lane is dormant, which means the host has said not to ship it. Shared exporter/credential rendering remains a value-level concern and is declared through a narrow internal option, not an enablement marker.

The prior guarantee that registrations are never silently dropped is narrowed to: **a registration is never silently dropped while its lane is composed**. Host-policy assertions that particular machines select required lanes belong in consumer inventories, where the host policy lives.

**Rejected alternative:** inspect registrations or destination bindings to decide that a lane must be active, or to fail when a registration has no selected realization. That turns data into inferred capability state and makes valid dormant declarations impossible.

**Rejected alternative:** make the telemetry vocabulary a hard import dependency of every producer. A host must be able to compose a producer for local consumption, or provision it before adding a signal lane, without also selecting telemetry.

## Output views are native pipeline composition, not a fleet API

**Id:** 3112615d-1b32-476a-9fec-1b6ae3d880b4
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `openspec/changes/telemetry-output-views/design.md`, `examples/telemetry-output-views.nix`, 2026-10-09

A selected route may deliver different payload representations of the same received stream: a lean operational copy for the trace store and rich copies for explicitly selected AI backends. The destination set stays declared on the route, and native `services.opentelemetry-collector.settings` partitions the route's existing exporters into sibling trace pipelines. After such an override the rendered pipelines are the effective routing; the declaration only determines which exporters and credentials exist.

**Reason:** a mixed application emits useful lifecycle spans and content-bearing LLM spans in one trace, so a per-application listener cannot express "lean copy here, rich copy there". Routes express who the stream belongs to; output views express what each destination may retain. The exporter already carries the credentials, queue identity and WAL path, so partitioning outputs reuses the delivery state the fleet renders rather than rebuilding it.

**Rejected alternative:** a `routes.*.views` option namespace or a fleet processing DSL — it re-exposes the collector's processor model as fleet API surface before native composition has been exhausted

**Rejected alternative:** branch-only processors added to `services.otel-collector.processors` — that list is included in generated pipelines for every signal, so a trace-only redactor or adapter would silently apply to metrics and logs too

**Rejected alternative:** per-application listeners for mixed applications — Hindsight's ordinary requests and its LLM traffic share one causal trace, so separating them by listener would mean the producer guessing an audience per request

## The Latitude adapter uses the version's supported message carrier

**Id:** 4d3f2eff-17b5-467d-b679-ae6e470bb0d5
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `openspec/changes/telemetry-output-views/tasks.md`, pinned `latitude-dev/latitude-llm` v0.3.118 (`67c577ba`), 2026-10-09

Hindsight's inference-detail event values are `{role, content}` arrays. Latitude 0.3.118 reads span attributes only, and its parser accepts those arrays through the deprecated `gen_ai.prompt`/`gen_ai.completion` carriers, so the Latitude view bridges the event into those two attributes. The fill never mixes carrier families inside one span: the two legacy message carriers are filled only when the span carries no canonical message carrier (`gen_ai.input.messages`, `gen_ai.output.messages`) at all, and each is skipped when the producer set that legacy key. The gate names only the canonical keys because the statements set the legacy ones and OTTL runs them in order against the same span. `gen_ai.system_instructions` is the same canonical key in both representations, so it is guarded only by its own presence; the other views are untouched.

**Reason:** the current-carrier parser is reachable only with parts-based `{role, parts:[…]}` messages, and on the current carrier 0.3.118 does not surface plain-text system instructions. Copying Hindsight's arrays into the current names would parse to empty, and an empty parse is silent — so a compatibility claim needs a positive sentinel, not the absence of an error.

**Rejected alternative:** restructure the arrays into parts-based messages at the gateway, or copy them into the current carriers — more transformation for a stream the deployed backend's supported carrier already parses correctly

**Rejected alternative:** leave the adapter unclaimed and document the gap — it would make the AI backends a partial view of Hindsight sessions for the version the fleet actually runs

## A regex in a rendered OTTL literal is escaped at the render site

**Id:** 360869a3-b79f-4b0a-9f9b-cc2b392b99ae
**Type:** workaround
**Status:** active
**Evidence:** confirmed
**Source:** `examples/telemetry-output-views.nix`, 2026-10-09

An OTTL string literal escapes backslashes, so a regex written with `\\.` reaches the collector as `\.`. The example escapes the pattern once in Nix (`lib.escape [ "\\\\" ]`) and writes the readable regex at the call site.

**Reason:** hand-doubling the backslashes in the literal produced a silently wrong regex that still evaluated; the escaping belongs in one place where it can be read against the pattern it protects.

## Credentials may bind dormant destinations

**Id:** cc767e32-98e7-4079-a95e-de6ff746df0b
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `openspec/changes/telemetry-capability-aspects/design.md`, decisions 8 and 11, 2026-10-08

A consumer may declare a destination and bind its credential even when the corresponding telemetry realization is not selected. Dormant bindings are valid; unknown destinations, unreferenced header credentials, incompatible protocols/signals and credentials embedded in store-resident configuration still fail validation.

**Reason:** destination and credential declarations are policy data, not evidence that an exporter is active. Rejecting a dormant secret because no selected realization currently consumes it would reintroduce graph inference through validation and force configuration to be staged in lockstep with aspect selection. Validation instead checks declared destination/header relationships, while the lane determines whether a renderer materializes the destination's exporter, secret file, headers or pipelines.

**Rejected alternative:** require a separate "credential consumed" marker or require the destination to be active before accepting a binding. Both duplicate exporter selection and reject a safe declaration that is intentionally dormant.

## A route is a listener-bound stream with its own destination policy

**Id:** 77b08223-5f02-42a5-9b06-67ae2b40814a
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `openspec/changes/telemetry-stream-routing/design.md`, 2026-10-08

`services.telemetry.routes.<route>` declares the signals a route accepts, its own per-signal destination selection and the ingress listener that carries it. The general route keeps the top-level `pipelines` and the existing `otlp.ingress`; a route inherits nothing from it.
**Reason:** Traces used to fan out to every resolved destination, so an AI-observability backend received general infrastructure traces and diagnostic probes. Isolation has to be stated where the data enters, because the sender is the party that knows which audience a trace belongs to. Absence of inheritance is deliberate: if a route inherited the general policy, naming an AI backend would silently make the general store a destination of the AI route. Route selection is the listener a producer sends to; span names and resource attributes describe telemetry and never classify it.

**Rejected alternative:** one pipeline with a routing processor splitting records by attribute — queue and retry state stay shared per destination, so two audiences sharing a destination interleave in one queue and route identity is re-derived from record content instead of from where the record entered

**Rejected alternative:** replacing the top-level pipelines with `routes.general` — it rewrites a surface that already states the general case correctly, with no behavioural gain

## Route isolation is per exporter instance, not per pipeline

**Id:** 0202f481-a6aa-4ac3-a7c7-994f57801382
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `openspec/changes/telemetry-stream-routing/design.md`, `modules/telemetry/otel-collector.nix`, 2026-10-08

Each route gets its own receiver, its own pipeline names and its own exporter instance per destination (`<protocol>/route-<route>-<destination>`). The general route keeps `<protocol>/<destination>`.
**Reason:** A sending queue is per exporter component. Sharing one exporter between two routes would put both audiences in one queue, so one backend's outage would hold the other audience's data behind it and a retry burst could deliver records that route never selected for that destination. Separate instances scope an outage to the route and destination that experienced it.

**Rejected alternative:** one exporter per destination behind a router — it shares the queue the isolation depends on

## The route-isolation check runs the pinned collector against mock backends

**Id:** 98b97ef5-dcb9-4a0a-a775-4f40ae4af5a0
**Type:** decision
**Status:** superseded
**Evidence:** confirmed
**Source:** `tests/telemetry/route_check.py`, `modules/flake/fixture.nix`, 2026-10-08

Route isolation is verified at runtime: the pinned collector runs a rendered two-route config with a 1 s pipeline batch processor against two local mock backends, posting traces to each listener and asserting absence at the other backend through a bounded settle window. The check is named `telemetry-route-isolation`.

**Superseded by:** none — the runtime check is removed, and `tests/telemetry/route_check.py` with it. The fleet-owned half of its claim, that a route renders its own receiver, exporter and pipeline, is pinned at evaluation by the `telemetry-routes` leaf; end-to-end isolation on a running collector is an accepted gap. See `context/check-surface-trim.md`.
**Reason:** Evaluation proves what the pipelines contain; only a running collector proves that a record entering one listener cannot leave through another route's exporter, which is the guarantee consumers are being asked to rely on. The harness enables a batch processor because production renders none by default, so the boundary is exercised through a real batch window rather than only per-item delivery. The name avoids `telemetry-routes`, which is a contract leaf: `contractChecks // { ... }` would have shadowed the leaf silently, and two checks claiming one name evaluate to one of them with no error.

## Routing is not admission

**Id:** 8fd5ee58-ad30-4d8b-8e7a-e81afc636c89
**Type:** constraint
**Status:** active
**Evidence:** confirmed
**Source:** user directive, 2026-10-08

Route selection is routing only. The contract adds no authentication, authorization, credential or enrollment mechanism to a route listener, and a consumer still owns any admission in front of its listeners. A host must not describe a route as authenticated or enrolled, and sender span attributes or an absent credential must never be treated as admission. Authenticated enrollment for specialized routes is a separate, still-unimplemented change.
**Reason:** The requirement is audience-aware routing: only explicitly AI-related telemetry reaches the AI backends. Who may select a route is an independent problem, and carrying an implied authentication promise would make a plain listener read as an access boundary. Descriptive telemetry content is not authorization either.

## A realization owns its own listener's health registration

**Id:** 7d9e94c8-aa8a-4411-9cd7-fdea8dd333cd
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** feedback from a consumer migration, 2026-10-08

`vmagent-health` (`:8429`), `vector-health` (`:9598`) and `otel-collector-health` are plain values registered by the realization that binds the listener. A host that registered one of those jobs itself under the older single-aspect composition must drop its own definition; two definitions of one job name conflict rather than merge, and `lib.mkForce` is the deliberate override.
**Reason:** One value feeds both the listener argument and the registration, so the bound port and the scraped target cannot drift apart. A defaults-merge would let a host silently repoint the health scrape away from the listener the provider bound, which is the drift ownership exists to prevent.

## The output-view runtime check keeps only the artifacts this repo authors

**Id:** 7a2c9e51-4d38-4f6b-8e21-5c9b0a3f7d64
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** check-surface trim, `modules/telemetry/output-view-checks.nix`, `tests/telemetry/output_views_check.py`, 2026-10-09

`telemetry-output-view-projection` (renamed from `…-isolation`) runs the pinned
Collector against local mock backends and asserts what the rendered configuration
cannot: one mixed trace arrives whole in the lean view with parents, timing,
status and resource identity intact and none of the five content markers, arrives
in the rich view with those markers and the canonical message carriers, and the
Latitude bridge obeys its precedence rule — canonical carriers untouched, no
legacy carrier added beside them, the producer's own legacy keys preserved, and
system instructions supplied whenever the span lacks them. Everything else it
used to assert — one receiver feeding two pipelines, an unavailable rich
destination not diverting the lean branch, listener isolation — is readable from
rendered config and is now asserted at evaluation, including each view
pipeline's exporter membership as a set equality.

**Reason:** a syntactically valid but semantically wrong OTTL regex passes both
evaluation and `otelcol validate`, because the failure is in what a statement
does with a record, not whether the config loads. That is not hypothetical: a
hand-doubled backslash produced exactly that during this work. The remaining
phases are the ones where a runtime observation is the only evidence we can have;
the deleted ones were Collector plumbing that evaluation states directly.

**Rejected alternative:** keep the plumbing phases for confidence. They cost a
second and third mock backend apiece and re-prove upstream behaviour, which is
what the trim removes.

**Rejected alternative:** delete the runtime check entirely and accept the
projection as covered by evaluation. That would leave the regex class uncovered,
which is the class that has actually failed here.

## The parser-probe artifact is written and asserted non-empty

**Id:** e41b7c08-9d25-4a63-b5f7-8c02d9e6143a
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** check-surface trim, `tests/telemetry/output_views_check.py`, 2026-10-09

The runtime check still emits the attribute artifact the pinned Latitude probe
consumes, and the derivation fails if it is missing or empty.

**Reason:** the 0.3.118 compatibility claim — that Latitude parses our carrier
through the deprecated `gen_ai.prompt`/`gen_ai.completion` pair — is only
re-derivable while something still writes the attributes it reads. Losing that
file would not fail anything; the probe would simply stop meaning anything, and
the claim would decay into point-in-time evidence. One file write in a phase that
already runs the Collector buys the difference.
