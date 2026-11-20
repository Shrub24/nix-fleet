# Proposal

## Why

nixbot is the fleet's CI, but adopting it meant copying one repository's effects and
hand-writing its cache rule, its allowlist entry, its ruleset and its project
enablement. Only flake.lock-and-nix-update repositories could take the update
effect, and the cache kept everything for 30 days, so retention was not the point
of pins. The CI should be one interface any repository implements, with the
operator's side derived from one list.

## What Changes

- **`flakeModules.ci`** (replaces `flakeModules.nixbotEffects`): the repository
  interface. Effects are entries of `ci.effects`, the fleet's included, merged and
  overridden by the module system; retention gains release pins per tag and kept
  generations; updates are on by default; `checks.cache-root` is contributed.
- **Updates**: `packageUpdates.commands` and `packageUpdates.lockfiles` (cargo,
  bun, npm) run in the same transaction as packages; an empty registry refreshes
  `flake.lock` instead of refusing.
- **`packages.ci-enrol`**: enrol or withdraw a repository (project enablement,
  auto-merge, `nixbot` ruleset) without an instance deploy, configured from the
  canonical instance facts (`lib.ci.instance`).
- **`services.niks3-cache`**: a release rule per repository beside the retention
  rule; `gc.olderThan` becomes an option.
- **`templates.ci`**: a new repository's starting flake, CI inputs in a flake-parts
  partition so consumers never lock them.
- **No `nixbot.toml`**: nixbot's defaults are the policy.

## Impact

- New: `modules/flake/{ci,ci-checks,ci-enrol,templates}.nix`, `lib/ci.nix`,
  `pkgs/ci-enrol`, `templates/ci`, `docs/contracts/federated-ci.md`.
- Removed: `flakeModules.nixbotEffects`, `lib.nixbotEffects`,
  `docs/contracts/nixbot-effects.md`.
- Consumers: nix-homelab moves to `flakeModules.ci` and derives its nixbot service
  from the canonical instance facts; other repositories adopt the interface when
  enrolled; nix-dotfiles installs `ci-enrol`.
