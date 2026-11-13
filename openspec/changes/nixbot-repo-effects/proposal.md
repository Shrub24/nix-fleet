# Proposal

## Why

nixbot is live as nix-homelab's CI, cache and pin plane, but the repository-side
half exists only in homelab: the main-push retention effect, the scheduled update
transaction and its publish helper are homelab files with homelab coordinates
inlined. The cache's trust rules run the other way: `niks3-cache` in homelab
grants all six repositories write and pin rights through Actions workflow
claims that are being retired, and grants exactly one repository a nixbot rule,
hand-written with the effect name and pin namespace restated.

Every other repository that moves to nixbot would copy those effect files and
add another hand-written rule. Retiring the Actions rules first would silently
remove cache write for five repositories.

## What Changes

- **`flakeModules.nixbotEffects`** (new): a flake-parts module that owns a
  consumer's `herculesCI` output and renders it from typed options:
  - `cacheRetain`: on a push to the repository's default branch, push each
    system's `cache-root`, move its rolling pin, and prove the root can be
    substituted from the public cache.
  - `packageUpdates`: a scheduled transaction running
    `update-packages --refresh-inputs`, pushing one automation branch and
    opening or updating one pull request, optionally with auto-merge.
  - `extra.onPush` / `extra.onSchedule`: consumer effects rendered beside
    the fleet's.
- **`lib.nixbotEffects`** (new): the claim shape the module produces — the
  retention effect's workload-identity name and the pin-namespace function — so
  the cache server and the consumers read one definition.
- **`services.niks3-cache.nixbot`** (new option on the existing aspect): issuer,
  audience and a repository list; renders one nixbot OIDC rule per repository
  from `lib.nixbotEffects`, with pin namespaces checked disjoint.
- The nixbot flake input moves to nix-fleet's lock as the shared-input
  authority; consumers follow it.

## Capabilities

### New Capabilities

- `nixbot-repo-effects`: per-repository nixbot effects and the cache trust rules
  derived from them.

## Impact

- New: `modules/flake/nixbot-effects.nix` (+ `-checks.nix`),
  `pkgs/nixbot-update-publish`, `lib/nixbot-effects.nix`,
  `docs/contracts/nixbot-effects.md`; the effect contract tests moved from homelab.
- Changed: `modules/cache/niks3-cache.nix` gains `nixbot`; `flake.lock` gains
  `nixbot`.
- Consumers: nix-homelab replaces `modules/ci/{effects,_cache-retain,_package-updates}.nix`
  with the module and its hand-written nixbot rule with a repository list. Pin
  names are unchanged.
- Not changed here: the Actions rules (`ciRepositories`) and the GHA workflow
  stack; each is retired per repository after its first observed nixbot main
  cycle. The nixbot service aspect stays in homelab (one instance).
