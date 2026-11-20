# Design

## Context

See proposal.md for motivation and specs/package-updates/spec.md for the behavioral contract.

nix-fleet publishes implementation packages from `modules/flake/packages.nix` and public flake-parts modules such as `flakeModules.fleet`. Files under `modules/` are auto-imported flake-parts contributors. The existing native `checks.<system>` include real Bifrost startup/UI, Voyage-plugin and governance/CEL module checks.

Bifrost currently pins transport version 2.2.5 and source commit 77d08f24 in `pkgs/bifrost/default.nix`, with a Go vendor hash and an npm hash in `ui.nix`. Its source is split with build-time derivations to avoid evaluation-time source realization. `mkPlugin` inherits the host toolchain and shared dependency graph. Those properties must survive updater integration.

The read-only dotfiles inventory found more than the three nvfetcher entries. Those three cover binary tarballs only. Other locally pinned families include pi-bolt (npm plus runtime/catalog pins), approximately 18 npm plugin tarballs plus a GitHub plugin, and three Neovim plugins. There are also flake-input packages, an OCI digest and a host NVIDIA pin; these are not all native packages owned by this proposed registry. The inventory is bounded evidence, not an exact exhaustive artifact count. It confirms that bare nix-update cannot infer every downstream policy.

## Goals / Non-Goals

**Goals:**

- One small fleet-owned update interface, usable locally before Actions automation exists.
- Ordinary nix-update behavior plus conventional package update scripts for unusual feeds and coupled sources.
- Bifrost as the first implementation and runtime acceptance case, not as the shape of every consumer package.
- Clear errors and provenance without hidden VCS mutation or a second package-update engine.

**Non-Goals:**

- A generic dependency graph, datasource registry, automatic discovery of all pins or a replacement for nvchecker inside fleet.
- Updating upstream packages merely consumed through flake inputs, or modifying host-policy pins such as NVIDIA automatically.
- Consumer migration, schedules, bot credentials, GitHub branch rules or automerge configuration in this slice.
- Combining flake-lock and package refresh writers yet; native updates leave lockfiles and OCI policy untouched.
- Changing builder selection, niks3 publication or deployment behavior.

## Decisions

### Public module, explicit selection, one app

Publish `flakeModules.packageUpdates` from `modules/flake/package-updates.nix`, following the existing reusable flake-module pattern and dogfooding it in this repository. Its typed option is `perSystem.packageUpdates.packages`, a list of owned `packages.<system>` attribute names, defaulting to an empty list. This repository registers `bifrost`; consumers register their own sets later. The app is `apps.<system>.update-packages`.

No arguments updates the full registered set. Optional package names select a registered subset. Validate the entire effective selection before running anything: no empty set, duplicates, unknown names or missing output. Use a stable lexical order. The app runs from the current checkout and addresses that checkout's flake outputs, not files in the Nix store.

Use one shared runner under `pkgs/package-updates/` with a directory-import entrypoint and focused tests under `tests/package-updates/`. Package the evaluated `pkgs.nix-update` and required tools into its execution environment; do not resolve updater tools through a floating registry. Do not expose alternate engines or arbitrary command strings in the registry.

**Alternative:** duplicate a small loop in each repo. Rejected because failure semantics, validation and tool pinning would drift. **Alternative:** a generic catalog of every pin. Rejected because package update scripts already provide the exceptional-policy interface.

### Package expressions own their update policy

The runner uses standard nix-update for an ordinary package. When a selected derivation declares `passthru.updateScript`, use nix-update's supported script invocation rather than guessing its custom source structure. Package scripts are trusted repository code, not a sandbox; they must not commit, reset, publish or deploy. Both paths share selection, execution ordering and failure reporting.

Bifrost gets a package-owned update script with a stable transport-tag filter. The script controls its shared upstream version/revision, source hash, Go dependency hash and UI npm hash. Expose the UI to nix-update through passthru for its supported subpackage handling. Preserve build-time subtree extraction; expose upstream metadata or use the package script as necessary rather than introducing import-from-derivation to satisfy updater discovery. Verify actual nix-update behavior on this derived-source layout before relying on a one-line invocation.

Custom release discovery, binary downloads, registry SRI values and coupled runtime/catalog pins can later use the same standard script interface. That is package policy, not a second updater pipeline. Do not carry dotfiles feed URLs or its package list into fleet defaults.

**Alternative:** nvfetcher across all repos. Its source catalog and broad discovery remain useful, but it does not replace all the Go/npm hash-refresh operations needed here. **Alternative:** retain both engines indefinitely. Rejected as the target state; consumers keep existing nvfetcher only until their later adoption slice verifies replacement policy.

### Refresh is not acceptance or merge policy

The app edits package pins and reports update status. It does not create branches/PRs, write flake.lock, invoke full repository builds, merge or deploy. Partial edits remain on failure; stop immediately and return nonzero, without automatic rollback commands that would destroy unrelated working-copy work.

Future automation can invoke the same app after its chosen lock refresh and run one acceptance pipeline after the complete candidate diff. Exactly one writer must own each file. Renovate remains appropriate for OCI/images and Actions. Lock ownership is a future automation choice, not an implicit side effect of this app.

Fleet automerge versus consumer manual adoption belongs to the calling automation; no per-repo merge switches belong in the native-package runner. Cache publication remains builder hooks and niks3-action; there is no coordinator collection/upload addition.

### Acceptance has offline checks and one tracked real experiment

Add offline runner tests using fixture updater commands and a minimal consumer flake. Cover successful default execution, subset selection, custom update-script dispatch, full preflight refusal, failure ordering and preserved edits. Mutation checks must prove missing selection validation and swallowed updater failures would be caught. Regular flake checks must not query moving upstream releases.

For Bifrost, run a real update in an isolated checkout, recording base commit, exact updater/toolchain, selected tag and resolved upstream SHA, changed pin files, and validation results. Use a real stable transport-release change when available; same-version hash refresh alone is not proof of release selection. If no usable release change is available, report that acceptance limitation rather than marking it complete. A newer unsupported release must fail visibly rather than silently selecting an older one.

Run all existing Bifrost binary/runtime gates, formatting, all-system evaluation and fresh-store evaluation with IFD disabled. Re-run against the same recorded target to prove idempotence. Keep an updated production pin only if all acceptance gates pass; no unrelated consumer updates accompany it. Expose tests through ordinary `checks.<system>` rather than defining a second build-target catalog.

## Risks / Trade-offs

- **Derived sources hide upstream metadata from nix-update** → Test this exact packaging layout and use the standard package script; never replace build-time extraction with evaluation-time filtering.
- **Latest transport requires a new toolchain or packaging changes** → Surface failure and record the required intervention; do not weaken ABI/runtime checks.
- **Different downstream package families need more than source-hash edits** → Leave selection and policy explicit; later adoption must verify npm SRI, custom feeds and coupled pins through package scripts.
- **Trusted scripts can modify unrelated files** → Review package scripts and validate observed update diffs; do not promise filesystem confinement merely from registered package selection.
- **Network release discovery changes over time** → Record exact candidate targets; distinguish discovery runs from same-target idempotence runs.
- **Batch failure leaves a partial diff** → Nonzero status rejects the whole candidate; preserve evidence instead of destructive automatic rollback.

## Migration Plan

1. Implement and document the shared module/app and offline contract tests in nix-fleet.
2. Register Bifrost and complete the tracked real update experiment and acceptance gates.
3. Publish only after review and explicit approval. Existing consumer workflows remain unchanged.
4. In separate adoption changes, enumerate each consumer's owned package families, register them, and implement any needed standard update scripts. Remove nvfetcher/config/generated metadata only when all currently covered sources have verified replacements.
5. Configure refresh scheduling, PR creation, combined lock ownership and merge rules separately using the proven entry point.

Rollback of this opt-in mechanism consists of removing the import/selection and reverting updater integration. No automatic rollback of user work or deployed services is involved.
