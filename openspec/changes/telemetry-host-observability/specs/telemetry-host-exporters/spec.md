# Spec Delta

## Purpose

Provide reusable host metrics producers with declared dependencies, local scrape surfaces and consumer-owned selection policy, without coupling producers to a metrics destination.

## ADDED Requirements

### Requirement: Producer composition owns source wiring

Selected exporter aspects SHALL compose their implementation and publish scrape registrations matching their listeners. New exporter listeners SHALL bind loopback without opening firewall ports. Registrations SHALL remain dormant without a metrics realization. Optional exporter selection SHALL NOT implicitly select metrics delivery or notification transport.

#### Scenario: Producer without scraper

- **WHEN** a host selects an exporter aspect without a metrics lane
- **THEN** the exporter is configured and its registration stays dormant

#### Scenario: Port override

- **WHEN** a consumer changes an exporter listener port
- **THEN** the registration changes with it rather than retaining a stale target

### Requirement: Systemd and Tailscale reuse existing producers

The node-exporter aspect SHALL provide systemd collector coverage without starting a second systemd exporter. The Tailscale aspect SHALL register its daemon's local metrics endpoint without enabling a tailnet web listener or requiring fleet-wide OAuth credentials. Unit filters and detailed collector policy SHALL remain consumer-configurable.

#### Scenario: Node exporter selection

- **WHEN** a host selects the node-exporter aspect
- **THEN** its existing process exposes systemd collector metrics without a separate exporter service

#### Scenario: Tailscale metrics registration

- **WHEN** a host selects the Tailscale aspect
- **THEN** its daemon metrics are registered for local collection without additional webclient exposure

### Requirement: SMART and process monitoring are explicit

SMART and process exporters SHALL be independently selectable. Disk policy and process selectors SHALL be consumer-owned. Selecting process monitoring with no configured selectors SHALL fail with a named error. Documentation SHALL state device and process-access privileges and discourage high-cardinality or content-bearing labels.

#### Scenario: Host without disk monitoring

- **WHEN** a host does not select the SMART exporter
- **THEN** no SMART exporter or raw-device privileges are added by this capability

#### Scenario: Missing process selection

- **WHEN** a host selects process monitoring with an empty selector list
- **THEN** evaluation reports the required process selection rather than monitoring every process

### Requirement: Podman exporter declares engine access

The Podman producer SHALL compose its rootful local-engine dependency and configure working socket access for its remote-mode exporter. Its metrics listener SHALL remain local, and container-label copying SHALL not be unrestricted by default. Rootless and remote-engine monitoring SHALL NOT be inferred from host configuration.

#### Scenario: Rootful Podman selection

- **WHEN** a host selects the Podman exporter aspect
- **THEN** its configured service can access the declared local engine socket and its listener matches the scrape registration

#### Scenario: Container label defaults

- **WHEN** no consumer container-label policy is supplied
- **THEN** arbitrary container labels are not copied into metric labels

### Requirement: Temporary upstream adaptation remains replaceable

The vendored Podman implementation SHALL retain exact upstream provenance. Replacing it with a merged implementation available in the fleet's nixpkgs pin SHALL preserve the fleet-facing aspect and source registration. An upstream merge alone SHALL NOT trigger removal before the pinned replacement is available and verified.

#### Scenario: PR merged before input update

- **WHEN** the upstream PR merges but the fleet's nixpkgs pin lacks its implementation
- **THEN** the vendored implementation remains usable

#### Scenario: Adopt pinned upstream implementation

- **WHEN** the pinned upstream replacement passes the engine-access and registration checks
- **THEN** consumers keep their fleet aspect selection while the temporary implementation is removed
