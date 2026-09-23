# nix-fleet — shared fleet infrastructure modules

A dendritic flake-parts repository of **reusable, host-agnostic NixOS aspects** shared across saurabhj's machines (nix-homelab fleet, dotfiles, future hosts). Consumers import this flake as a flake input and select its aspects by name.

## Mission

- Host **one authoritative copy** of infrastructure capabilities that more than one repository needs, so fixes land once — including the implementation code specific to each mechanism (`pkgs/`), so a shared mechanism is never split across repositories.
- Publish **aspects and owned implementation packages**, not configurations: modules contribute `flake.modules.nixos.<aspect>`; packages contribute `packages.<system>.<name>`. No hosts, no secrets, no policy data.
- Stay **provider-agnostic**: no cloud-specific defaults, no tailnet suffixes, no literal hostnames.

## Non-goals

- No host records, no `nixosConfigurations` beyond the fixture evaluation class, no deploy topology — consumers own those.
- No secrets or `.sops.yaml` — consumers bind secret paths through typed option contracts.
- No service policy data (recipients, topics, endpoint catalogs, publisher lists) — those are consumer concerns.

The boundary in one line: **nix-fleet owns the mechanism and its code; consumers own placement, recipients/topics, endpoint policy, and secrets.** Per-contract reference docs for onboarding other repos live in [docs/contracts/](docs/contracts/README.md) — hosts (identity + trust), builders (registry + scheduling), ci (builder artifacts + workflow template).

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
modules/
  flake/             # flake plumbing, not host features
    flake-parts.nix  # imports inputs.flake-parts.flakeModules.modules (REQUIRED)
    outputs.nix      # wiring: configurations.nixos -> nixosConfigurations + toplevel checks
    fixture.nix      # fixture evaluation class for `nix flake check`
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
    beszel-agent.nix # aspect: Beszel agent auth/enrollment
  access/
    builder-access.nix # published flakeModules: fleet registry + fleet-builders realization
.envrc               # direnv: use flake
justfile             # fmt / fmt-check / check / lock
lefthook.yml         # pre-commit fmt+statix+deadnix, pre-push flake check
renovate.json        # weekly nix flake input updates
```

````

## Aspects (extracted from nix-homelab)

1. **`tailscale`** — Tailscale baseline: enable, Tailscale SSH, systemd restart/ordering pinning, MTU debug option. Auth key via `secretFiles.auth`; unbound or missing file means the two-step sops bootstrap, registering nothing.
2. **`beszel-agent`** — agent auth/enrollment (the hub stays in nix-homelab). Gated on `secretFiles.host` existing; credentials arrive via a sops template. The credential is the fleet-wide KEY (hub→agent SSH auth); TOKEN is deliberately not wired — WebSocket registration needs plain-HTTP reachability of the hub URL, but the hub sits behind Cloudflare Access and agents reach it over tailnet SSH, so the hub-issued token path can never work here. Consumers can drop `beszel/token` from host secrets entirely.
3. **`fleet`** — the fleet authority feature: canonical machine identity, builder participation, and named builder sets as the one scheduling mechanism; the evaluation-local realization (`config.fleet.realization`) and CI bundles (`packages.ci`, `packages.<set>`) render from the same inventory. Full contract: [docs/contracts/builders.md](docs/contracts/builders.md) (hosts: [hosts.md](docs/contracts/hosts.md), CI: [ci.md](docs/contracts/ci.md)). The old `modules.nixos.fleet-builders` / `services.builder-access.hosts` paths fail eval with named migration errors (transitional shims).
4. **`niks3-cache`** — niks3 binary-cache *server*. S3 coordinates, cache URL, secret paths are options; fails closed when unbound.
5. **`niks3-publisher`** — niks3 closure-upload *client* (upstream post-build-hook module). `serverUrl` required; token via `secretFiles.apiToken`.
6. **`notify`** — notification dispatch (Telegram + ntfy) realizing native systemd event notifications. One owned package (`pkgs/notify`, overridable): the daemon (`notify serve`, unprivileged system user, unix socket + loopback TCP for app webhooks) owns secrets, the policy map, and journal access; `notify send`/`notify test` and the `unit-notify` handler are thin unprivileged connectors. The registration contract `services.notify.events.<unit>.{failure,success}` is a declaration-only fragment contributors import, so registration is unconditional and realization happens only when notify is co-selected. Socket access: callers join the always-defined `notify` group from their own module (`users.users.<name>.extraGroups`); root units need nothing. Per-event policy: severity, topic, journalLines, context, title — explicit only (no hook without a declared event). Routing resolves per transport: semantic topic if the consumer's map has it, otherwise the severity. Dispatch policy (chatId, topics, ntfy coordinates) is consumer-bound; secrets follow the two-step bootstrap.

## Consumer contract (how nix-homelab / dotfiles consume)

nix-fleet is the **authority for canonical fleet facts**: machine identity
(`fleet.hosts`), builder participation (`fleet.builders`), cross-fleet
builder sets (`fleet.builderSets`), and shared mechanism defaults. Three
tiers govern who may change what:

1. **Canonical fact** — declared here (inventory + schema). Consumers derive;
   never restate. Not casually overridable.
2. **Shared default** — mechanism defaults (ssh tuning, maxJobs). Overridable
   normally.
3. **Consumer-local policy** — compositions, sshUser per relationship,
   extraKnownHosts, local builder sets, substituters, secrets. Downstream.

```nix
# consumer flake-level: one import — the fleet feature composes schema,
# canonical inventory, validation, CI artifacts, and the realization.
imports = [
  inputs.nix-fleet.flakeModules.fleet
  inputs.nix-fleet.flakeModules.tooling
];

# consumer-local additions (additive, never shadows canonical IDs):
fleet.builderSets.deploy = [ "home-forge" ];   # consumer-local set
```

Host compositions consume the **evaluation-local realization** — built in
the consumer's own evaluation with the consumer's merged fleet config closed
over:

```nix
# consumer host composition (NixOS class)
imports = [ config.fleet.realization ];
services.fleet-builders.activeSet = "ci";
```

The realization is never imported from `inputs.nix-fleet.modules.nixos.*`:
a module constructed in nix-fleet's evaluation would silently bind
nix-fleet's inventory. Importing it throws with this exact guidance
(transitional shim; removed after both consumers migrate).

CI artifacts (`packages.ci` for the canonical set, `packages.<set>` per declared set)
render from the same inventory; see [docs/contracts/ci.md](docs/contracts/ci.md).

NixOS aspects are host modules, not flake-parts modules: they land in a host
composition's NixOS module list, never in the consumer's flake-level imports.
The fleet realization is the one exception in shape — it is not imported from
`inputs.nix-fleet.modules.nixos.*` at all, but from the consumer's own eval
(`config.fleet.realization`), because a module constructed in nix-fleet's
evaluation would silently bind nix-fleet's inventory:

```nix
# consumer host composition (a NixOS module evaluation)
imports = [ config.fleet.realization ];
services.fleet-builders.activeSet = "ci";  # null = trust only, no scheduling
```

Consumers keep: compositions, placement, secrets, per-relationship policy,
provider quirks. nix-fleet owns: canonical facts, the mechanism, its code.

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

``.github/workflows/build-push-cache.yml` is a **reusable workflow**
(`workflow_call`) — consumers call it with `uses:`and pin a version tag;
renovate proposes tag bumps behind a PR gate with changelogs.`.github/templates/`keeps the readable source of the workflows (the
consumer contract detail lives in [docs/contracts/ci.md](docs/contracts/ci.md));`.github/workflows/ci.yml` instantiates them for this repository —
nix-fleet is its own first consumer.

- **`nvfetcher-refresh`** — scheduled source-metadata regeneration, flake
  validation, PR on change.
- **`build-push-cache`** — coordinated fleet build + cache push. One
  coordinator runs `nix-fast-build`: it evaluates locally, fans builds out
  to nix remote builders (the `builders =` mechanism, multiple hosts, results
  return to the coordinator), and pushes realised paths with `niks3 push`
  (server-side deduplication makes overlap harmless). GitHub-runner builds
  run through `niks3-action`, which registers a post-build-hook and streams
  uploads with GitHub OIDC — bind `services.niks3-cache.oidc.providers`
  consumer-side for that path. The coordinator push reads the token
  file niks3 re-reads periodically; on GHA an inline refresher loop mints
  fresh OIDC tokens bound to the cache audience (no long-lived secrets), and
  non-GHA coordinators use a fleet-issued push token in the same env var.

CI builder artifacts come from the fleet inventory, not repo variables: a
consumer flake importing the fleet feature gets `packages.ci` (canonical set;
per-set bundles as `packages.<set>`) — a directory with `machines` (nix
machines-file lines), `known_hosts`, and `ssh_config`, rendered from the
merged inventory at consumer eval time. The `build-push-cache` template
installs these instead of holding builder coordinates; a
`FLEET_CI_ON_TAILNET=true` repo variable plus
`TS_OAUTH_CLIENT_ID`/`TS_OAUTH_CLIENT_SECRET` secrets add the Tailscale join
for fleet-host builders. Full contract: [docs/contracts/ci.md](docs/contracts/ci.md).

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
