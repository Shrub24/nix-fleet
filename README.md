# nix-fleet — fleet control plane

A dendritic flake-parts repository that is the **shared fleet control-plane contract + mechanisms** for saurabhj's machines (nix-homelab fleet, dotfiles, future hosts): canonical cross-fleet facts, shared policy, pure projections, and the implementation packages of the mechanisms it owns. Consumers import this flake as a flake input and select its aspects and projections by name.

## Mission

- Host **one authoritative copy** of cross-fleet facts (machine identity + capabilities, external build resources, scheduling profiles, service endpoints) and of infrastructure capabilities more than one repository needs, so fixes land once — including the implementation code specific to each mechanism (`pkgs/`), so a shared mechanism is never split across repositories.
- Publish **facts, pure projections, aspects, and owned implementation packages**, not configurations: canonical facts + `fleet.buildProfiles` are tier-1 data; `lib.buildProfile` projects them; modules contribute `flake.modules.nixos.<aspect>`; packages contribute `packages.<system>.<name>`.
- Keep **canonical facts/policy distinct from consumer-local placement**: placement, recipients/topics, endpoint exposure/ingress policy, and secrets stay downstream.
- Stay **provider-agnostic** in mechanisms: no cloud-specific defaults in aspect code; provider coordinates enter through typed options or the tier-1 inventory, where nix-fleet is deliberately the authority.

## Non-goals

- No `nixosConfigurations` beyond the fixture evaluation class, no deploy topology — consumers own those.
- No secrets or `.sops.yaml` — consumers bind secret paths through typed option contracts.
- No service policy data (recipients, topics, publisher lists, ingress/auth) — those are consumer concerns. Cross-fleet service coordinates (`fleet.services.*`) are tier-1 facts; public routes exist only when explicitly bound.

The boundary in one line: **nix-fleet owns the canonical facts, the shared policy, the projection API, the mechanism, and its code; consumers own placement, recipients/topics, consumer-local endpoint policy, and secrets.** Per-contract reference docs for onboarding other repos live in [docs/contracts/](docs/contracts/README.md) — hosts (identity + trust), builders (capabilities + profiles + scheduling), ci (builder artifacts + workflow template).

## Pattern (dendritic, non-negotiable)

Follow the Dendritic Pattern exactly: github.com/mightyiam/dendritic (README + `references/examples.md`), auto-imported via `vic/import-tree`.

- Every file under `modules/` is a flake-parts module. No exceptions.
- Aspect files are ordinary `.nix` files named for the feature — **never `default.nix`** for a discovered feature.
- Several contributors to one aspect = sibling files each contributing to the same `flake.modules.nixos.<name>` (deferredModule merge; no imports list between them).
- `_`-prefixed paths are a rare escape hatch: genuinely private non-discovered implementation or data helpers. Not the primary way to define anything.
- Values shared across aspects go through declared flake-parts options or let bindings — never `specialArgs`/`extraSpecialArgs`.
- Cross-cutting contracts are declared option namespaces (e.g. an aspect declares `services.<name>.*`); provider aspects and consumer features compose by selecting/importing, never by reading another aspect's internals.

## Repository shape

```
flake.nix            # minimal: inputs + mkFlake + import-tree ./modules
lib/
  secrets.nix        # canonical secrets helper (mkSecretFileOption, mkSecretKeyOption,
                     # mkRequiredSecretAssertion, mkSecretsFromMap) — same file shape as
                     # nix-homelab's lib/secrets.nix; aspects import it explicitly
pkgs/
  notify/               # owned implementation: daemon + CLI + systemd handler (one package)
  sops-bootstrap/       # owned implementation: create one SOPS file from a template
modules/
  flake/             # flake plumbing, not host features
    flake-parts.nix  # imports inputs.flake-parts.flakeModules.modules (REQUIRED)
    outputs.nix      # wiring: configurations.nixos -> nixosConfigurations + toplevel checks
    fixture.nix      # fixture evaluation class + its contract leaf checks for `nix flake check`
    tooling.nix      # published: flakeModules.tooling (treefmt-nix, priorities pinned)
    packages.nix     # owned implementation packages (pkgs/)
    secrets-lib.nix  # published: lib.secrets (re-exports lib/secrets.nix)
    devshell.nix     # repo-local operator dev shell
  networking/
    tailscale.nix    # aspect: Tailscale baseline
  notifications/
    notify.nix       # aspect: notification dispatch + monitor registration
  cache/
    niks3-cache.nix     # aspect: niks3 binary-cache server
    niks3-publisher.nix # aspect: niks3 closure-upload client (post-build hook)
  observability/
    beszel-agent.nix  # aspect: Beszel agent auth/enrollment
    node-exporter.nix # aspect: node metrics (loopback exporter + scrape registration)
  monitoring/
    alertmanager.nix  # aspect: Alertmanager loopback default + failure registration
    vmalert.nix       # aspect: vmalert instance validation + failure registration
  telemetry/         # aspect: telemetry — the services.telemetry vocabulary + value validation
                     #   (starts nothing); lanes telemetry-metrics, telemetry-logs, telemetry-otlp
                     #   each compose the contract + the fleet default realization for one signal;
                     #   realizations telemetry-vmagent, telemetry-vector (one signal each) and
                     #   telemetry-otel-collector-scrape / telemetry-otel-collector-otlp
                     #   (one host collector service)
  access/
tests/
  telemetry/         # bounded offline runtime checks: local mock receivers, synthetic
    delivery_check.py # OTLP ids, real collector binary (no live endpoint, no credential)
    ingress_check.py
.envrc               # direnv: use flake
justfile             # fmt / fmt-check / check / lock
lefthook.yml         # pre-commit fmt+statix+deadnix, pre-push flake check
renovate.json        # weekly nix flake input updates
```

````

## Aspects (extracted from nix-homelab)

1. **`tailscale`** — Tailscale baseline: enable, Tailscale SSH, systemd restart/ordering pinning, MTU debug option. Auth key via `secretFiles.auth`; unbound or missing file means the two-step sops bootstrap, registering nothing.
2. **`beszel-agent`** — agent enrollment (the hub stays in nix-homelab). The KEY the agent holds is the hub's PUBLIC key (hub→agent SSH auth): policy data, bound via `services.beszel-agent.key`, no sops involved. TOKEN is deliberately not wired — WebSocket registration needs plain-HTTP reachability of the hub URL, but the hub sits behind Cloudflare Access and agents reach it over tailnet SSH, so the hub-issued token path can never work here. No host secrets remain for beszel.
3. **`fleet`** — the fleet authority feature: canonical machine identity with build capabilities (`fleet.hosts.*.capabilities`), external build resources (`fleet.externalBuilders`), named scheduling profiles (`fleet.buildProfiles`), and the pure projection API `lib.buildProfile` (`resolveBuildProfile` → renderers). No NixOS realization is published; the consumer's own flake-level module resolves a profile and wires trust + scheduling. Includes the `build-account` dispatch-account aspect. Full contract: [docs/contracts/builders.md](docs/contracts/builders.md) (hosts: [hosts.md](docs/contracts/hosts.md), CI: [ci.md](docs/contracts/ci.md)).
The same fleet feature publishes the typed `fleet.services.*.endpoints.*` endpoint catalog and pure `lib.serviceEndpoints` resolver (`resolveEndpoint` returns URL, canonical host ID, hostname, and port for a tailnet route). Its raw canonical data is `lib.serviceEndpoints.canonicalServices`. See [docs/contracts/services.md](docs/contracts/services.md) for selection and ownership. Telemetry is host-local instead. The `telemetry` aspect owns the `services.telemetry` vocabulary, the signal lanes (`telemetry-metrics`, `telemetry-logs`, `telemetry-otlp`) compose the fleet's default realization for one signal each, and the realizations (`telemetry-vmagent`, `telemetry-vector`, `telemetry-otel-collector-scrape`, `telemetry-otel-collector-otlp`) are aspects of their own — see [telemetry.md](docs/contracts/telemetry.md). Service aspects register sources and read the local endpoint; registering never activates a realization.

4. **`niks3-cache`** — niks3 binary-cache *server*. S3 coordinates, cache URL, secret paths are options; fails closed when unbound.
5. **`niks3-publisher`** — niks3 closure-upload *client* (upstream post-build-hook module). `serverUrl` required; token via `secretFiles.apiToken`.
5a. **`telemetry`** — the host-local contract provides the `services.telemetry` vocabulary and value validation; it starts no unit, listener or provider. Producers register Prometheus scrape sources (`services.telemetry.scrape`), admit OTLP signals (`services.telemetry.otlp.signals`, empty by default), and read local OTLP endpoints (`services.telemetry.otlp.httpUrl`/`grpcUrl`). Reading an endpoint fails closed unless the OTLP realization is composed with an admitted signal and a destination pipeline. Remote backends are typed destinations with protocol, endpoint, secret headers, and a required per-destination `signals` set plus per-signal fanout (`services.telemetry.destinations`/`pipelines`), so a traces-only backend never receives metrics or logs.

Registrations are dormant declarations, like notify's: a scrape source, admitted signal, destination or journald sink neither activates a realization nor fails when none is composed. A registration is realized only while its signal lane is composed. Host composition chooses capabilities through **lane aspects**: `telemetry-metrics` composes the default `telemetry-vmagent` realization; `telemetry-logs` composes `telemetry-vector`; and `telemetry-otlp` composes `telemetry-otel-collector-otlp`. Journald shipping is opt-in through the logs lane and uses its typed sink (`services.telemetry.journald`: source filters, `sink.endpoint`, `streamFields`, bounded disk buffer).

Realizations are aspects of their own: `telemetry-vmagent`, `telemetry-vector`, `telemetry-otel-collector-scrape` and `telemetry-otel-collector-otlp`. Composing an alternate replaces its lane's default; `telemetry-otel-collector-scrape` is the alternate scraper when scraped metrics go to an OTLP destination. The two Collector aspects configure one host service, so composing both gives one Collector with both pipelines. Each signal has at most one realization; composing a second for that signal fails closed by name.

vmagent renders registered jobs into `services.vmagent`, forwards scraped metrics over Prometheus remote write to the selected metrics destinations, uses a bounded persistent queue, and refuses credentials at unit start if their values could alter vmagent's argument parsing. Vector ships journald logs directly to the consumer's HTTP JSON-line endpoint rather than through the Collector. The OTel realization renders into nixpkgs' Collector, with implementation tuning under `services.otel-collector` (resource processor, extra processors, loopback delivery-health port 9464, raw exporter override) and persistent bounded per-exporter delivery: file_storage-backed OTLP queues and a WAL for the Prometheus remote-write exporter, which rejects `sending_queue` in the pinned contrib release. It publishes explicit loopback delivery-health metrics instead of the implicit port 8888 listener. Every active realization publishes its loopback health listener as a registration; collection follows the composed metrics realization.

Hosts may act as explicit relays or gateways: producer listeners stay loopback-only; optional `otlp.ingress` binds an explicitly addressed network listener without moving local URLs; local `resourceAttributes` enrichment never relabels forwarded telemetry; and no firewall opening is added. An admitted signal with no pipeline, non-loopback producer bind, invalid or colliding ingress, destination/protocol signal mismatch, unsupported metrics fanout for the composed scrape realization, duplicate realization for a signal, or journald sink without an endpoint fails closed by name. See [docs/contracts/telemetry.md](docs/contracts/telemetry.md).
5b. **`node-exporter`** — node metrics as a producer of the telemetry contract: nixpkgs' node exporter bound to `127.0.0.1` (no firewall rule) plus its own `services.telemetry.scrape.node` registration on the same port, so the realization's target cannot drift from the listener. `services.node-exporter.port` is the only option; deeper exporter tuning stays in nixpkgs' own `services.prometheus.exporters.node`. Registers `prometheus-node-exporter.failure`. Composing it alone starts no scraper: its registration is carried only while a metrics realization is composed.
5c. **`vmalert`** — rule evaluation as a mechanism: the validation and the owned-unit failure registration over nixpkgs' `services.vmalert.instances.<name>`. The aspect binds no instance, so a host with none is inert; rules, thresholds, datasource, notifier, and placement stay the consumer's. An enabled instance fails closed by name, per instance, in three cases: without `settings."datasource.url"` (nothing to evaluate against), without `settings."notifier.url"` (alerts reaching nobody), and without `settings."httpListenAddr"` (vmalert's own default listens on every interface, so exposure has to be a deliberate binding — a loopback default cannot be contributed here, because `settings` is the consumer's per-instance CLI flag set). Registers `vmalert-<name>.failure` for every enabled instance.
5d. **`alertmanager`** — alert grouping and delivery as a mechanism: over nixpkgs' `services.prometheus.alertmanager`, `listenAddress` defaults to `127.0.0.1` (`mkDefault`: nixpkgs listens on every interface otherwise, and alert delivery is a loopback conversation on this host) and `checkConfig` stays on, so `amtool` validates the rendered configuration at build time. The consumer owns `configuration` (route tree, receivers, grouping, inhibition, recipients) and the `enable` binding; the aspect enables nothing, so an unbound host is inert, and its failure registration exists only when the consumer enables the unit. Secret-bearing receiver values go through `environmentFile` (sops-rendered) and `$VAR` references — `configuration` itself is world-readable.
5e. **`bifrost`** — native AI gateway with its embedded dashboard, loopback listener and a managed unprivileged service. `services.bifrost.settings` owns startup configuration; `plugins.*` owns built-in and host-locked native plugin registration. The config store is enabled by default (governance, CEL routing and dashboard authentication require it) with `source_of_truth = "config.json"`, so the Nix document stays the startup authority while `config_store.type` and its `config` object remain overridable for an existing store. Credentials enter through a runtime `environmentFile`, and the aspect registers `bifrost.failure`. Providers, authentication, exposure and backups remain consumer policy. Contract: [docs/contracts/bifrost.md](docs/contracts/bifrost.md).
6. **`notify`** — notification dispatch (Telegram + ntfy) realizing native systemd event notifications. One owned package (`pkgs/notify`, overridable): the daemon (`notify serve`, unprivileged system user, unix socket + loopback TCP for app webhooks) owns secrets, the policy map, and journal access; `notify send`/`notify test` and the `unit-notify` handler are thin unprivileged connectors. Its POST routes are `/notify` (application notification; `severity` must be one of the three values and an unknown one is refused with a 400 rather than downgraded), `/event` (systemd unit event), and `/alertmanager` (one Alertmanager webhook group: mapped to a single notification at the group's worst severity — critical > warning > info — with `?topic=` selecting the routing topic, and a body that is not an Alertmanager group refused with a 400 rather than dropped). The registration contract `services.notify.events.<unit>.{failure,success}` is a declaration-only fragment contributors import, so registration is unconditional and realization happens only when notify is co-selected. Socket access: callers join the always-defined `notify` group from their own module (`users.users.<name>.extraGroups`); root units need nothing. Per-event policy: severity (`info | warning | critical`, defaulted per event kind — failure at warning, success at info; failure/success are event names, never severities), topic, journalLines, context, title — explicit only (no hook without a declared event). Routing is declared by use case: an explicit topic resolves in the consumer's per-transport map (`topics`), otherwise the transport's `defaultTopic` does, and that default must name a key of the map — never severity-derived, with an unresolvable topic returned as a named dispatch error rather than a silent drop. Dispatch policy (chatId, topics, ntfy coordinates) is consumer-bound; secrets follow the two-step bootstrap.

### System baselines

Selection is enablement for every aspect: importing the module applies it, so there is no `enable` flag to remember.

7. **`nix-baseline`** — latest locked Nix package, batch CPU and low-priority I/O daemon defaults, substituter catalog and tuning (nixpkgs-owned defaults such as `cache.nixos.org` are not restated). Host-sized memory, `cores` and `max-jobs` budgets stay consumer-owned. The catalog is a baseline rather than an option surface: a consumer appends through nix.conf's own `extra-substituters` and `extra-trusted-public-keys` keys, or replaces a list with `lib.mkForce` (`substituters` already being an option is why a fleet-specific `extraSubstituters` was redundancy, not a seam). Registers `nix-daemon.failure` (`fromPackage`).
8. **`ssh`** — server hardening (password auth off, `prohibit-password`, firewall default on) + client tuning fragment in `/etc/ssh/ssh_config.d`. Namespace is `services.ssh-baseline`. Registers `sshd.failure`.
9. **`mosh`** — `programs.mosh` with `openFirewall = false` deliberately: exposure is the consumer's call, and tailnet-only use needs none.
10. **`nix-gc`** — scheduled store cleanup; `implementation = "nh" | "fast-nix-gc"`. The fast path is threshold-driven (`ensureFree`), prunes stale roots with nh `--no-gc`, and runs a weekly optimise; see [docs/contracts/nix-gc.md](docs/contracts/nix-gc.md). Registers failures for each unit it owns.
11. **`podman`** — no option namespace: selection contributes fleet defaults onto the platform's own options (`virtualisation.podman.enable`, `autoPrune.{enable,flags}`), so consumer overrides read as upstream config and `flags` appends rather than fighting. Adds the start-limit guard for `virtualisation.oci-containers` units (`serviceName`-based, so renamed units are covered) that makes a crash-looping container reach `failed` — 3600/5, because systemd counts every start in a fixed window and a 300s window only reaches loops faster than 60s, and registers `podman-prune.failure`. `--volumes` is not a default — it reclaims volumes whose container was removed. Container units are consumer-declared, so their failure events stay the consumer's registration.


### Operator tools

12. **`sops-bootstrap`** — `packages.<system>.sops-bootstrap`: create one SOPS-encrypted file from a checked-in template (literal or Jinja2), refusing existing targets, unfilled `<placeholders>`, invalid documents, and paths outside the secrets directory. Operator-only, never a CI path. Contract: [docs/contracts/secrets.md](docs/contracts/secrets.md).

## Consumer contract (how nix-homelab / dotfiles consume)

nix-fleet is the **authority for canonical fleet facts**: machine identity
and build capabilities (`fleet.hosts`), external build resources
(`fleet.externalBuilders`), cross-fleet scheduling profiles
(`fleet.buildProfiles`), service endpoint coordinates (`fleet.services`), and shared mechanism defaults. Three tiers govern
who may change what:

1. **Canonical fact** — declared here (inventory + schema). Consumers derive;
   never restate. Not casually overridable.
2. **Shared default** — mechanism defaults (ssh tuning, maxJobs). Overridable
   normally.
3. **Consumer-local policy** — compositions, per-relationship overrides,
   extra trust, local profiles, substituters, secrets. Downstream.

```nix
# consumer flake-level: one import — the fleet feature composes schema,
# canonical inventory, validation, CI artifacts; lib.buildProfile is the
# pure projection API; lib.serviceEndpoints resolves explicitly selected routes.
imports = [
  inputs.nix-fleet.flakeModules.fleet
  inputs.nix-fleet.flakeModules.tooling
];

# consumer-local additions (additive, never shadows canonical IDs):
fleet.hosts.mybox.capabilities.nixBuilder.enable = true;
fleet.buildProfiles.mybox = { hosts.mybox = { }; };
```

There is **no NixOS realization module**. The consumer's own flake-level
module closes over its `config.fleet` and calls the pure API:

```nix
let
  resolve = inputs.nix-fleet.lib.buildProfile;
  specs = resolve.resolveBuildProfile config.fleet "ci";
in {
  programs.ssh.knownHosts = resolve.knownHosts specs;  # trust by projection
  nix.buildMachines = resolve.buildMachines specs;     # scheduling
}
```

CI artifacts (`packages.<profile>`, e.g. `packages.ci`) render from the same
inventory; see [docs/contracts/ci.md](docs/contracts/ci.md).

NixOS aspects (including `build-account`) are host modules: they land in a
host composition's NixOS module list, never in the consumer's flake-level
imports.

Consumers keep: compositions, placement, secrets, per-relationship policy,
provider quirks. nix-fleet owns: canonical facts, the projection API, the
mechanism, its code.

## Working agreements

- jj colocated repo; anonymous mutable changes off `main@origin`; bookmark only on publish.
- `treefmt` via `nix fmt` (prettier for md/yaml/json, taplo for TOML, plus the pinned Nix trio in `modules/flake/tooling.nix`); `nix flake check` runs the same formatter as a check, so unformatted files fail CI. Same tooling shape as dotfiles' `modules/flake/tooling.nix`.
- Secrets enter through `/lib/secrets.nix` helpers only: `mkSecretFileOption` for consumer-bound paths, `mkRequiredSecretAssertion` for the named fail-closed gate, `mkSecretsFromMap` for `sops.secrets` registration. Byte-identical to nix-homelab's helper; consumers of these aspects do not need their own copy.
- Every aspect declares its options; every option has a type; fail closed with named errors, never raw `builtins.head`/null derefs.
- Input pins: once consumer flakes alias their nixpkgs-family inputs to nix-fleet's (`inputs.<x>.inputs.nixpkgs.follows = "nixpkgs"` via nix-fleet), this repository's `flake.lock` is the fleet's shared-input authority and its `renovate.json` schedule is the fleet's bump cadence — a nixpkgs bump lands here first, consumers inherit it through their follows chains.
- Provenance discipline: no secrets, no private keys, no absolute paths in this repo. The canonical inventory carries public fleet facts only (machine IDs, systems, Tailscale hostnames, host *public* keys once harvested); consumer-local inventory lives downstream, additive only. The fixture is a consumer-shaped integration test and must never resemble or feed the canonical inventory.

## Pointers into nix-homelab (read-only reference)

- Dendritic conventions evolved there: `AGENTS.md` (## Project Policy), `CONVENTIONS.md`.
- The aspect inventory and ownership rules: `ARCHITECTURE.md` / `STRUCTURE.md` in nix-homelab.
- The three registration patterns worth copying conceptually: `services.state-backups.services.<name>` (backup registration), `services.notify.events.<unit>.{failure,success}` (declaration-only fragment imported by the notify aspect and by contributors; realization is native systemd events), `services.postgres.consumers.<name>` (database registration).

## Tooling contract

`flake.flakeModules.tooling` is the base formatting layer for every repository
that selects it. Fixed by the base: `projectRootFile`, the pinned Nix trio
(deadnix < statix < nixfmt — all three claim `*.nix`; with the default tie the
rewriters can land after nixfmt and `nix fmt` never reaches a fixed point),
baseline excludes, and prettier for markdown/YAML/JSON. Consumers wire it
beside their own flake-parts modules and declare `treefmt-nix` as their own
input (inputs are not transitive), then extend with their own languages and
extra excludes via the same `perSystem.treefmt` options — list options
concatenate:

```nix
imports = [ inputs.nix-fleet.flakeModules.tooling ];
```

`flake.lib.secrets` (consumed as `inputs.nix-fleet.lib.secrets`) exposes the
canonical SOPS helpers; consumers import it
instead of carrying their own copy:

```nix
secretHelpers = inputs.nix-fleet.lib.secrets;
```

The four helpers (`mkSecretFileOption`, `mkSecretKeyOption`,
`mkRequiredSecretAssertion`, `mkSecretsFromMap`) are byte-identical to
nix-homelab's `lib/secrets.nix`, so options declared with either resolve to the
same types.
````

## CI

`.github/workflows/build-push-cache.yml` is a reusable workflow
(`workflow_call`) with a direct-dispatch entry point. Consumers call it with
`uses:` and pin a version tag; `.github/workflows/ci.yml` calls it for this
repository. The full interface lives in [docs/contracts/ci.md](docs/contracts/ci.md).

One coordinator runs `nix-fast-build` against `.#checks`. `runner_system`
selects its architecture (ARM by default); `systems` selects the workload
architectures (x86_64 and ARM by default). `builder_attr` selects a rendered
remote-builder profile (`ci` by default); explicitly empty means local-only.
An x86-only consumer sets both `runner_system` and `systems` to `x86_64-linux`.

Remote builders publish through their native niks3 post-build-hooks. The GHA
coordinator uses `Mic92/niks3-action` for cache configuration and local build
publication with GitHub OIDC. There is no separate coordinator uploader or
custom token refresher. Both direct dispatch and reusable callers require
`contents: read` and `id-token: write`; cache authorization remains consumer
policy in `services.niks3-cache.oidc.providers`.

CI builder artifacts come from the fleet inventory, not repo variables: a
consumer flake importing the fleet feature gets `packages.ci` (canonical profile;
per-profile bundles as `packages.<profile>`) — a directory with `machines` (nix
machines-file lines), `known_hosts`, and `ssh_config`, rendered from the
merged inventory at consumer eval time. The `build-push-cache` reusable
workflow installs these instead of holding builder coordinates; a
tailnet join is enabled by default, using public `fleet.ci.tailscale` metadata
rendered as `packages.<system>.ci-tailscale` — no repository variables or
long-lived OAuth secret. Only the coordinator private key is a repository
secret; its public half is `fleet.ci.sshPublicKey`. The join reuses the same
`id-token: write` grant niks3 needs. Full contract:
[docs/contracts/ci.md](docs/contracts/ci.md).

CI-capable cache setup consumer-side:

```nix
services.niks3-cache = {
  s3.endpoint = "...";
  cacheUrl = "https://cache.example.com";
  secretFiles = { host = ...; apiToken = ...; };
  oidc.providers.github = {
    issuer = "https://token.actions.githubusercontent.com";
    audience = "https://cache.example.com";
    boundClaims.repository_owner = [ "Shrub24" ];
    scopes = [ "write" ];
  };
};
```
