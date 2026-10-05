# telemetry-collection Specification

## Purpose

Define a host-local telemetry interface that admits sources explicitly and runs only the providers needed to carry their data.

## Requirements

### Requirement: One host-local producer interface

The system SHALL expose one public telemetry aspect. Producers SHALL register scrape sources, opt into journald shipping, or consume local OTLP URLs without naming the collector implementation or remote backends.

#### Scenario: Existing scrape registration

- **WHEN** a host selects telemetry and declares a scrape source and a supported metrics destination
- **THEN** the selected scrape provider carries the source without changes to its registration shape

#### Scenario: Independent capabilities

- **WHEN** a host declares trace ingest, local scraping and journald shipping
- **THEN** each capability is realized by its selected provider without introducing separate public provider aspects

### Requirement: Providers run only for declared work

The system SHALL start a provider only when a declared input uses that provider and has a valid destination pipeline. Provider selection or a destination declaration alone SHALL NOT start an unused provider.

#### Scenario: Metrics-only host

- **WHEN** a host registers scrape work for the default scrape provider, binds remote-write destinations and admits no OTLP signals
- **THEN** the scrape provider runs and no OTel collector, OTLP listener or OTel failure registration is created

#### Scenario: Journal-only host

- **WHEN** a host enables journald shipping with a valid sink and declares no scrape or OTLP work
- **THEN** only the journal provider runs

#### Scenario: Alternate scrape provider

- **WHEN** a host selects the OTel scrape implementation with a valid scrape source and metrics fan-out, but admits no OTLP signals
- **THEN** OTel runs its scrape pipeline without an OTLP receiver or a second scraper

### Requirement: Explicit OTLP signal admission

The host SHALL explicitly declare a unique set of signals accepted by its OTLP input. The default admitted set SHALL be empty, and each admitted signal SHALL resolve to a nonempty compatible destination pipeline.

#### Scenario: Trace-only input

- **WHEN** a host admits traces and binds a traces destination
- **THEN** its OTLP input accepts traces but does not silently accept metrics or logs

#### Scenario: Input without export

- **WHEN** a host admits traces without a valid traces destination
- **THEN** evaluation fails with a named telemetry error identifying the unserved signal

### Requirement: Local URLs promise a realized input

Reading a local OTLP URL SHALL fail with a named telemetry error unless the host selects telemetry and realizes an admitted OTLP input with a valid export pipeline. An unused destination SHALL NOT satisfy this promise.

#### Scenario: Metrics destination is not OTLP admission

- **WHEN** a scrape-only host reads its local OTLP URL
- **THEN** evaluation fails rather than advertising an unbound listener

#### Scenario: Producer outside the host evaluation

- **WHEN** a standalone Home Manager instance or a container cannot access the host's option tree or loopback
- **THEN** its endpoint requires an explicit consumer binding rather than an invented cross-class realization

### Requirement: Invalid sources and fan-out fail closed

The system SHALL reject orphan registrations, unknown selected destinations, signal/protocol mismatches and fan-out unsupported by the chosen provider with named telemetry errors.

#### Scenario: No selected aspect

- **WHEN** a producer registers a scrape source without the host selecting telemetry
- **THEN** evaluation reports the named orphan source instead of silently dropping it

#### Scenario: Unsupported scrape fan-out

- **WHEN** the remote-write scrape provider is asked to send scraped metrics to an OTLP-only destination
- **THEN** evaluation names the unsupported destination instead of filtering it from fan-out

### Requirement: Provider-bound credentials

Each provider SHALL bind only credentials referenced by its active exporters. Unknown or unbound referenced credentials SHALL fail closed, and credentials SHALL NOT appear in store-resident configuration.

#### Scenario: Unused backend credential

- **WHEN** an active provider's pipelines do not select a declared destination containing a secret-backed header
- **THEN** that provider renders neither its exporter nor its secret binding
