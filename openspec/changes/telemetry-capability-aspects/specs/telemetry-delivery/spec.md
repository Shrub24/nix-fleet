# Spec Delta

## Purpose

State how an active realization exposes delivery health and that its collection follows the metrics realization the host composes.

## MODIFIED Requirements

### Requirement: Delivery health is observable

Each active realization SHALL expose queue utilization, capacity, enqueue failures and export failures through an explicitly configured loopback listener, and SHALL publish that source as a telemetry registration. Each realization SHALL own its unit-failure registration and SHALL NOT open a public management port. Collection of a published health source SHALL follow the metrics realization the host composes and SHALL NOT depend on the publishing realization activating one.

#### Scenario: Queue pressure

- **WHEN** a realization accumulates a backlog
- **THEN** its queue utilization and configured capacity can be inspected through its loopback metrics endpoint

#### Scenario: No OTel work

- **WHEN** a host composes no OTel realization
- **THEN** no OTel operational listener or unit-failure registration is created
