# Tasks

## 1. Baseline specs

- [x] 1.1 Archive `fleet-package-update-contract`, `transactional-package-updates` and
      `federated-ci`, carrying their open tasks into this change or a named note; verify
      `openspec list --specs` lists `federated-ci` and `package-updates`.

## 2. One module

- [x] 2.1 Move `modules/flake/ci.nix`, `cache-root.nix` and `package-updates.nix` into
      sibling files under `modules/ci/` contributing to `flakeModules.ci`; delete the
      `cacheRoot` and `packageUpdates` exports; verify `nix eval .#flakeModules --apply
builtins.attrNames` lists `ci`, `fleet`, `tooling` only.
- [x] 2.2 Declare `ci.updates.packages.<name> = { paths; reason; }`, `lockfiles` and
      `commands` at flake level and render one registry for every system; remove
      `writeSets` and `deferredInputs`; verify the runner tests pass and a `paths` without
      `reason` fails with its named error.
- [x] 2.3 Rename the batch app to `update-all`; verify `nix run .#update-all -- --help`
      runs and `update` still opens the picker.
- [x] 2.4 Move nix-fleet's adoption to `modules/flake/ci.nix` and register bifrost
      through `ci.updates.packages`; verify `nix flake check` and that `herculesCI` still
      yields `cache-retain`, `cache-release` and `package-updates`.
- [x] 2.5 Update `templates.ci` to one `modules/flake/ci.nix` importing only
      `flakeModules.ci`; verify an instantiated template evaluates `cache-root` and its
      effects.

## 3. Input policy

- [x] 3.1 Declare `flake-file.inputs.<name>.update = { version; versionRegex; reason; }`
      from `flakeModules.ci`, with a named failure for `fixed` without `reason` and for a
      regex without one capture group; add a check over flake-file plus `flakeModules.ci`
      proving the option merges, the generated `flake.nix` is unchanged by an override,
      and each failure fires (mutation: remove the guard, the check fails).
- [ ] 3.2 Export each input's override and repository-relative declaring file in the
      registry; verify on dotfiles that `hermes-agent` maps to
      `modules/agents/hermes.nix`.

## 4. flake-edit

- [x] 4.1 On a `Shrub24/flake-edit` branch, add per-input `version_regex` (patch A)
      with upstream-style tests; verify `cargo test` passes and a regex without one capture
      group is rejected.
- [x] 4.2 Add release selection (patch B): latest-release marker, else
      same-prefix `VersionReq` matching with pre-releases excluded unless allowed; add
      tests for the hermes, numen and noctalia tag sets; verify `cargo test` passes and
      `flake-edit --diff --no-lock update` on dotfiles proposes `v0.23.3` for hermes-agent.
- [ ] 4.3 Package `flake-edit` in nix-fleet as nixpkgs' with both patches as patch
      files; verify it builds on x86_64 and aarch64.
- [ ] 4.4 Open patches A and B upstream on `a-kenji/flake-edit`; record the PR links in
      `pkgs/` beside the patches.

## 5. Runner

- [x] 5.1 Classify each input as `stable`, `branch` or `fixed` from its remote and
      apply overrides; verify tests for a tag, the `nixos-25.11` branch, a `rev` pin, and
      an explicit request moving a `fixed` input.
- [x] 5.2 Run flake-edit with a generated config for `stable` and `unstable` inputs;
      verify tests against a stubbed flake-edit and forge for each policy value.
- [x] 5.3 Write moves back to the declaring file, regenerate with `write-flake`,
      compare the regenerated `inputs`, and relock only moved inputs; verify tests for a
      module declaration, a plain `flake.nix`, a doubled literal (named failure, others
      proceed) and a write-flake mismatch; mutate the occurrence count, the tests fail.
- [x] 5.4 Report each moved input with old → new, compare link and release link, and
      each failed input with its reason; verify the report tests.
- [x] 5.5 Run the batch with the `forge-read` secret as `GITHUB_TOKEN` and a Nix
      access token, keeping the push token out of it; verify `ci-updates` with a batch
      stub that fails without the read-only token or with the push token in its
      environment.

## 6. Documentation

- [x] 6.1 Render the `ci` option reference to `docs/reference/ci-options.md` with a
      `write-ci-reference` app and a drift check; verify the check fails after editing a
      description without regenerating.
- [x] 6.2 Fold `docs/contracts/package-updates.md` into `federated-ci.md`: ownership
      (repo CI file, owning feature, derivation, input declaration), policy values,
      write-back, the token, Renovate's remaining scope; verify no remaining reference to
      `packageUpdates`, `cacheRoot`, `writeSets`, `deferredInputs` or `update-packages`
      outside archived changes.

## 7. Consumers

- [ ] 7.0 nix-homelab: bind `forge-read` for `github:Shrub24/*` in
      `services.nixbot.effects.perRepoSecretFiles` from `github/token` and deploy
      home-forge; verify the rendered secrets file has the key.
- [ ] 7.1 nix-homelab PR: bump nix-fleet, migrate to `ci.updates` in
      `modules/flake/ci.nix` (from `modules/ci/effects.nix`), remove Renovate's
      `github-tags` and `github-releases` managers; verify nixbot checks pass and a
      scheduled run moves `degoog` `1.1.1 → 1.2.0`.
- [ ] 7.2 nix-dotfiles PR: the same migration with hermes-agent, noctalia, numen and
      vicinae under input policy; verify nixbot checks pass and a scheduled run moves at
      least one tag through its declaring module.
