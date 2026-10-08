# Proposal

## Why

The telemetry contract and every telemetry realization are fused into one selectable aspect. Because that single aspect contains all three signal lanes, it must work out which lanes to run from configuration values: `providers.*` select an implementation, `mkIf active` predicates read destinations and registrations, `services.telemetry.realized` records that the aspect was selected, and an orphan guard rejects registrations whose consumer is absent. That is a dependency graph reconstructed from data, and it is where the open review friction comes from — a destination declaration that starts a provider, and a provider-owned health registration that cannot express "the puller runs because it was composed" without either self-starting or needing a marker to exclude itself. If something is a dependency, Nix already has a way to declare it: compose it.

## What Changes

- **BREAKING** `flake.modules.nixos.telemetry` narrows to the contract: the `services.telemetry.*` vocabulary plus value validation, with no runtime.
- **BREAKING** Signal lanes become selectable aspects — `telemetry-metrics`, `telemetry-logs`, `telemetry-otlp` — each composing the contract and the realization that carries its signal.
- **BREAKING** Realizations become aspects of their own: `telemetry-vmagent`, `telemetry-vector`, `telemetry-otel-collector-scrape`, and `telemetry-otel-collector-otlp`.
- **BREAKING** `services.telemetry.providers.*` is removed. A lane composes one realization, so implementation choice stays inside the lane and a host still never names an implementation.
- Registrations become dormant declarations: a scrape or event registration is fixed-point data that neither activates a realization nor fails when none is composed. The orphan-registration error, `services.telemetry.realized` and the activation predicates it fed are deleted.
- Guarantees move to composition. Composing a lane is what makes a signal ship; the fleet owns the default realization inside each lane, and overriding it means composing a realization explicitly.
- Delivery health: each active realization exposes its loopback health listener and publishes that source as a registration. Collection follows the composed metrics realization. No provider writes an activation for another provider.
- Value validation is kept: unknown selected destinations, signal and protocol mismatches, fan-out the composed realization cannot perform, unbound credentials, admitted signals without a valid pipeline, and missing sink endpoints.
- Notify adopts the same posture without additions: registrations stay inert declarations, and the claim that contributing aspects require the notify aspect is corrected in the header and the contract docs.

## Capabilities

### New Capabilities

- `telemetry-composition`: how telemetry capabilities are selected and composed — contract as vocabulary, signal lanes, realizations, one realization per signal, dormant registrations, and guarantees delivered by composition.

### Modified Capabilities

- `telemetry-collection`: the producer interface becomes a selected capability, provider activation is replaced, and orphan-registration rejection is removed.
- `telemetry-delivery`: delivery health states how a realization exposes and publishes its health, and that collection follows composition.

## Impact

Affected: `modules/telemetry/*`, `lib/telemetry-contract.nix`, `docs/contracts/telemetry.md`, `docs/contracts/observability.md`, the README aspect list, the fixture's capability matrix, and consumer composition in `nix-homelab` and `.dotfiles/nix`.

Hosts that compose the lanes they use behave as they do today; the change is in how capabilities are selected and in what fails closed. Evidence that motivated it: `modules/telemetry/otel-collector.nix:89` states that a destination is never evidence that an input exists, while the scrape provider's activation reads the destination and the puller's own registration; `openspec/specs/telemetry-collection/spec.md:23` freezes the inference as a requirement.

Not in scope: renaming the `services.telemetry.*` option tree, per-lane policy knobs beyond selection, journal replay or boot-scope policy, delivery-recovery VM tests, notify's dispatch semantics, and the journald `includeAll` / `current_boot_only` slice already implemented in the working tree.
