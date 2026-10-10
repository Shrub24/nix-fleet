# Tasks

## 1. Write-set contract and package registration

- [x] 1.1 Add an optional write-set to package registration with package-local defaults; verify typed module evaluation covers default and explicit shared-path declarations and rejects invalid paths.
- [ ] 1.2 Trace Bifrost's updater writes for a recorded target and declare the narrow effective set (or restructure duplicated configuration to derive from the package source); verify a real staged diff is wholly inside the declared set.
- [x] 1.3 Document package-local ownership, explicit shared exceptions with rationale, and the limits of repository-file rollback in `docs/contracts/package-updates.md`; verify examples match the registration interface.

## 2. Isolated per-package update transactions

- [x] 2.1 Implement disposable jj-workspace staging from the caller's current working copy without rewriting caller commits or bookmarks; regression-test that an initial caller edit is present in the candidate and that successful updates apply cumulatively. Temporary workspace changes are recorded in jj's operation log.
- [x] 2.2 Validate updater outputs against declared paths; verify an undeclared write is rejected without modifying the original workspace.
- [x] 2.3 Apply a successful package result before staging the next package; verify later updaters observe prior successful edits and overlapping package ownership cannot silently replace them.
- [x] 2.4 Discard a failed package's staged repository changes and continue to later packages; verify a failure after multiple writes leaves no candidate changes while earlier successful changes survive.
- [x] 2.5 Extend offline runner tests for transaction and continuation cases; verify structured/stdout reports include every selected package, concise failure details, reports are written on partial failure, and the batch exits nonzero if any package fails.

## 3. Integration and acceptance

- [x] 3.1 Run formatting, focused package-update runner/consumer checks, `nix flake check`, and `nix flake check --no-build --all-systems`; record results and verify no check or output is dropped.
- [ ] 3.2 Run the Bifrost updater in an isolated checkout for a recorded target and repeat for idempotence; verify success retains only declared changes and an induced mid-update failure leaves no partial repository changes.
- [x] 3.3 Review the final diff and strict OpenSpec validation; verify no automatic jj commit/reset/publish behavior and no claim of rollback for external side effects.
