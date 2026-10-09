# Spec Delta

## Purpose

Allow explicitly selected telemetry streams to have destination-specific payload representations without fragmenting their received traces or changing audience routing.

## ADDED Requirements

### Requirement: Output views preserve received trace structure

A composed lean operational view and rich AI views SHALL offer every received span to their explicitly assigned destinations without selecting traces by semantic content. Each view SHALL preserve trace IDs, span IDs, parent IDs, originating resource identity, timing and status. The guarantee concerns received spans, not uninstrumented work or spans lost upstream.

#### Scenario: Mixed lifecycle and LLM trace

- **WHEN** a selected stream contains application ancestors, an LLM span and supporting operation spans
- **THEN** all views retain the received span set and causal identifiers while applying their own payload processing

#### Scenario: Ordinary-only trace on an explicitly selected stream

- **WHEN** the stream receives a trace with no LLM span
- **THEN** the same declared destinations receive it without waiting for an AI marker

#### Scenario: Late worker continuation

- **WHEN** spans continuing an earlier trace arrive in a later export request
- **THEN** each view offers those spans with unchanged causal identifiers without a trace-completion selection deadline

### Requirement: Lean content removal precedes persistent export

A documented lean profile SHALL remove the content-bearing fields named by that profile before its exporter queue stores telemetry. It SHALL retain useful operational metadata and SHALL NOT mutate the rich views. Documentation SHALL distinguish the checked profile from a universal privacy guarantee and identify upstream queues as possible rich-content storage.

#### Scenario: Hindsight content appears in multiple carriers

- **WHEN** synthetic spans contain inference-detail events, tool-call event payloads, query attributes, raw tool arguments and exception content
- **THEN** the lean output contains none of the profile's forbidden payloads, retains the checked operation metadata, and rich outputs retain their permitted content

### Requirement: Backend normalization is scoped to its output view

An explicitly configured backend adapter SHALL preserve trace structure and SHALL NOT change other output views. A supported inference-event adapter SHALL produce message attributes that the pinned backend parser interprets as the original synthetic input and output messages, without overwriting already supplied canonical message attributes.

#### Scenario: Event-based message capture

- **WHEN** a synthetic Hindsight LLM span carries messages in its inference-detail event
- **THEN** the Latitude view exposes the corresponding supported message attributes, the Langfuse view retains its original carrier, and the lean view retains neither content carrier

### Requirement: Views preserve routing and delivery isolation

Output views SHALL use only destinations explicitly selected for their input route and SHALL retain independent export queues per route and destination. The checked baseline SHALL assign each selected destination to one effective view, avoiding duplicate ingestion paths. A retryable destination outage within queue capacity SHALL NOT change another view's content or redirect general-route records to AI destinations.

#### Scenario: General input remains general

- **WHEN** general-route and explicitly selected mixed-stream traces arrive close together
- **THEN** general-route traces remain outside the mixed stream's AI destinations

#### Scenario: Rich backend outage

- **WHEN** a rich destination is unavailable and its export queue still has capacity
- **THEN** the lean destination continues receiving its processed copy and recovery delivers only the rich destination's assigned stream

### Requirement: Policy scope and effective routing are explicit

Output views SHALL remain native Collector composition. Guidance SHALL identify which incoming records each profile processes. Payload-processing attributes SHALL NOT imply audience routing or authorization. After native overrides, effective pipelines SHALL determine delivery; route declarations SHALL determine exporter and credential materialization.

#### Scenario: Shared listener carries several applications

- **WHEN** Hindsight and an AI-native producer use the same listener with unconditional lean and rich profiles
- **THEN** both receive those profiles and documentation makes no claim of Hindsight-only shaping

#### Scenario: Native pipeline override

- **WHEN** a consumer partitions a declared route's destinations into native output pipelines
- **THEN** composition checks inspect the effective receiver, processor and exporter assignments rather than treating the unmodified route declaration as proof of delivery
