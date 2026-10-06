# nix-fleet plan — remaining and upcoming

Living checklist. Done items are removed, not struck through; decisions and
rationale live in README, AGENTS.md, and docs/contracts/.

## Fleet Contract v2 (decided direction — next major work unit)

Scope per owner decision: the parts of the v2 contract that the CI contract
and fleet topology depend on, functionally self-contained. The service endpoint
catalog subsequently landed; host-data harvest lands after the contract settles
(nix-dotfiles' agent can input its own records then).

- [x] **1. Realization decomposition** (PRIORITY — strong smell today):
      delete `config.fleet.realization` as an architectural API entirely.
      nix-fleet exposes facts + pure renderers; consumers close over their
      own `config.fleet` in their own flake evaluation.
  - `modules/fleet/build-account.nix` — ordinary optional NixOS aspect
    (the `nixbuild` dispatch account is MECHANISM, not policy; keep it
    shared, do not let it become consumer copy-paste). Selected like any
    aspect; `buildUserName` option unchanged.
  - activeSet/machines wiring → consumer's own ~15-line flake-level
    module (resolveBuildProfile → render → nix.settings), documented once
    in docs/contracts/builders.md. That wiring is policy, consumer-owned.
  - No cross-class realization bridge remains. This also structurally
    kills the wrong-import footgun class (no pre-realized module exists
    to mis-import).
- [x] **2. Capabilities into hosts; single builder registry**:
      `fleet.hosts.<id>.capabilities.nixBuilder = { enable; maxJobs;
supportedFeatures; endpoint.{protocol,user}; }`. Delete host-backed
      `fleet.builders.*`. `system` derives from the host record (capability
      exception only for genuine extra/emulated systems). Keep the
      dedicated `nixbuild` account as the capability endpoint default
      (least-privilege dispatch — NOT `dev`; consumer override possible).
- [x] **3. `fleet.externalBuilders.<name>`** (narrow, no entity framework):
      uri, systems, publicHostKey, metered. nixbuild moves here.
- [x] **4. `fleet.buildProfiles.<name>`** replaces builderSets:
      explicit `hosts` + `external` membership, small per-member override
      axis (maxJobs, features) allowed on BOTH variants uniformly
      (nixbuild's maxJobs is the metered-cost knob — profiles exist for
      exactly this). No weights/predicates/inheritance/tags/all-hosts.
- [x] **5. Two-stage pure resolution API**: hosts/externals + profile →
      normalized `BuilderSpec[]` (`resolveBuildProfile`), then renderers
      (`renderMachinesFile`, `renderSshConfig`, `renderKnownHosts`,
      nix.buildMachines form). Single public API; `packages.<profile>`
      CI bundles keep the same artifact shape (workflow contract
      unchanged: `builder_attr` input, v1+).
- [x] **6. Trust by projection**: `renderKnownHosts` renders exactly the
      selected hosts/resources — kills the current "inventory membership ⇒
      trusted everywhere" flaw (fixture renders all entries today).
      Pinned keys stay pinned.
- [x] **7. Mission/README rewrite**: "shared fleet control-plane contract + mechanisms"; remove the stale "no hosts, no policy data" language.
      Keep the canonical-facts vs consumer-local-placement distinction.
- [x] **8. Contract tests**: profile references exist; members have
      nixBuilder.enable; systems derive correctly; externals have
      URI+key; duplicate canonical/local IDs fail; Nix-module form ≡
      machines-file form.

Not in original v2 scope: shrub/spectre inventory records (data harvest
after the contract settles; nix-dotfiles' agent can input them itself);
Den/repo-merge/policy-engine (explicitly out).

## Cross-fleet service endpoints (completed follow-on)

- [x] Typed `fleet.services.<service>.endpoints.<endpoint>` in the single
      `flakeModules.fleet` feature, with canonical tailnet coordinates for
      omniroute, hindsight, remote docs-mcp, ntfy, niks3-write, bifrost.
- [x] Pure `lib.serviceEndpoints.resolveEndpoint` and `.url` with explicit
      route selection, named reference errors, no public fallback; raw canonical
      records exported as `.canonicalServices` for flake-level scripts.
- [x] Fleet validation + mutation checks, and docs/contracts/services.md.
      Downstream adoption and ingress/auth policy remain consumer-owned.

## Telemetry contract (host-local, completed)

- [x] ONE public aspect `flake.modules.nixos.telemetry` — the
      implementation-agnostic `services.telemetry` contract: a Prometheus
      scrape registration (`services.telemetry.scrape.<job>`), the local OTLP
      endpoint producers read (`services.telemetry.otlp.{httpUrl,grpcUrl}`),
      typed remote destinations (`services.telemetry.destinations.<name>`:
      protocol + endpoint + required non-empty `signals` + secret headers) and
      per-signal fanout (`services.telemetry.pipelines`). Selection is
      enablement. A contributing aspect imports the `telemetry/_contract.nix`
      fragment.
- [x] `signals` is authoritative, never inferred from the protocol: a null
      pipeline fans out only to destinations that accept that signal, so a
      traces-only OTLP backend (Langfuse/Latitude) never receives metrics or
      logs without every host writing override lists. A destination accepting a
      signal its protocol cannot carry is rejected eagerly (even when no
      pipeline names it), and an explicit pipeline naming a destination for a
      signal it does not accept fails closed by name.
- [x] Implementations are private modules (`telemetry/_providers/`) selected
      per capability via `services.telemetry.providers.*`, defaulting to the
      OpenTelemetry adapter. No second public aspect, no provider registry, and
      no imports-list edit to swap one.
- [x] Orphan guard: a scrape source or destination configured without the host
      aspect fails closed by name; registration is not declaration-only. The
      same guard covers push-only consumers, which register nothing: reading
      `otlp.httpUrl`/`grpcUrl` on a host that did not select the aspect throws
      instead of advertising an endpoint nothing binds.
- [x] OpenTelemetry implementation renders the contract into nixpkgs'
      collector: OTLP receiver bound to the contract endpoint, `scrape`
      rendered into the Prometheus receiver and metrics pipeline, ordered
      processors, protocol-mapped destinations, SOPS-backed header
      environment, build-time config validation, owned failure notification.
      Collector-only tuning (processors, resource attributes, package,
      exporter override) stays under `services.otel-collector`.
- [x] Removed the fleet-level `telemetry.{ingest,sink}` endpoint capabilities
      and `lib.telemetry`: they advertised collector endpoints in the flake
      catalog that no host-local registration consumed. Generic
      `fleet.services` endpoint facts + `lib.serviceEndpoints` stay for
      explicit remote backends.
- [x] Fixture mutation/non-vacuity checks: endpoint aligns with the receiver,
      two scrape registrations merge into the metrics pipeline, a traces-only
      destination receives neither metrics nor logs, typed
      destination drives the pipeline by protocol, orphan registration rejected
      by name, push-only endpoint read rejected by name (and accepted with the
      aspect), unknown destination / destination-not-accepting-the-signal /
      protocol-cannot-carry-declared-signal / empty fanout /
      scrape-without-metrics-destination rejected by name, and secret/notify
      behavior intact.
- [x] `node-exporter` aspect (its own public aspect, NOT a provider): nixpkgs'
      node exporter bound to `127.0.0.1` (no firewall rule) and its own
      `services.telemetry.scrape.node` registration for the same port, so the
      collector target cannot drift from the listener. `services.node-exporter.port`
      is the only option; deeper tuning stays in nixpkgs'
      `services.prometheus.exporters.node`. Registers
      `prometheus-node-exporter.failure`. Fixture co-selects it with
      `telemetry` and asserts the unit, the listen bind, the rendered scrape
      job, the notify hook, and that node-exporter alone (no host aspect) is a
      rejected orphan.
- [x] Journald logs as an opt-in source with a typed sink
      (`services.telemetry.journald.{enable,includeUnits,excludeUnits,sink.endpoint,sink.streamFields,buffer.*}`)
      and a `journaldIngest` capability selector, implemented by a private
      Vector provider that ships JSON lines straight to the consumer's HTTP
      ingest URL over a bounded disk buffer with persistent read checkpoints —
      deliberately NOT through the collector's memory-only pipeline, which
      would imply durability it does not have. Fails closed on: shipping with
      no endpoint, an endpoint that is not http(s), an endpoint while shipping
      is off, a sink without the host aspect, and a buffer below Vector's
      268435488-byte disk floor (confirmed against the real binary: below it,
      the unit exits 78). Fixture asserts source/sink/buffer/notify, that the
      collector's own pipelines are untouched, that telemetry without journald
      starts no shipper, and the refusal probes.
- [ ] Consumer adoption (nix-homelab / dotfiles): select `telemetry` per host
      and move any host-local scrape registrations onto
      `services.telemetry.scrape`. For node metrics, select `node-exporter` and
      DELETE the downstream remote scrape jobs (homelab's VictoriaMetrics
      `node` job over the tailnet, and its `nodeExporterPort` / `scrapeTargets`
      options): leaving both in place scrapes every host twice, once locally
      through the collector and once remotely. The store's own self-scrape job
      stays. Journald: select `journald` with a `sink.endpoint` derived in the
      consumer's flake-level wrapper from its service endpoints.
- Deferred: an `expose` direction, external authenticated ingress,
  agent-to-gateway forwarding, cross-host destination discovery. A
  container/standalone Home Manager instance does not share the NixOS host's
  loopback or options and configures its exporter endpoint explicitly.
  Journald shipping is host-local and backend-agnostic in shape but implements
  one wire protocol today (the backend's HTTP JSON-line ingest); a
  different-protocol backend is a provider change, not a registration change.
  A durable local queue for the _OTLP_ path is still absent — the collector's
  exporters are memory-only, so trace/metric loss during an outage remains
  possible and is not covered by the journald buffer.

## Quick wins (pre-v2 value, consumer-adoptable independently)

Ship some of these before v2 so consumers get value that does NOT depend
on the contract change; none conflict with it.

- [x] **`nix-baseline` aspect**: substitution catalog + tuning from
      dotfiles' `nix.nix` (duplicated in homelab's foundation.nix):
      cache.shrublab.xyz substituter + keys, connect-timeouts,
      builders-use-substitutes. Tier-2 shared default, owned outright by the
      aspect; consumers append via nix.conf's `extra-substituters` /
      `extra-trusted-public-keys` or replace with `mkForce`. Adoption
      independent of v2.
- [x] **`ssh` + `mosh` aspects**: openssh baseline (password-auth off,
      openFirewall default) + client multiplexing fragment;
      `clientTuning` toggle. Per-host server policy stays consumer-side.
- [x] **tailscale notify**: tailscaled registers failure (fromPackage);
      autoconnect deliberately unregistered (retry exits are normal).
- [x] **`nix-gc` aspect generalization**: `implementation` switch
      (nh | fast-nix-gc), upstream-first import, ONE notify failure
      registration either way, `noVacuum` option (builders). Remaining:
      live-timing decision + fast-nix-optimise optional service.
- [ ] **Reusable-workflow adoption notes**: consumers call
      `build-push-cache.yml@v1` (tag cut at 0180d5ec) — stub + inputs in
      docs/contracts/ci.md; renovate bumps via tags.
- [ ] **`nix-baseline` adoption in both consumers** so the substituter
      catalog has one owner.
- [x] **`sops-bootstrap` package**: homelab's `scripts/secrets-bootstrap.py`
      generalized into `packages.<system>.sops-bootstrap` (literal or Jinja2
      templates, one-shot, placeholder + containment + validation gates,
      `--check`, recipients reported from the sops metadata). Consumer
      adoption: delete the script, drop devShell `jinja2`.

## Adoption (consumers — after v2 lands)

- [ ] **Homelab TD-31**: rebase onto v2 (capabilities-in-hosts + profiles +
      consumer-side wiring; build-account aspect). Paused until v2 core is
      green — avoid adopt-then-migrate.
- [ ] **Dotfiles adoption**: same shape; drop the stale
      `oci-melb-1.system = "x86_64-linux"` from topology (canonical says
      aarch64); topology loses per-machine `system`.

## CI live-run prerequisites (user-side)

- [ ] Set repo variable `FLEET_NIKS3_API_URL` (tailnet API host) + secret
      `FLEET_BUILDER_SSH_KEY`; authorize the key for the `nixbuild`
      account on builders; `FLEET_CI_ON_TAILNET=true` +
      `TS_OAUTH_CLIENT_ID`/`TS_AUDIENCE` from a Tailscale federated
      identity (writable `auth_keys` scope, tag `tag:ci`, `sub` claim
      narrowed to the repo).

## Deferred / future waves

- [ ] **shrub/spectre canonical records**: sparse host records + host keys;
      input by the nix-dotfiles agent once the v2 contract settles.
- [ ] **syncthing device IDs**: stays consumer-side (service credentials).
- [ ] **fast-nix-optimise**: optional second service on builders (bundled
      with nix-gc work).
