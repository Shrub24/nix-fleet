# Proposal

## Why

A mixed application such as Hindsight emits useful lifecycle spans and content-bearing LLM spans through one OTLP exporter. The same received trace should reach the operational store without prompt, query or tool payloads, and the explicitly selected AI backends with their richer content, without splitting its causal structure or introducing retrospective trace selection.

## What Changes

- Document and verify native Collector composition of separate output pipelines from one explicitly selected route receiver: a lean operational view and rich AI views.
- Keep the existing route API. Declare destinations there so the fleet renders credentials and isolated exporter queues; use native Collector settings to partition those exporters into effective output pipelines.
- Add a checked example and runtime coverage for structural preservation, content removal, rich-view independence, and route isolation. Verify a narrowly scoped inference-event-to-attribute adapter for Latitude's pinned ingestion format.
- State that native pipeline overrides, not the declaration alone, determine effective routing. The checked composition must still offer every received span to every declared destination exactly once through its assigned view.
- Keep output policy downstream. Homelab owns gateway composition and Hindsight's endpoint binding; nix-fleet owns the documented composition seam and its regression checks.
- Do not add route enablement inference, a processing DSL, tail sampling, semantic audience classification, or automatic AI fanout from the general route.

## Capabilities

### New Capabilities

- `telemetry-output-views`: Native composition of destination-specific trace representations while preserving span structure, explicit route boundaries and destination-scoped delivery state.

### Modified Capabilities

- `telemetry-stream-routing`: Clarify that explicitly selected destinations may receive different payload representations of the full received stream, and that native overrides make the rendered pipelines the effective routing policy.

## Impact

- `docs/contracts/telemetry.md`, a checked native Nix composition example, `tests/telemetry/`, and the registered telemetry fixture checks.
- No new `services.telemetry` or `services.otel-collector` options, no new mandatory listener, and no default behaviour change.
- The example uses the existing `services.opentelemetry-collector.settings` seam. Production renderer changes are not planned; a discovered blocker must be reported rather than worked around by a new API.
- Deployment, backend retention and producer enrollment remain consumer work. Latitude interpretation needs a pinned backend parser check; Collector delivery to mock endpoints alone does not prove its UI interpretation.
