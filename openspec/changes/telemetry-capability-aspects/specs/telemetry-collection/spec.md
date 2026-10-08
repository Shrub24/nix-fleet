# Spec Delta

## Purpose

Narrow the host-local producer interface to a shared vocabulary plus explicit capability selection, and drop the requirement that providers infer their own activation.

## MODIFIED Requirements

### Requirement: One host-local producer interface

The system SHALL expose one shared telemetry contract namespace. Producers SHALL register scrape sources, opt into journald shipping, or consume local OTLP URLs by declaring into that namespace, without naming the collector implementation or remote backends. Capabilities SHALL be selected by composing the lane aspects that carry them.

#### Scenario: Existing scrape registration

- **WHEN** a host composes the metrics lane and a producer registers a scrape source with a supported metrics destination
- **THEN** the composed scrape realization carries the source without changes to its registration shape

#### Scenario: Independent capabilities

- **WHEN** a host declares trace ingest, local scraping and journald shipping
- **THEN** each signal is carried by the realization composed for it, and any signal whose lane is not composed ships nothing

### Requirement: Local URLs promise a realized input

Reading a local OTLP URL SHALL fail with a named telemetry error unless the host composes the OTLP realization with an admitted signal and a valid export pipeline. An unused destination SHALL NOT satisfy this promise.

#### Scenario: Metrics destination is not OTLP admission

- **WHEN** a scrape-only host reads its local OTLP URL
- **THEN** evaluation fails rather than advertising an unbound listener

#### Scenario: Producer outside the host evaluation

- **WHEN** a standalone Home Manager instance or a container cannot access the host's option tree or loopback
- **THEN** its endpoint requires an explicit consumer binding rather than an invented cross-class realization

### Requirement: Invalid sources and fan-out fail closed

The system SHALL reject unknown selected destinations, signal and protocol mismatches, and fan-out that the composed realization cannot perform, with named telemetry errors.

#### Scenario: Unsupported scrape fan-out

- **WHEN** the composed scrape realization is asked to send scraped metrics to an OTLP-only destination
- **THEN** evaluation names the unsupported destination instead of filtering it from fan-out

#### Scenario: No selected aspect

- **WHEN** a producer registers a scrape source and the host composes no telemetry realization
- **THEN** evaluation succeeds and the registration stays dormant rather than failing as an orphan

## REMOVED Requirements

### Requirement: Providers run only for declared work

**Reason**: Activation inferred from configuration values cannot distinguish a composed capability from an incidental one, and it forced every realization to read a fixed point that a realization itself can contribute to. Selection replaces inference: a realization runs because its aspect is composed, and a host that composes a lane ships that lane.

**Migration**: Replace `imports = [ nixos.telemetry ]` with the lane aspects the host ships (`telemetry-metrics`, `telemetry-logs`, `telemetry-otlp`), and replace any `services.telemetry.providers.*` override with an explicit realization aspect import. The cases previously covered by this requirement are now covered by "Capability selection determines what runs" in the `telemetry-composition` capability, and by "One realization per signal" for arbitration.
