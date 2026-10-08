# telemetry-delivery Specification

## Purpose

Provide bounded persistent OTLP export with observable failure behaviour across relay outages, collector restarts and independently unavailable backend destinations.

## Requirements

### Requirement: Persistent export by default

Active OTel exporters SHALL use persistent queues by default under managed service state. Successfully queued telemetry SHALL survive a collector process restart with unchanged exporter identity and storage, subject to storage failure and documented recovery limits.

#### Scenario: Relay restart during outage

- **WHEN** a relay successfully queues uniquely identified traces while its gateway is unavailable, then restarts before the gateway recovers
- **THEN** those traces are delivered after recovery without relying on producer retransmission

### Requirement: Acknowledgement does not depend on a volatile batch

The default pipeline SHALL NOT acknowledge successful acceptance solely into a volatile batching stage before its persistent export queue. An inability to queue a request SHALL produce a failure instead of a success indicating durable acceptance.

#### Scenario: Abrupt process termination

- **WHEN** a client receives successful acceptance while downstream export is blocked and the collector is immediately killed
- **THEN** the accepted trace remains available after restart within the documented persistent-queue guarantees

### Requirement: Explicit queue capacity and retry policy

Each exporter SHALL have an explicit finite queue capacity, documented sizing units and overflow behaviour. Retryable downstream failures SHALL NOT expire merely because the default five-minute retry interval elapsed; exhausted capacity, permanent rejection and storage failures SHALL remain visible failure cases.

#### Scenario: Outage longer than the upstream retry default

- **WHEN** downstream remains unavailable beyond five minutes and storage and queue capacity remain available
- **THEN** queued requests remain eligible for retry instead of expiring at that default deadline

#### Scenario: Queue exhausted

- **WHEN** a request cannot enter its export queue because capacity or storage is exhausted
- **THEN** the caller receives a failure within the documented timeout and delivery-health metrics record the enqueue failure

### Requirement: Independent fan-out delivery

Fan-out SHALL maintain independent queues and export attempts per destination. A retryable outage of one backend SHALL NOT stop healthy destinations while the failed destination's queue remains within capacity.

#### Scenario: One failed backend

- **WHEN** two destinations are healthy and the third is unavailable with available queue capacity
- **THEN** the two healthy destinations continue receiving traces while the third retains pending data for retry

### Requirement: Delivery health is observable

Each active realization SHALL expose queue utilization, capacity, enqueue failures and export failures through an explicitly configured loopback listener, and SHALL publish that source as a telemetry registration. Each realization SHALL own its unit-failure registration and SHALL NOT open a public management port. Collection of a published health source SHALL follow the metrics realization the host composes and SHALL NOT depend on the publishing realization activating one.

#### Scenario: Queue pressure

- **WHEN** a realization accumulates a backlog
- **THEN** its queue utilization and configured capacity can be inspected through its loopback metrics endpoint

#### Scenario: No OTel work

- **WHEN** a host composes no OTel realization
- **THEN** no OTel operational listener or unit-failure registration is created

### Requirement: Sensitive state and bounded guarantees

Persistent telemetry state SHALL have restrictive service-managed access. Delivery documentation SHALL state that queued content can be sensitive, redaction must precede storage when required, retries can duplicate data, and queue persistence does not provide exactly-once or lossless-forever delivery.

#### Scenario: Trace contents on disk

- **WHEN** a consumer enables full-content trace capture
- **THEN** deployment guidance identifies relay and gateway queue storage as sensitive data locations and does not claim gateway-only redaction protects relay storage

#### Scenario: Partial fan-out retry

- **WHEN** a grouped request partially reaches destinations before a failure causes retransmission
- **THEN** documentation permits duplicate delivery and does not describe fan-out as an atomic transaction
