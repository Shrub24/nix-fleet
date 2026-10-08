# telemetry-composition Specification

## Purpose

Define how telemetry capabilities are selected and composed: one shared vocabulary, signal lanes that a host selects explicitly, realizations that carry one signal each, and registrations that remain dormant data until a realization is composed.

## ADDED Requirements

### Requirement: The telemetry contract is vocabulary, not runtime

The system SHALL expose the telemetry option tree as a shared vocabulary that declares types and validation only. Composing the contract SHALL NOT start a provider, listener or unit.

#### Scenario: Contract without a realization

- **WHEN** a host composes the contract and binds a destination
- **THEN** evaluation succeeds, no provider service or listener is created, and the unused destination is not a failure

#### Scenario: Contract alongside a realization

- **WHEN** a host composes the contract, a producer aspect and one lane realization
- **THEN** the contract contributes no runtime of its own while the realization carries the producer's registration

### Requirement: Capability selection determines what runs

The system SHALL start a realization only because its aspect is composed. No part of the contract SHALL infer a capability from destination, pipeline or registration state.

#### Scenario: Logs-only host

- **WHEN** a host composes the log lane and no metrics lane
- **THEN** the log shipper runs and no scrape provider, OTLP listener or metrics-forwarding exporter is created

#### Scenario: Metrics destination without a metrics lane

- **WHEN** a host binds a metrics destination and composes no metrics realization
- **THEN** evaluation succeeds and no scrape provider starts

#### Scenario: Published health without a metrics lane

- **WHEN** a host composes the log lane and no metrics realization
- **THEN** the log shipper exposes its loopback health listener, publishes the source for any metrics realization composed later, and no scrape provider starts

### Requirement: One realization per signal

Each input capability SHALL have at most one realization on a host. Composing two different scrape realizations SHALL fail with a named telemetry error. Repeated imports of the same realization SHALL be idempotent. Prometheus scraping and OTLP metrics admission are distinct inputs and SHALL be composable together.

#### Scenario: Two scrape realizations

- **WHEN** a host composes a different scrape realization alongside a lane that already composes one
- **THEN** evaluation fails with a named error instead of producing two scrapers or duplicate scrape sources

#### Scenario: Repeated realization import

- **WHEN** a host imports the same scrape realization directly and through its lane
- **THEN** one scraper runs and each pipeline and source is contributed once

#### Scenario: Scraping alongside OTLP metrics

- **WHEN** a host composes both collector realizations and admits OTLP metrics
- **THEN** one collector serves distinct `metrics/scrape` and `metrics` input pipelines with shared exporter delivery state

### Requirement: Registrations are dormant declarations

A registration SHALL remain valid fixed-point data whether or not a realization consumes it. Evaluation SHALL NOT fail solely because a registration has no consumer, and no registration SHALL activate a realization.

#### Scenario: Producer without a consumer

- **WHEN** a producer registers a scrape source and the host composes no metrics realization
- **THEN** evaluation succeeds and no provider starts

#### Scenario: Consumed registration

- **WHEN** the host also composes a metrics realization
- **THEN** that realization carries the registered source without a change to the registration shape

### Requirement: Producers declare the vocabulary, not a capability

A producer aspect SHALL depend on the telemetry vocabulary only. Registering a source SHALL NOT compose a realization, imply one, or require one to exist.

#### Scenario: Producer composed alone

- **WHEN** a host composes a producer aspect that registers a scrape source and composes no telemetry lane
- **THEN** the host evaluates, and the registration remains available to any realization composed later

### Requirement: Guarantees are delivered by composition

A lane aspect SHALL compose everything needed to carry its signal, and SHALL select the fleet's default realization for that signal rather than leaving the choice to the host. Overriding the default SHALL require composing a realization explicitly.

#### Scenario: Lane composition is the guarantee

- **WHEN** a host composes the log lane and supplies its sink
- **THEN** the signal is carried without the host composing an implementation aspect

#### Scenario: Host overrides the default

- **WHEN** a host composes a scrape realization instead of the metrics lane
- **THEN** the composed realization carries scrape work and the lane's default realization is not additionally composed
