# Tasks

## 1. Shared update interface and runner

- [x] 1.1 Add the public `flakeModules.packageUpdates` contributor and typed `perSystem.packageUpdates.packages` option; verify a minimal consumer flake evaluates its own selection and pinned updater without inheriting Bifrost registrations.
- [x] 1.2 Package the shared runner and expose `apps.<system>.update-packages`; verify offline tests cover full-set execution, registered subsets, deterministic order and ordinary versus standard update-script dispatch.
- [x] 1.3 Add named preflight refusals for empty, duplicate, missing and unregistered selections; verify no fixture updater runs on refusal and mutation-style checks catch omitted validation.
- [x] 1.4 Implement fail-fast status reporting without commit/reset/publish side effects; verify a failing second updater leaves prior/partial edits intact, exits nonzero and prevents a third updater from running, including a mutation check for swallowed failures.
- [x] 1.5 Write `docs/contracts/package-updates.md` and index it in the contract documentation; verify documented module import, package selection and local app invocation against the minimal consumer fixture, including failure and trust semantics.

## 2. Bifrost update policy

- [x] 2.1 Verify nix-update source discovery and subpackage handling on Bifrost's actual build-time-split sources; deliver a package-owned update script/upstream metadata integration that refreshes source, Go and npm hashes without evaluation-time source realization.
- [x] 2.2 Declare stable transport-tag selection and expose the UI for hash refresh; verify fixture release data excludes unrelated component tags and prereleases, and missing/unsupported candidates fail rather than silently choosing an older target.
- [x] 2.3 Register only Bifrost as the fleet's initial update owner; verify the Voyage plugin still inherits its exact host source/toolchain/dependency graph and is not independently selected by the batch.
- [x] 2.4 Document Bifrost release selection, coupled hashes and the gateway/plugin acceptance gates in the update contract; verify a recorded-target invocation exercises the package policy through the shared app, not a separate ad-hoc updater.

## 3. Tracked real-update acceptance

- [x] 3.1 Run a real stable transport-release update through the shared app in an isolated checkout; record base commit, updater/toolchain, selected tag, resolved SHA and changed pin files. Verify the diff contains the coherent Bifrost family only; if no real release change is available, leave this acceptance task open and record the limitation.
- [x] 3.2 Build the updated native gateway and plugin and run existing startup/UI, Voyage-hook and governance/CEL module checks; record exact check outputs and reject the candidate if any gate fails.
- [x] 3.3 Repeat refresh against the same recorded target and verify an empty additional diff; record release discovery separately so a moving upstream cannot invalidate the idempotence comparison.
- [x] 3.4 Add a concise acceptance record with observed results and limitations, linked from the contract; verify no production version bump is retained without all gates passing and no consumer source files were edited.

## 4. Repository integration

- [x] 4.1 Expose shared runner/fixture tests through ordinary native `checks.<system>` and verify `nix fmt`, all-system evaluation and the complete native check suite pass; do not add a second build-target catalog.
- [x] 4.2 Run fresh-store evaluation with import-from-derivation disabled and verify updater integration does not force source or cross-system builds at evaluation time; distinguish ARM evaluation from any actual ARM build evidence.
- [x] 4.3 Review the public interface, update diff and recorded acceptance against the spec; verify remaining consumer migration and Actions scheduling/automerge work is clearly deferred, and validate this OpenSpec change strictly before handoff.
