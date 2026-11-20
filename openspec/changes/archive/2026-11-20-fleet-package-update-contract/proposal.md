# Proposal

## Why

Native package updates need one fleet-owned process, not separate nvfetcher and ad-hoc workflows in each repository. Bifrost currently has no automated updater, and its shared upstream source, Go dependencies, embedded npm UI and host-locked plugin make it a useful first acceptance case.

## What Changes

- Publish an opt-in flake-parts module, `flakeModules.packageUpdates`, with a typed per-system package selection and an `apps.<system>.update-packages` batch entry point.
- Use nix-update from the evaluated repository's pinned nixpkgs. Ordinary packages use its standard update behavior; package-specific policy uses the conventional `passthru.updateScript` interface.
- Define shared policy: explicit package ownership, one update writer per package, stable release selection unless explicitly overridden, deterministic batch order, named refusal for invalid selections and nonzero status for any failed update. A failed batch is not an acceptable candidate.
- Register Bifrost as the first fleet package. Update its transport release, shared source hash, Go vendor hash and UI npm hash together; derived Voyage plugins inherit the host update rather than updating independently.
- Prove the contract with offline batch-runner tests and a tracked real Bifrost update experiment, followed by its existing binary/runtime checks and fresh-store evaluation.
- Document how downstream repositories adopt the same contract later. Keep Renovate responsible for OCI images and Actions references; native-package refresh does not claim flake.lock ownership in this change.

## Capabilities

### New Capabilities

- `package-updates`: Fleet-wide native-package update selection, execution, package policy and candidate acceptance, initially exercised on Bifrost.

### Modified Capabilities

None.

## Impact

Implementation will add a public flake-parts contributor, the shared batch runner and regression checks, Bifrost update policy, and `docs/contracts/package-updates.md`. Existing Bifrost outputs and the nix-fast-build/cache-publication interface remain compatible.

This change does not migrate dotfiles or nix-homelab, remove their nvfetcher wiring, configure GitHub schedules/credentials/branch rules/automerge, deploy services, or introduce a system-manager class. Consumer inventory informs the interface and later adoption; it does not enlarge this first implementation slice.
