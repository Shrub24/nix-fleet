# Spec Delta

## Purpose

Define a common host and optional environment identity for locally collected telemetry without confusing origin, application, unit and transport identities.

## ADDED Requirements

### Requirement: Shared identity is inert data

The contract SHALL expose a nonempty canonical host name defaulting to the configured machine name and an optional nonempty environment. Declaring identity SHALL NOT activate any telemetry realization. Invalid explicit values SHALL fail with named telemetry errors.

#### Scenario: Vocabulary without transport

- **WHEN** a host binds identity without composing telemetry lanes
- **THEN** evaluation succeeds and no collector or shipper starts

#### Scenario: Invalid identity value

- **WHEN** a host explicitly binds an empty host name or an empty non-null environment
- **THEN** evaluation identifies the invalid identity field

### Requirement: Native projections preserve distinct meanings

Local OTLP resources SHALL carry host.name and, when bound, deployment.environment.name. Local scrape defaults SHALL carry host and environment labels; journal records SHALL carry host_name and environment fields. Projection SHALL NOT substitute host identity for service.name, job, instance or systemd unit identity.

#### Scenario: One host across signals

- **WHEN** a host binds one canonical identity and collects local traces, metrics and journal logs
- **THEN** their native host fields agree while application, scrape endpoint and unit identities remain distinct

#### Scenario: No environment binding

- **WHEN** environment is null
- **THEN** identity projection adds no environment field or label

### Requirement: Origin scope and precedence are explicit

Host enrichment SHALL apply only to local-origin inputs, not forwarded network ingress or named routes. Conflicting canonical resource configuration SHALL fail by name. Explicit scrape-source host and environment labels SHALL override local defaults for that source. Journal metadata SHALL remain intact and message payloads SHALL NOT override canonical identity.

#### Scenario: Gateway preserves remote origin

- **WHEN** a gateway receives telemetry from another host through general ingress or a named route
- **THEN** its canonical identity does not overwrite or fill the forwarded resource identity

#### Scenario: Configured resource conflict

- **WHEN** resource enrichment explicitly specifies a host identity different from the canonical local host
- **THEN** evaluation reports the conflicting configuration rather than silently selecting one

#### Scenario: Explicit source origin

- **WHEN** a scrape registration explicitly supplies a target host label
- **THEN** that source retains the explicit host label rather than the scraping machine's default

#### Scenario: Journal payload shadows metadata

- **WHEN** a message contains JSON host or unit fields contradicting the journal record
- **THEN** the original journal metadata and canonical normalized host remain unchanged
