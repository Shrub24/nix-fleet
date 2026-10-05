# Proposal

## Why

The host-local telemetry interface already separates producers from collector implementations, but any destination currently starts OTel and its trace pipeline has no persistent delivery queue. We need minimal local trace relays and a receive-and-fan-out gateway, without distributing backend credentials or running every collector on every host.

## What Changes

- Retain one public `telemetry` aspect and the `services.telemetry` producer interface; activate providers only for declared work they can serve.
- **BREAKING:** require explicit OTLP signal admission, with no admitted signals by default. OTLP producers continue reading the same local URLs, but hosts must declare the signals their receiver accepts. Metrics destinations alone no longer start OTel or advertise an OTLP receiver.
- Add an optional, explicitly bound additional OTLP ingress listener. **BREAKING:** the existing producer listener becomes loopback-only; gateway bindings move to additional ingress, and `resourceAttributes` enrichment applies only to local inputs rather than relabeling forwarded data. No `agent`/`gateway` role switch is introduced.
- Realize explicit OTLP destinations as relay upstreams or backend fan-out, using the same adapter at both ends. Render only the exporters, credentials and pipelines the selected provider actually uses.
- Give OTel exporters persistent, bounded queues, deliberate retry/overflow behaviour and loopback operational metrics. Preserve originating resource identity across the gateway.
- Keep vmagent scraping and Vector journald shipping direct to their respective stores; neither is routed through OTel merely because a traces gateway exists.
- Bring telemetry implementation contributors into the repository's sibling flake-parts pattern, without adding public provider aspects or recreating upstream configuration surfaces.
- Document coordinated adoption: home-forge hosts the traces gateway and trace backends; agents resolve its explicit endpoint through `lib.serviceEndpoints`; network admission uses consumer-owned Tailscale policy. Deployment, backend relocation and credentials remain consumer work.

## Capabilities

### New Capabilities

- `telemetry-collection`: host-local source admission, capability-driven provider activation and implementation-neutral producer interfaces.
- `otlp-forwarding`: explicit local relay and gateway routing, separate local/network listeners, signal admission and resource-identity preservation.
- `telemetry-delivery`: persistent bounded OTel export, restart recovery, independent fan-out queues and delivery-health visibility.

### Modified Capabilities

None. The project has no existing OpenSpec capability specs; these establish requirements for the affected behaviour rather than replacing a parallel specification.

## Impact

- Affects `modules/telemetry/`, the reusable registration fragment, `modules/observability/node-exporter.nix`, `modules/flake/fixture.nix`, telemetry checks and contract documentation.
- Keeps nixpkgs' `services.opentelemetry-collector`, `services.vmagent` and `services.vector` as the realization surfaces. The initial OTLP implementation remains Collector Contrib; no Alloy implementation, custom distribution, Kafka, HA cluster or collector discovery is added.
- Consumers must explicitly admit OTLP signals before using local URLs. Existing scrape/journald registrations and destination/pipeline bindings retain their shape.
- The working-tree service inventory currently advertises `otel-collector.otlp` on OCI. Publishing home-forge coordinates must follow verified consumer deployment, not precede it. This change does not move consumer services, edit secrets or alter live Tailscale policy.
