# Design

## Context

`flakeModules.ci` (`modules/flake/ci.nix`) imports two further published modules,
`flakeModules.cacheRoot` and `flakeModules.packageUpdates`. The update registry is
declared per system and reaches the runner as a JSON file named by
`PACKAGE_UPDATES_REGISTRY`. The runner refreshes every flake input not listed in
`deferredInputs` with `nix flake update`, which keeps each input's declared ref, so a
tag pin never moves. Both consumers import `packageUpdates` a second time. flake-file
declares `flake-file.inputs` as `lazyAttrsOf (submodule …)` and renders an explicit
list of attributes into `flake.nix` (`inputsExpr`), so an extra option on an input is
kept out of the generated file; its own per-input `autoFollow` already works this way.
flake-edit 0.4.0 (nixpkgs) chooses the semver maximum over the newest tags and never
consults releases; on dotfiles it chose `rc.13-v0.23.2` for hermes-agent, whose latest
release is `v0.23.3`.

## Goals / Non-Goals

**Goals:**

- One module, one namespace, one place per kind of fact.
- Tag-pinned inputs move inside the existing transaction, with its write sets,
  rollback and report.
- Upstream tools do the version work; nix-fleet carries only the flake-file
  write-back.

**Non-Goals:**

- Coupled follow-up commands after an input moves (Pi-Bolt.nix's runtime refresh).
  Deferred to that repository's adoption.
- Image digests and Actions pins: Renovate keeps them; they rebuild little.
- Upstreaming module-file editing to flake-edit or an `update` command to flake-file.
  Offered upstream once the write-back has run in practice.

## Decisions

### One module of sibling files

The implementation moves to `modules/ci/` as sibling files contributing to
`flake.modules.flake.ci`: `instance.nix`, `retention.nix` (owning `cache-root`),
`updates.nix`, `effects.nix`, `reference.nix`. `flakeModules.packageUpdates` and
`flakeModules.cacheRoot` are deleted outright. nix-fleet's own adoption moves from
`modules/flake/ci-adoption.nix` to `modules/flake/ci.nix`, the path consumers use.
Keeping the three exports was rejected: no repository uses one without the others,
and two consumers already import one twice.

### Registry at flake level

`ci.updates.packages`, `lockfiles` and `commands` are flake-level options. The update
apps stay per system and read the same rendered registry. `packages.<name>` takes
`paths` and `reason`, replacing `writeSets`; a non-empty `paths` without a `reason`
fails as today.

### Input policy on the flake-file declaration

`flakeModules.ci` declares `update = { version; versionRegex; reason; }` on
`flake-file.inputs.<name>`. The module system merges it into flake-file's submodule;
`inputsExpr` never renders it. The declaration is unconditional: in a repository
without flake-file the option exists alone and still carries overrides, though no
file renders it. Alternatives rejected: a `ci.updates.inputs` table keyed by name
(drifts when an input is renamed or removed), comment markers (unevaluated, untyped,
and the generated `flake.nix` would have to carry them), extra attributes in
`flake.nix` inputs (Nix rejects them), overlays (they modify packages, not inputs).

### The default comes from the remote

An input is `stable` when its ref is a tag on its remote (`git ls-remote --tags`),
`branch` when the ref is a branch or absent, and `fixed` when a `rev` is pinned. A
name-shape heuristic was rejected: `nixos-25.11` looks like a version and is a branch.

### flake-edit resolves; two patches make it standard

The runner writes a flake-edit config carrying each input's `versionRegex` and runs
`flake-edit update --no-lock` for the `stable` and `unstable` inputs, as flake-file
already runs `flake-edit follow` with a generated config. Two changes to flake-edit:

- **A:** a per-input `version_regex` in its config, filtering tags and extracting the
  compared version with one capture group (nix-update's `--version-regex`).
- **B:** select the forge's latest-release marker when the repository publishes
  releases, else the highest tag of the current prefix by `semver::VersionReq`
  matching, which excludes pre-releases unless the input is `unstable`.

Both are written on a `Shrub24/flake-edit` branch, offered upstream, and applied in
nix-fleet as `fetchpatch` over nixpkgs' `flake-edit` until a release carries them. A
resolver inside the runner was rejected in favour of the upstream tool.

### Write-back to the declaring file

flake-edit edits only top-level `flake.nix` inputs. For a flake-file repository the
runner:

1. Runs flake-edit on a scratch copy of the generated `flake.nix`, and reads each
   moved input by importing both copies' `inputs`.
2. Finds the declaring file from the registry, which records
   `options.flake-file.inputs.<name>.url.definitionsWithLocations` as a
   repository-relative path.
3. Replaces the URL literal there, failing the input unless it occurs exactly once.
4. Runs the repository's `write-flake` app and checks the regenerated `inputs` equal
   flake-edit's.
5. Relocks only the moved inputs.

A repository without a `write-flake` app takes flake-edit's edit of `flake.nix`
directly. Every written path joins the input's write set, so the transaction's
existing ownership check covers it.

### A read-only forge token for tag lookups

flake-edit reads tags and releases through the GitHub API and honours `GITHUB_TOKEN`.
The update effect gains a secret, `forge-read`, a read-only token the operator
provides beside the push token, exported only to the flake-edit step. Registered
commands and update scripts keep their credential-free environment. Without the
token the lookup is anonymous; a rate-limited input fails by name and the rest of the
transaction proceeds.

### Package policy stays on the derivation

Packages keep `passthru.updateScript` (`nix-update-script { extraArgs = [ … ]; }`),
the nixpkgs mechanism the contract already requires. A `ci.updates` policy option for
packages was rejected: it would duplicate that mechanism and be lost when a package
moves to nixpkgs.

### A generated option reference

`reference.nix` renders every `ci` option, with its description, type and default,
into markdown with nixpkgs' options documentation renderer, evaluated over the module
alone. A `write-ci-reference` app writes `docs/reference/ci-options.md` and a check
fails when the committed file differs, as `check-flake-file` does for `flake.nix`.

### App names

The batch app becomes `update-all`, since it updates inputs, lockfiles and commands
as well as packages; `update` stays the interactive picker. The effect calls the
runner directly and is unaffected.

## Risks / Trade-offs

- [flake-file renames `flake-file.inputs` or adds its own `update`] → a composition
  check evaluates the merged submodule and the rendered `flake.nix`; a collision
  fails there.
- [The latest-release marker and nix-update's release feed can disagree] → the
  runner's tests feed both backends the same tag and release fixtures per policy.
- [A nixpkgs bump breaks the flake-edit patches] → the build fails loudly; the patches
  are rebased or dropped once a release carries them.
- [Classification needs the network] → an unreachable remote fails that input by name.
- [Literal write-back is textual] → it is confined to one file, demands exactly one
  occurrence, and is checked against the regenerated `inputs`.

## Migration Plan

1. nix-fleet: module, runner, patches, reference and its own adoption land together;
   `nix flake check` green.
2. The operator adds the `forge-read` secret to the nixbot instance. Until then, tag
   lookups are anonymous.
3. nix-homelab and nix-dotfiles, one PR each: bump nix-fleet, migrate to `ci.updates`,
   move overrides onto their input declarations, delete `deferredInputs`, remove
   Renovate's tag managers. Each is accepted after one scheduled run moves a tag.

Rollback is reverting a consumer's nix-fleet pin; nix-fleet keeps no compatibility
path for the removed modules.
