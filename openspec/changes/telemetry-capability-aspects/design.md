# Design

## Context

Telemetry is one public aspect (`flake.modules.nixos.telemetry`) that four sibling contributors merge into: the contract and validation in `modules/telemetry/telemetry.nix`, and a realization each in `otel-collector.nix`, `vmagent.nix` and `vector.nix`. Because the aspect contains every signal lane, the realizations cannot use their own composition as evidence of what to run, and instead reconstruct that from the fixed point:

- `services.telemetry.realized` records that the aspect was selected, and `lib/telemetry-contract.nix` requires it before a registration may exist;
- `services.telemetry.providers.*` chooses an implementation, and each realization's `mkIf active` reads destinations, pipelines and registrations to decide whether it has work;
- `otel-collector.nix:89` states the principle that makes those predicates necessary — "a destination is where data goes, never evidence that an input exists";
- the delivery-health work then had no clean way to say "the puller runs because it is composed": a provider-owned registration travels through the same option the puller reads for activation, so it either self-starts or needs a marker excluding itself.

`openspec/specs/telemetry-collection/spec.md:23` freezes the result as "Providers run only for declared work". The notify aspect already uses the opposite posture for the same problem: contributions to `services.notify.events` are inert data, and no guard exists.

## Goals / Non-Goals

Goals:

- Capability selection is the only enablement mechanism for telemetry realizations.
- The contract is a vocabulary: types plus value validation, no runtime and no realization marker.
- A host's composition states which signals it ships, and a producer's registration never implies a capability.
- One realization carries one signal, with arbitration inside the lane rather than across aspects.

Non-goals:

- Renaming the `services.telemetry.*` option tree, or changing destination, pipeline or journald option shapes.
- Per-lane policy knobs beyond selection, journal replay and boot-scope policy, delivery-recovery VM tests.
- Notify's dispatch semantics; the change only aligns its documented posture.
- Backwards compatibility for `flake.modules.nixos.telemetry` consumers, `services.telemetry.providers.*`, or the orphan-registration error.

## Decisions

### 1. The contract aspect is the vocabulary, and keeps the name `telemetry`

`flake.modules.nixos.telemetry` stays the name a consumer writes, and its scope narrows to the `services.telemetry.*` declarations plus value validation. `modules/telemetry/telemetry.nix` already holds exactly that role; it loses the runtime-adjacent machinery listed in decision 4 and gains nothing else. `telemetry-contract` would be a redundant synonym in a repository whose subject is contracts.

### 2. The selectable unit is the signal lane, not the implementation

A lane aspect — `telemetry-metrics`, `telemetry-logs`, `telemetry-otlp` — composes the contract and the realization that carries that signal. Selecting a lane is the enablement, so nothing has to be inferred, and a host reads as the signals it ships:

```nix
imports = [ nixos.telemetry-logs nixos.telemetry-metrics nixos.node-exporter ];
```

The rejected alternative is naming implementations in host composition (`nixos.telemetry-vector` in every host that ships logs). It is dendritic-legal, but it puts a fleet implementation choice into consumer configuration and makes a fleet-wide swap an edit in every host. Keeping the choice inside the lane preserves the one property worth keeping from the current design: a host never names an implementation.

### 3. Realizations are per-signal aspects; the lane owns the default

`telemetry-vmagent` and `telemetry-vector` are single-signal by nature, so their names carry the signal. The collector serves two signals, so it is composed by two aspects — `telemetry-otel-collector-scrape` and `telemetry-otel-collector-otlp` — which configure one host service; a host that composes both gets one collector with both pipelines, and a host that composes one gets only that pipeline.

This is the part that makes "why am I composed" answerable from the module's identity rather than from a value. The alternative — one collector aspect taking a signal set as an option — reintroduces `providers.*`: configuration deciding what code exists.

Lane aspects reference sibling aspects at the file level, `imports = [ config.flake.modules.nixos.telemetry-vmagent ]`, which is the same lazy `flake.modules` reference hosts already use. The only cycle risk is a realization referencing a lane, which no realization does.

### 4. Registrations are dormant declarations

`services.telemetry.scrape.*`, `services.telemetry.otlp.*` admission and `services.notify.events.*` are fixed-point data. A registration does not activate a realization, does not require one to exist, and does not fail when none is composed.

Deleted with this decision: `services.telemetry.realized`, the `nothingRegistered`/orphan assertion and its message, every `mkIf` predicate that reads configuration to decide whether a capability exists, and `services.telemetry.providers.*`.

What replaces them is composition. A host that wants scrape work carried composes the metrics lane — that is the declaration, and `imports` is where Nix expects a dependency. `flake.modules.nixos.telemetry` narrows in meaning from "the telemetry runtime" to "the telemetry vocabulary", which is the honest description of what it already contributes to any host that selects it without a realization.

### 5. Producer aspects keep importing the contract definition

Producers (`node-exporter` and any service declaring a local scrape source or OTLP consumption) continue to import `lib/telemetry-contract.nix` directly. The consequence is stated plainly: the option tree exists wherever a producer is composed, so contributing to it is always legal, and no unknown-option error can occur.

The rejected alternative is making the contract aspect a hard dependency of every producer, so that a host composing a producer without the vocabulary fails with the module system's own unknown-option error. That is louder, and it was tempting, but it makes the vocabulary a capability: any host exposing a metrics port for local consumption, or provisioning a host before its telemetry lane lands, would have to compose telemetry. A producer must be composable by a host that ships nothing.

### 6. Guarantees are delivered by composition, and the promise is restated

The fleet previously promised "a registration is never silently dropped", enforced by cross-checking whether a sibling capability had been selected. Under this change the promise becomes: **a registration is never silently dropped while its lane is composed.** A host that composes `telemetry-logs` ships logs, by construction, because the bundle composes the shipper and its wiring; a host that registers a scrape source and composes no metrics lane ships nothing, and that is its composition's statement, not a defect the contract has to hunt for.

The trade is real and is accepted deliberately: the previous guarantee could catch a host whose composition was incomplete, and it did so at the cost of a contract that read configuration to reconstruct the aspect graph. Consumer-side policy checks — `nix-homelab`'s host inventory checks, `.dotfiles/nix`'s `modules/flake/telemetry-policy.nix` — remain the place for "this host should ship these signals", because that is a statement about a fleet's hosts, not about a telemetry contract.

### 7. One realization per signal, enforced inside the lane

Arbitration replaces `providers.*`. Two different realizations of the scrape input fail with a named error rather than collecting every source twice. An internal unique ownership declaration is contributed by each scraper and forced during validation; it never selects runtime or requires a scraper to exist. Repeated imports of the same realization deduplicate through stable native module identities.

Scraping and OTLP metrics admission are distinct input capabilities, not competing implementations of the same input. Both collector aspects may compose: `metrics/scrape` and `metrics` pipelines share exporter IDs and persistent delivery state.

### 8. Value validation is kept

The following remain, because they are lane-local statements about values rather than graph reconstruction:

- admitted OTLP signals without a compatible, valid destination pipeline;
- unknown selected destinations and unsupported fan-out for the composed realization (protocol and signal mismatches);
- bound credentials that no declared destination header references, and credential representation in store-resident configuration; credentials for dormant destinations remain valid declarations;
- sink endpoint presence and URL validity for journald shipping;
- listener bindings: loopback-only local receiver, explicit ingress host and transport;
- the `includeAll` whole-journal decision and the explicit `current_boot_only` render already implemented in the working tree.

### 9. Delivery health is published, not activated

Each active realization exposes its queue utilization, capacity, enqueue and export failures on its own loopback listener and publishes that source as a registration: the collector's existing metrics port, vmagent's listener, and — new here — Vector's `internal_metrics` source with a loopback `prometheus_exporter` sink. Collection follows the composed metrics realization: nothing is scraped unless a metrics realization is composed, and no realization activates one.

This resolves the review's delivery-health item without the inversion that produced the standoff: a provider publishes a fact, a composed puller consumes facts.

### 10. Notify keeps the same posture with no additions

`services.notify.events` stays inert data (decision 4). No realized marker, no enable gate, no assertion. The only work is documentary: the header in `modules/notifications/notify/_notify-events.nix` claims a registration without the notify aspect fails as an unknown option, which is false because every contributing aspect imports the fragment; and `docs/contracts/observability.md` should state that registrations are realized only where the notify aspect is composed.

### 11. Shared collector rendering is a declared module dependency

Both collector realizations import the same common-module path, so common service settings, list-valued processors, exporters and credential wiring are rendered once. Each realization contributes its receivers and pipelines. Reading the collector's own serializable settings during their rendering caused an evaluation recursion; a narrow internal `services.otel-collector.exporterDestinations` list therefore carries the selected destination names into the shared renderer. It is wiring data, never enablement.

Credential validation checks declared destination header references, not active exporters: otherwise binding a credential to a dormant destination would reconstruct a missing dependency and reject valid data. No separate consumption marker is needed. Local OTLP URLs have lazy throwing defaults; only the OTLP realization defines a usable URL, so no presence marker is needed.

## Risks / Trade-offs

- **Silent no-op.** A producer composed without its lane ships nothing and says nothing. Accepted per decision 6; the mitigation is that lanes are what hosts compose and that consumers own host policy checks. A future non-failing warning is possible but is not part of this change.
- **More names in the composition.** Three lane aspects and four realization aspects replace one name. Lanes are the names hosts need; realizations are the escape hatch for overriding a fleet default.
- **`imports` depth.** Lane bundles reference sibling aspects lazily. If a cycle appears it will be an evaluation error naming the aspects, and the fix is to move the shared wiring into the contract rather than to reintroduce a value.
- **Fixture churn.** The capability matrix is rebuilt around lane selection, and the current fixture refactor is in flight. Tasks sequence the rebuild after that work lands.
- **Consumers break by design.** `nix-homelab` and `.dotfiles/nix` change imports and drop `providers.*`; both are mid-adoption, which is why compatibility was explicitly not required.

## Migration Plan

1. Land the journald `includeAll` / `current_boot_only` slice already in the working tree; it is independent of this change.
2. Split the aspects and delete the inference machinery in one pass, so no intermediate state has a half-composed lane.
3. Rebuild the fixture capability matrix around lane selection, after the in-flight fixture refactor lands.
4. Update `docs/contracts/telemetry.md`, `docs/contracts/observability.md` and the README aspect list.
5. Migrate `nix-homelab` and `.dotfiles/nix`: `imports = [ nixos.telemetry ]` becomes the lanes the host ships, and any `providers.*` override becomes a realization import.
6. Sync the spec deltas and archive.

No data migration: destination bindings, pipelines, journald configuration and queued state are unchanged.

## Verification

- `nix fmt` clean and `nix flake check` green through the fixture evaluation class.
- Non-vacuity, mutation-style checks in the fixture: a producer composed alone evaluates and starts no provider; composing a second realization for one signal fails with the named error; the logs lane alone creates the shipper and no scrape provider; a metrics destination bound with no metrics realization starts nothing; Vector's loopback health listener exists with no scrape provider present.
- A check that the deleted machinery is gone: no `realized` marker, no orphan assertion, and no `mkIf` in `modules/telemetry/` that reads `services.telemetry.scrape`, `destinations` or `pipelines` to decide whether a realization exists.
- Consumer renders: the homelab and dotfiles host evaluations succeed with lane imports.
- Documentation matches the surface: aspect names, the composition examples, and the restated guarantee.

## References

- `openspec/specs/telemetry-collection/spec.md`, `openspec/specs/telemetry-delivery/spec.md`
- `openspec/changes/archive/2026-10-05-gateway-agent-telemetry-architecture/design.md` (the decision this change reverses)
- `modules/telemetry/otel-collector.nix`, `modules/telemetry/vmagent.nix`, `modules/telemetry/vector.nix`, `lib/telemetry-contract.nix`
- `modules/notifications/notify/_notify-events.nix`
- `.pi-herdsman/upstream-review.md` (local review scratch, not a published artifact)
