# Tasks

## 1. Narrow the contract aspect

- [x] 1.1 Reduce `modules/telemetry/telemetry.nix` to the `services.telemetry.*` vocabulary and value validation; verify the aspect still contributes no unit, service or listener by evaluating a host that composes it with a bound destination and no realization.
- [x] 1.2 Delete `services.telemetry.realized`, the orphan/`nothingRegistered` assertion and the `providers.*` option; verify no module reads or sets them and the fixture composes without them.
- [x] 1.3 Remove every `mkIf` in `modules/telemetry/` whose condition reads destinations, pipelines or scrape registrations to decide whether a realization exists; verify with a grep sweep that the only remaining conditions are value- or option-local.
- [x] 1.4 Keep the retained validation list from design decision 8 and confirm each still fails closed by name; verify a named mutation case per retained check.

## 2. Add the lane aspects

- [x] 2.1 Add `telemetry-metrics`, `telemetry-logs` and `telemetry-otlp`, each importing the contract and the fleet default realization for its signal; verify a host composing one lane starts exactly that signal's machinery.
- [x] 2.2 Verify lane composition is the guarantee: a host composing `telemetry-logs` with a sink ships logs and starts no scrape provider, no OTLP listener and no metrics-forwarding exporter.
- [x] 2.3 Verify a host that binds a metrics destination and composes no metrics lane starts no provider and evaluates without error.

## 3. Split the realizations into per-signal aspects

- [x] 3.1 Publish `telemetry-vmagent` and `telemetry-vector` as single-signal realization aspects; verify each is composable without a lane and starts no other signal's machinery.
- [x] 3.2 Compose the collector from `telemetry-otel-collector-scrape` and `telemetry-otel-collector-otlp`; verify composing both configures one host service with both pipelines, and composing one runs only that pipeline.
- [x] 3.3 Enforce "one realization per signal" with a named error; verify composing a second realization for a signal fails with that name instead of producing two scrapers or duplicate scrape sources.
- [x] 3.4 Verify a realization composed directly (instead of its lane) carries the signal and the lane's default realization is not additionally composed.

## 4. Make registrations dormant

- [x] 4.1 Remove the failing orphan path so a registration with no composed realization evaluates and stays visible in the option tree; verify a producer composed alone evaluates and starts no provider.
- [x] 4.2 Confirm producer aspects keep importing `lib/telemetry-contract.nix` and that no producer imports a lane or realization; verify the fixture's producer-only composition.
- [x] 4.3 Confirm the consumed path is unchanged: a registration's shape does not change when a realization composes it; verify against the existing scrape-registration fixture cases.

## 5. Publish delivery health, do not activate it

- [x] 5.1 Add Vector's `internal_metrics` source and its loopback `prometheus_exporter` sink; verify the rendered config passes `vector validate --no-environment` and the listener is loopback-only.
- [x] 5.2 Publish each active realization's health source as a telemetry registration, including vmagent's and the collector's existing listeners; verify no realization activates another and that collection follows the composed metrics realization.
- [x] 5.3 Verify the journald-only composition: the shipper exposes its loopback health listener, publishes the registration, and no scrape provider starts.
- [x] 5.4 Document the pinned series for backlog, enqueue failures and export failures for each realization, verified against the pinned versions rather than assumed.

## 6. Align notify's documented posture

- [x] 6.1 Correct the header in `modules/notifications/notify/_notify-events.nix` so it states that registrations are inert declarations rather than failing when the notify aspect is absent.
- [x] 6.2 State the same posture in `docs/contracts/observability.md`; verify no guard, marker or enable gate was added for notify.

## 7. Rebuild the fixture capability matrix

- [ ] 7.1 Rebuild the fixture's telemetry compositions around lane selection, keeping the retained validation cases; verify `nix flake check` is green.
- [x] 7.2 Add the non-vacuity checks from the design's verification list: producer-only, second-realization failure, logs-lane-only, destination-without-lane, and the Vector health listener without a scrape provider.
- [x] 7.3 Sequence this section after the independent-leaf fixture refactor is integrated and its owner releases the fixture; verify no capability-matrix expectation is carried over from the pre-refactor structure. The owner approved a combined snapshot rather than a prerequisite commit.

## 8. Documentation and public surface

- [x] 8.1 Update `docs/contracts/telemetry.md` with the aspect names, a composition example per lane, and the restated guarantee (a registration is never silently dropped while its lane is composed).
- [x] 8.2 Update `docs/contracts/observability.md` and the README aspect list; verify no reference remains to `providers.*`, the realized marker or the orphan error.

## 9. Consumer migration

- [ ] 9.1 Migrate `nix-homelab`: replace `imports = [ nixos.telemetry ]` with the lanes each host ships and drop scraper selection values; verify each host evaluates.
- [ ] 9.2 Migrate `.dotfiles/nix`: same replacement, and reconcile `modules/flake/telemetry-policy.nix` so it states host policy rather than compensating for contract validation.
- [ ] 9.3 Pin the consumer updates after this change is published; verify both repositories' checks are green against the new aspect names.

## 10. Acceptance sweep

- [ ] 10.1 `nix fmt` clean and `nix flake check` green on a frozen revision.
- [x] 10.2 Verify the deleted machinery is absent: no realized marker, no orphan assertion, no activation inferred from configuration values.
- [x] 10.3 Sync the spec deltas into `openspec/specs/` and update the capability purposes that referenced provider-inferred activation.
