# Proposal

## Why

nix-fleet's update tooling is three disconnected pieces: Renovate opens weekly lock PRs, the scheduled package refresh opens a separate PR, and routine CI only evaluates. Nothing builds the tree that would actually merge, so the cache is warmed for neither candidate and an accepted update can still fail to build. The two PRs also change inputs independently, so a build of either is not a build of the closure that lands.

The fleet needs one lifecycle that produces a complete update, builds and caches that exact revision, and promotes it by repository policy, reusable by the two consumers.

## What Changes

- A native scheduled producer runs `nix flake update` (with an exclusion list), then the registered package updaters against the refreshed lock, and opens or refreshes one PR with a cumulative report. It replaces Renovate's `lockFileMaintenance` and the separate package-refresh PR.
- A shared candidate pipeline treats every update PR the same way: prepare (a no-op or a generated child commit), publish the exact candidate SHA under an automation-owned ref, evaluate, build, verify cache availability, and post an evidence status on that SHA.
- Promotion is a fast-forward push of the validated candidate SHA to `main` by a GitHub App, with no ruleset bypass. A required status on `main` makes GitHub itself reject any push that lacks evidence.
- Promotion policy is an input: `auto` (nix-fleet) or `label` (consumers, bound to the accepted revision).
- Renovate keeps SemVer-tagged flake inputs, Actions, and OCI updates, with its lock maintenance and automerge disabled. It never has its branch modified.
- Routine `ci.yml` evaluation becomes the first stage of the pipeline on the prepared candidate. Human PRs only check generated-file consistency.
- **BREAKING** (internal): `package-updates-refresh.yml` stops opening its own PR; `renovate.json` drops `lockFileMaintenance` and the nix manager.

## Capabilities

### New Capabilities

- `update-candidates`: preparing, building, evidencing and promoting an update revision, including the privilege boundary and the cache check.
- `native-update-producer`: the scheduled lock-then-packages refresh that opens an ordinary PR with a cumulative report.

### Modified Capabilities

None. The `package-updates` requirements live in the unarchived `transactional-package-updates` change; this change consumes that app and does not alter its spec.

## Impact

- `.github/workflows/`: new reusable candidate workflow, a retargeted refresh workflow, `ci.yml` folded into the pipeline's first stage, and a `build-push-cache.yml` input for an explicit candidate SHA.
- `renovate.json`, a GitHub ruleset on `main` and a GitHub App (settings, not code).
- `modules/flake/package-updates.nix` and `pkgs/package-updates/` gain the lock-refresh step and its report; the existing package updaters are reused unchanged.
- niks3 OIDC trust must admit candidate builds, scoped by a GitHub Environment; that policy lives in the consumer homelab repo and is a prerequisite, not part of this change.
- Docs: `docs/contracts/ci.md`, `docs/contracts/package-updates.md`, `context/flake-checks.md`, `context/package-updates.md`.
- Consumers adopt the reusable workflow later; their package updaters and policy are outside this change.
