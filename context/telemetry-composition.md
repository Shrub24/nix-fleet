# Telemetry composition

## Capability presence is declared by the selected lane

**Id:** 4479ca81-13bc-4cdb-a729-970b6767f5d9
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `openspec/changes/telemetry-capability-aspects/design.md`, decisions 4, 6 and 11, 2026-10-08

Telemetry and notification registrations are dormant declarations. They describe producers, destinations and credentials; they do not infer that a runtime capability exists or should be enabled. Selecting a signal lane composes the realization that delivers that signal.

**Reason:** Nix's module graph expresses dependencies through `imports`. Reading merged configuration to infer which sibling aspects were selected reconstructs that graph indirectly and creates an orphan guard whose logic can diverge from actual composition. The selected lane is the explicit host statement: while composed, its contract is guaranteed to be delivered. A producer registration with no lane is dormant, which means the host has said not to ship it. Shared exporter/credential rendering remains a value-level concern and is declared through a narrow internal option, not an enablement marker.

The prior guarantee that registrations are never silently dropped is narrowed to: **a registration is never silently dropped while its lane is composed**. Host-policy assertions that particular machines select required lanes belong in consumer inventories, where the host policy lives.

**Rejected alternative:** inspect registrations or destination bindings to decide that a lane must be active, or to fail when a registration has no selected realization. That turns data into inferred capability state and makes valid dormant declarations impossible.

**Rejected alternative:** make the telemetry vocabulary a hard import dependency of every producer. A host must be able to compose a producer for local consumption, or provision it before adding a signal lane, without also selecting telemetry.

## Credentials may bind dormant destinations

**Id:** cc767e32-98e7-4079-a95e-de6ff746df0b
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `openspec/changes/telemetry-capability-aspects/design.md`, decisions 8 and 11, 2026-10-08

A consumer may declare a destination and bind its credential even when the corresponding telemetry realization is not selected. Dormant bindings are valid; unknown destinations, unreferenced header credentials, incompatible protocols/signals and credentials embedded in store-resident configuration still fail validation.

**Reason:** destination and credential declarations are policy data, not evidence that an exporter is active. Rejecting a dormant secret because no selected realization currently consumes it would reintroduce graph inference through validation and force configuration to be staged in lockstep with aspect selection. Validation instead checks declared destination/header relationships, while the lane determines whether a renderer materializes the destination's exporter, secret file, headers or pipelines.

**Rejected alternative:** require a separate "credential consumed" marker or require the destination to be active before accepting a binding. Both duplicate exporter selection and reject a safe declaration that is intentionally dormant.
