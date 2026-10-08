# Design

## Context

See `proposal.md` for the routing problem and intended outcome. The existing `otlp-forwarding` contract models one trace pipeline fan-out for the host's admitted OTLP traces and separately models local and network ingress. This change adds audience-specific routing without introducing producer-side backend knowledge or attributing route authority to arbitrary span/resource attributes.

## Goals / Non-Goals

**Goals:**

- Make general and explicitly AI-session streams independently routable through declared destination policy.
- Preserve stream/session boundaries across the gateway's receive, processing, persistence and delivery path.
- Keep the general producer path compatible and avoid requiring unrelated senders to understand AI backends.
- Keep the API about routing intent and observable behavior, leaving concrete NixOS wiring to the implementation phase.

**Non-Goals:**

- Authenticate or authorize a producer's choice of stream.
- Instrument SDKs, add AI semantic transformations, redact or rewrite span content.
- Prescribe a second listener, port, receiver component, protocol extension, or particular Collector configuration before validating candidates.
- Move specialized backend credentials out of the gateway or change consumer deployment policy in this planning change.

## Decisions

### Classify at a declared stream boundary

Represent the routing choice as an explicit stream/route declaration associated with the producer's trace stream or ingress path. The general path remains the default for existing producers; specialized AI routing requires explicit selection. Destination presence, span names, attributes, host identity, and credential availability do not infer the route.

**Alternatives considered:** Attribute-based filtering was rejected because attributes are descriptive telemetry data, can be absent or misleading, and per-span filtering can split an AI session. Destination-driven classification was rejected because merely configuring a backend would silently broaden its audience.

### Give each stream its own explicit destination policy

Resolve each declared stream to its own destination list. General routes target general observability destinations. An AI-session route targets its selected AI backends and includes a general store only if its own policy names one; no destinations are inherited implicitly across routes.

**Alternatives considered:** A global fan-out with deny rules was rejected because new specialized destinations could capture general data by default and policy becomes harder to audit. Implicitly copying AI traces to general storage was rejected because retention and audience are policy decisions, not routing defaults.

### Preserve route identity for the full delivery lifecycle

The implementation must retain routing identity when it batches, persists, retries or independently fans out telemetry. The implementation phase must choose a Collector-compatible mechanism that does not mix differently routed records into a batch whose exporters would deliver them to the same destination set. Export queues and retries remain scoped to the route and selected destination so one backend outage cannot redirect data across audiences.

**Alternatives considered:** Classifying only at initial receive and then merging all records into the existing shared trace pipeline was rejected because downstream processors and exporters would lose the distinction. Separate receivers or ports are possible mechanisms, not contract requirements; choose among them only after validating behavior and operational consequences.

### Keep routing distinct from authorization

The route is an explicit routing input, not proof of producer identity or permission. This change neither adds nor promises authentication. If a later threat model requires restricting who can choose a specialized route, that belongs in a separately scoped admission/security decision.

**Alternatives considered:** Treating route names or telemetry attributes as credentials was rejected because neither authenticates a sender. Adding auth here was rejected by scope: the user confirmed the problem is routing, not authorization.

## Risks / Trade-offs

- **[Risk] Route separation may require receiver or pipeline changes that alter the current gateway surface** → Compare candidates against existing local/network ingress behavior and keep the receiver/port choice out of the contract until tests demonstrate it is necessary.
- **[Risk] Mixed-stream batching or retry could leak general traces to specialized backends** → Add integration coverage with interleaved streams, batch flushes, partial fan-out failures, retries and restart recovery; inspect destination contents, not just generated configuration.
- **[Risk] A producer may omit explicit AI routing and its session remains general** → Preserve general behavior by default and document that AI-specific delivery requires an explicit producer/consumer binding; do not guess from content.
- **[Risk] Routing one session across several independent destination queues can produce partial delivery and duplicates** → Preserve existing bounded, per-destination delivery semantics and document that routes are not atomic transactions.
- **[Risk] Route separation is mistaken for access control** → State plainly in the API and consumer docs that route selection offers no authentication or authorization guarantee.

## Migration Plan

1. Keep existing producers and destinations on the current general route while adding explicit stream policy.
2. Configure the gateway's general destination set and verify existing producers continue to arrive there and nowhere specialized.
3. Bind the AI producer/session stream to the AI route and configure its specialized destinations explicitly; include the general store only if desired.
4. Verify complete sessions, route isolation, partial failures, retries and restart behavior before enabling specialized delivery in the consumer deployment.
5. Roll back by removing the AI route binding and returning that producer to the general route; preserve general destination policy and queues. No automatic fallback from a failed or missing AI route to specialized backends is permitted.
