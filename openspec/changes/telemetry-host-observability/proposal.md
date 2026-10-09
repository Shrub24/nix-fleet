# Proposal

## Why

Host telemetry lacks a common origin identity across metrics, logs and traces, and structured journal messages do not expose their trace context as normalized fields. Existing producer aspects also leave inexpensive systemd, disk, Tailscale and container coverage uncollected.

## What Changes

- Add `services.telemetry.identity.hostName` (defaulting to `networking.hostName`) and optional `environment`; project them into local OTLP resources, scrape labels and journal fields without changing forwarded origin identity.
- Normalize supported structured journal trace/span IDs before buffering, retaining journal metadata and preserving records when parsing fails.
- Enable node-exporter's systemd collector in the existing node-exporter aspect; add selectable SMART, Podman and process-exporter producer aspects and register Tailscale's existing daemon metrics from the Tailscale aspect.
- Temporarily vendor the package and module adaptation from nixpkgs PR #507097 at an exact revision. Use its remote-mode/socket integration explicitly, with replacement once the fleet's nixpkgs pin includes the merged implementation.
- Keep process selection, disk policy, container labels, environment values, destinations and deployment placement consumer-owned.
- Add narrowly scoped checks for authored rendering, normalization and producer wiring rather than upstream exporter internals.

## Capabilities

### New Capabilities

- `telemetry-identity`: shared host/environment identity, native signal projections, precedence and origin preservation.
- `telemetry-log-correlation`: validated trace/span context normalization from journal fields and structured messages.
- `telemetry-host-exporters`: composition-selected systemd, SMART, Tailscale, Podman and process metrics producers.

### Modified Capabilities

None. Existing dormant-registration and originating-resource-preservation requirements remain in force; the new capabilities specialize them without changing audience routing or realization selection.

## Impact

- `lib/telemetry-contract.nix`, collector resource rendering, both scrape realizations and Vector journal processing.
- Existing node-exporter/Tailscale aspects; new producer modules and temporary Podman package/module helper outside auto-discovered `modules/`.
- Contract documentation, focused feature-owned checks and upstream-source provenance.
- Added host/environment fields and systemd series change observable telemetry schemas; existing options and audience routes remain supported. Historical data is not rewritten.
- Consumer migration is a separate handoff: derive host overrides from fleet inventory, choose environment and producer policy, and configure backend correlation links.

## Non-goals

SNMP/blackbox probing, profiling, eBPF instrumentation, metrics exemplars, trace sampling, arbitrary text/JSON field extraction, rootless Podman user services, backend dashboards and production deployment are deferred. The unrelated output-view helper scope correction is not part of this change.
