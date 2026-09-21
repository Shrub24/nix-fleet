# Working instructions — nix-fleet

## Mission

Reusable, host-agnostic NixOS infrastructure aspects shared across saurabhj's machines. This repo publishes `flake.modules.nixos.<aspect>` outputs and the implementation packages its mechanisms need (`packages.<system>.<name>`, sources in `pkgs/`). Consumers (nix-homelab, dotfiles) select aspects, bind secrets, and own policy data — placement, recipients/topics, endpoint policy, secrets/readership. Read `README.md` first — it carries the full mission, aspect list, and consumer contract.

## Dendritic pattern — authoritative rules

Follow the Dendritic Pattern (github.com/mightyiam/dendritic, README + references/examples.md) exactly:

- Every file under `modules/` is a flake-parts module; no exceptions. `modules/flake-parts.nix` must import `inputs.flake-parts.flakeModules.modules`.
- Aspect files are ordinary `.nix` files named for the feature. **Never use `default.nix` for an auto-discovered feature module** — only for real directory-import entrypoints.
- Multiple contributors to one aspect = sibling files each contributing to the same `flake.modules.nixos.<name>` (deferredModule merge semantics; no cross-imports between siblings).
- `_`-prefixed paths are a rare escape hatch for genuinely private non-discovered implementation or data helpers — never the primary way to define an aspect.
- Values shared across aspects: declared flake-parts options or `let` bindings. Never `specialArgs`/`extraSpecialArgs`.
- Cross-feature contracts: declared option namespaces (e.g. `services.<name>.*`). Provider and consumer aspects compose by selection/import, never by reading another aspect's internals.
- Large single-owner features split into auto-imported sibling files, not `_` dirs.

## Hard constraints

- **No secrets, no `.sops.yaml`, no encrypted material** in this repo. Every secret enters through a typed `secretFiles.*`-style option the consumer binds.
- **No hostnames, tailnet suffixes, provider endpoints, or cloud defaults.** Provider quirks live in consumer repos. Policy data (endpoint catalogs, publisher lists, builder URLs, S3 coordinates) is consumer-supplied through options.
- **No host records, no `nixosConfigurations`, no deploy tooling.** A single fixture evaluation class for `nix flake check` is allowed and encouraged.
- Fail closed with named errors (`"<aspect>: <specific problem>"`), never raw `builtins.head []`/null derefs.
- jj colocated workflow: anonymous mutable changes off `main@origin`; Git-facing bookmark only at publish time. Never run `git reset`/`git checkout`/`git stash` (destroys the colocated index).

## Validation baseline

- `nix fmt` clean, and it stays clean: `modules/flake/tooling.nix` pins formatter priorities (deadnix < statix < nixfmt) because statix and nixfmt both claim `*.nix` and a tie leaves code that `nix flake check` reports as unformatted. `nix flake check` runs the same treefmt config as a check, so formatting is enforced, not just available.
- `nix flake check` green via the fixture evaluation class.
- Nix reads this repo through the Git index, so **new or deleted files are invisible to `nix flake check`/`nix fmt` until a jj command snapshots the working copy** (`jj st` is enough). Symptom if skipped: a stale evaluation or "path exists on disk, but not in HEAD".
- Every new aspect: typed options with defaults, a named fail-closed assertion for missing required bindings, and at least one mutation-style non-vacuity check in the fixture class where practical.
- Formatting is the published tooling base: prettier for markdown/YAML/JSON, the pinned Nix trio for Nix, taplo for TOML. Consumers extend with their own languages/excludes via `perSystem.treefmt` (list options concatenate) — do not add repo-local md/yaml/json formatters over the base.
- Input pins: this repo's flake.lock is the fleet's shared-input authority once consumers alias via follows; renovate.json here is the fleet's bump cadence.
- Secrets use `lib/secrets.nix` helpers (`mkSecretFileOption`, `mkSecretKeyOption`, `mkRequiredSecretAssertion`, `mkSecretsFromMap`) — the same file nix-homelab uses, so an aspect behaves identically in either consumer.

## Extraction sources

Reference implementations live in the sibling repo `/mnt/LinuxData/Projects/dev/nix-homelab` (read-only reference — do not import its code directly; re-express per the pattern above):

- beszel-agent: `modules/flake/observability-agent.nix` (the hub in `modules/admin/beszel.nix` stays in nix-homelab)
- builder-access: `modules/flake/builder-access.nix` (nixbuild leaf consolidated inline there)
- niks3-cache: `modules/cache/niks3-cache.nix`
- niks3-publisher: `modules/cache/cache-publisher.nix` + `modules/cache/cache-publisher/upload-client.nix` (upstream post-build-hook module; nix-path-filter and post-deploy hooks stay homelab-side)
- notification-daemon: `modules/notifications/notify.nix` + `notify/_events.nix` contract + `pkgs/{notification-daemon,notify,unit-notify}` (redesigned onto native systemd OnFailure/OnSuccess with per-unit policy; not a mechanical port)
- tailscale: `modules/flake/tailscale.nix`

Behaviour parity with those sources is the acceptance bar; repo-local idioms (secret path derivation, policy imports) become typed options.
