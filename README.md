# nix-fleet — shared fleet infrastructure modules

A dendritic flake-parts repository of **reusable, host-agnostic NixOS aspects** shared across saurabhj's machines (nix-homelab fleet, dotfiles, future hosts). Consumers import this flake as a flake input and select its aspects by name.

## Mission

- Host **one authoritative copy** of infrastructure capabilities that more than one repository needs, so fixes land once.
- Publish **aspects**, not configurations: every module here contributes `flake.modules.nixos.<aspect>` and nothing else. No hosts, no secrets, no policy data.
- Stay **provider-agnostic**: no cloud-specific defaults, no tailnet suffixes, no literal hostnames.

## Non-goals

- No host records, no `nixosConfigurations`, no deploy topology — consumers own those.
- No secrets or `.sops.yaml` — consumers bind secret paths through typed option contracts.
- No service policy data (endpoint catalogs, publisher lists) — those are consumer concerns.

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
flake.nix            # minimal: inputs (flake-parts, import-tree) + mkFlake + import-tree ./modules
modules/
  flake-parts.nix    # imports inputs.flake-parts.flakeModules.modules (REQUIRED)
  beszel-agent.nix   # example aspect
  builder-access/
    default-options.nix
    nixbuild.nix
  ...
treefmt.toml
```

## Seed aspects (extraction wave 1, from nix-homelab)

These four are already self-contained in nix-homelab (post D-054) and are the first extraction targets. Read their nix-homelab sources for behaviour; re-express here per the pattern above:

1. **`beszel-agent`** — Beszel agent auth/enrollment. Source: `nix-homelab/modules/flake/observability-agent.nix` (+ `modules/admin/beszel.nix` is the *hub*, which stays in nix-homelab — only the agent is shared). Key contract: derives the conventional host secret path, gates enrollment on its existence; keep that gate, but express the secret path as a typed option (`secretFiles.host`) with the conventional default, not a repo-relative path literal.
2. **`builder-access`** — remote-builder SSH trust. Source: `nix-homelab/modules/flake/builder-access.nix` + `modules/flake/_builder-access/nixbuild-ssh.nix`. Keep the mechanism here; the builder *endpoint/URL* is consumer policy (nix-homelab passes it in via options; no nixbuild.net literals in this repo).
3. **`niks3-cache`** — niks3 binary-cache *server*. Source: `nix-homelab/modules/cache/niks3-cache.nix`. S3 backend coordinates and signing keys arrive via typed options (`accessKeyFile`, `secretKeyFile`, `signKeyFiles`, backend endpoint); no R2 literals, no `policy/globals.nix` import.
4. **`tailscale`** — Tailscale baseline. Source: `nix-homelab/modules/flake/tailscale.nix`. Mechanism here: enable, advertise connector behaviour, MTU debug option, systemd hardening. The auth key is a typed `secretFiles.auth` option (consumer binds it; the conventional `secrets/hosts/<host>/system.yaml` path stays in nix-homelab, not here). No tailnet suffix, no tag literals.

## Consumer contract (how nix-homelab / dotfiles will consume)

```nix
# consumer flake.nix
inputs.nix-fleet.url = "git+ssh://.../nix-fleet";  # or path:../nix-fleet during bring-up

# consumer module selecting an aspect
imports = [ inputs.nix-fleet.flake.modules.nixos.tailscale ];
```

Consumers keep: host identity, secrets, policy data, provider quirks. nix-fleet owns: the mechanism.

## Working agreements

- jj colocated repo; anonymous mutable changes off `main@origin`; bookmark only on publish.
- `treefmt` with nixfmt; keep `nix flake check` green (a wiring module + one fixture NixOS class is enough to evaluate aspects without hosting real configs).
- Every aspect declares its options; every option has a type; fail closed with named errors, never raw `builtins.head`/null derefs.
- Provenance discipline: no secrets, no absolute paths, no machine names in this repo.

## Pointers into nix-homelab (read-only reference)

- Dendritic conventions evolved there: `AGENTS.md` (## Project Policy), `CONVENTIONS.md`.
- The aspect inventory and ownership rules: `ARCHITECTURE.md` / `STRUCTURE.md` in nix-homelab.
- The three registration patterns worth copying conceptually: `services.state-backups.services.<name>` (backup registration), `services.notification-daemon.monitor.units.<unit>` (per-unit hooks), `services.postgres.consumers.<name>` (database registration).
