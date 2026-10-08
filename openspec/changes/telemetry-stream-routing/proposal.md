# Proposal

## Why

The gateway currently fans every received trace out to the same configured destinations. That mixes ordinary infrastructure and application traces with AI-session traces in specialized AI observability backends such as Langfuse and Latitude. Routing must distinguish telemetry by an explicit producer-declared stream or route, so general traces reach only general stores while explicitly AI-related session telemetry reaches its intended destinations without fragmenting the session.

## What Changes

- Add an explicit way for a producer/ingress stream to select a named trace-routing policy, independent of the set of configured destinations.
- Define destination policy separately for general telemetry and explicitly AI-related telemetry. General telemetry must not reach specialized AI destinations unless a policy explicitly routes it there.
- Preserve stream identity and routing through batching, retry, and fan-out so mixed traffic cannot cross routes and complete agent/tool/LLM sessions stay together.
- Keep existing general producers working without requiring an AI route declaration.
- Keep backend credentials at the gateway; route classification itself is not an authorization feature.
- Treat sender authentication/authorization, SDK instrumentation, span transformation, and consumer deployment changes as out of scope for this contract change.

## Capabilities

### New Capabilities

- `telemetry-stream-routing`: Explicit stream classification and destination routing for general and specialized telemetry consumers.

### Modified Capabilities

- `otlp-forwarding`: OTLP gateways distinguish explicit trace routes and apply route-specific destination policies rather than applying one undifferentiated trace fan-out to every ingress stream.

## Impact

- Changes the host-local OTLP forwarding contract and the gateway's route/pipeline configuration model.
- Requires consumer policy to define the general and AI-session destinations and bind the intended producer stream to the AI-session route.
- Requires verification that the route boundary survives receiver handling, batching, queueing, retries, and independent destination failures. No receiver count, port layout, or authentication mechanism is prescribed here.
