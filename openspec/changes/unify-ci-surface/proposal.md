# Proposal

## Why

A repository's CI is configured through two namespaces at two scopes: `ci.*`
(retention, schedule, publishing) at flake level, and `perSystem.packageUpdates.*`
(what to update) per system, from three published modules. Flake inputs pinned to a
release tag never move: the lock refresh keeps their ref, and Renovate tracks only the
few that have a hand-written regex manager, without regenerating `flake.nix` or
relocking. Input update policy belongs next to the input it governs.

## What Changes

- **BREAKING** One public module and one namespace. `flakeModules.ci` owns the whole
  surface at flake level: `ci.instance`, `ci.retention`, `ci.updates`, `ci.effects`.
  `flakeModules.packageUpdates` and `flakeModules.cacheRoot` are removed.
- **BREAKING** `perSystem.packageUpdates.*` moves to `ci.updates.*`:
  `packages.<name> = { paths; reason; }` replaces the `packages` list and
  `writeSets`; `lockfiles` and `commands` keep their shape; `deferredInputs` is
  removed in favour of an input's `fixed` policy.
- Every flake input follows a version policy: `stable`, `unstable`, `branch` or
  `fixed`, with an optional `versionRegex`. Its default is derived from the locked
  ref, so most inputs declare nothing. Overrides are declared on the input's
  flake-file declaration (`flake-file.inputs.<name>.update`), never rendered into
  `flake.nix`.
- Tag-pinned inputs move to their newest matching release through flake-edit, in the
  same transaction and pull request as everything else. The file that declares the
  input is the one edited; `flake.nix` is regenerated and only the moved inputs are
  relocked. The report gives each move with its compare link and release notes.
- Package version policy stays on the derivation (`passthru.updateScript`,
  `nix-update-script` arguments): the existing contract, now stated for the unified
  surface.
- The interface is documented by an option reference generated from the module, kept
  current by a check.
- **BREAKING** The batch app is renamed `update-all`; `update` stays the interactive
  picker.
- Consumers declare their CI in one `modules/flake/ci.nix`; `templates.ci` shows it.

## Capabilities

### New Capabilities

- `input-version-policy`: how each flake input's update target is chosen, where its
  policy is declared, and how a moved tag is written back and relocked.

### Modified Capabilities

- `federated-ci`: the interface becomes one module and one flake-level namespace,
  and documents itself.
- `package-updates`: the registry moves to `ci.updates` at flake level, write sets
  join their package, and deferral becomes input policy.

## Impact

- nix-fleet: `modules/flake/ci.nix`, `cache-root.nix` and `package-updates.nix` split
  into sibling files under `modules/ci/`; nix-fleet's own adoption moves to
  `modules/flake/ci.nix`; `bifrost-updates.nix` registers through `ci.updates`.
- `pkgs/package-updates`: input policy, the flake-edit source, write-back, the
  report section, the renamed app.
- flake-edit, carried as patches over nixpkgs' package until upstream releases them:
  per-input `version_regex`, and release selection by the forge's latest-release
  marker with standard pre-release exclusion.
- The update effect reads tags through a read-only forge token, a new nixbot effect
  secret on the instance.
- Consumers (nix-homelab, nix-dotfiles): one PR each to migrate to `ci.updates`,
  move overrides onto their input declarations, and drop Renovate's tag managers.
  Renovate keeps image digests and Actions pins.
- `docs/contracts/federated-ci.md` absorbs `package-updates.md`; a generated
  `docs/reference/ci-options.md`.
