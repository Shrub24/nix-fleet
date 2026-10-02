# Spec Delta

## Purpose

Allow the same host-local telemetry interface to serve local trace relays and explicit receive-and-fan-out gateways without collector discovery or duplicated collection.

## ADDED Requirements

### Requirement: Explicit destination routing

An OTLP pipeline SHALL forward only to its selected destinations. A destination can be another collector or a backend without changing the producer interface; selection SHALL NOT depend on hostname, credentials being present, or discovery order.

#### Scenario: Remote relay

- **WHEN** a host's traces pipeline selects one explicitly resolved gateway destination
- **THEN** its local traces are forwarded only to that gateway and no backend credentials are required on that host

#### Scenario: Gateway fan-out

- **WHEN** a gateway's traces pipeline selects three compatible backend destinations
- **THEN** each received trace is offered to those three destinations with their own configured credentials

### Requirement: Local and additional ingress coexist

A gateway SHALL retain its local producer listener and optionally bind a separate explicitly configured network ingress listener. Configuring network ingress SHALL NOT change the local producer URLs.

#### Scenario: Gateway also serves local producers

- **WHEN** a host binds local loopback OTLP and additional tailnet ingress
- **THEN** local producers use the loopback URL and remote relays use the advertised network endpoint in one collector deployment

#### Scenario: No implicit exposure

- **WHEN** a host admits OTLP signals without declaring network ingress
- **THEN** no additional network listener or automatic firewall opening is created

### Requirement: Ingress signal and transport validation

Additional ingress SHALL use the host's admitted OTLP signals and explicitly selected HTTP and/or gRPC listeners. Invalid addresses, missing transports or listener collisions SHALL fail with named telemetry errors.

#### Scenario: Trace-only gateway rejects another signal

- **WHEN** a client submits an OTLP metrics request to a gateway admitting only traces
- **THEN** the request is rejected rather than acknowledged and discarded

#### Scenario: Conflicting listeners

- **WHEN** additional ingress declares the same address and transport port as the local listener
- **THEN** evaluation reports the listener conflict before starting the collector

### Requirement: Preserve originating resource identity

The gateway's default processing SHALL preserve incoming service and originating-host resource attributes. Local identity enrichment SHALL apply only to locally received telemetry and SHALL NOT relabel remote telemetry as gateway-local.

#### Scenario: Distinguishable hosts

- **WHEN** two relays send traces with different host identities and the gateway emits its own local traces
- **THEN** the backend retains three distinct origin identities

### Requirement: Gateway is not a universal collection hop

Adding OTLP gateway ingress SHALL NOT enable remote scraping or journald collection, or redirect metrics and journal logs through the OTLP gateway.

#### Scenario: Specialized delivery paths

- **WHEN** a host sends traces through a gateway while using local scraping and journald shipping
- **THEN** scraped metrics and journal logs continue using their separately configured store destinations

### Requirement: Explicit fleet endpoint projection

Consumers SHALL be able to resolve the remote gateway through the existing generic fleet endpoint projection. The mechanism SHALL NOT choose a gateway automatically or publish a replacement canonical address before its listener has been verified.

#### Scenario: Unavailable named endpoint

- **WHEN** a consumer resolves a nonexistent gateway service, endpoint or requested route
- **THEN** resolution fails by name without a public-route fallback or first-match collector selection

#### Scenario: Planned relocation

- **WHEN** a gateway relocation has been planned but its new listener has not been deployed and verified
- **THEN** the existing published coordinates remain unchanged

### Requirement: Network admission remains explicit policy

The gateway SHALL expose no public authenticated ingress by default. Managed-fleet network admission SHALL be consumer-owned policy; accepting a resource label SHALL NOT treat that label as authenticated host identity.

#### Scenario: Restricted fleet ingress

- **WHEN** a consumer deploys tailnet ingress
- **THEN** the consumer validates allowed and denied device access independently of the collector's local producer listener
