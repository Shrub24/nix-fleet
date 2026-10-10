# Design

## Context

See [proposal.md](proposal.md) for motivation and the package-updates spec delta for observable behavior. The current runner calls each updater in the caller's working tree, snapshots `git status --porcelain` only to classify the report, and stops at the first nonzero exit. Package policy can be a nix-update invocation or a trusted `passthru.updateScript`; Bifrost's script currently edits `pkgs/bifrost/default.nix` and invokes nix-update for its UI dependency hash. The repository uses jj colocated with Git, and pre-existing user changes must not be reset or overwritten.

## Goals / Non-Goals

**Goals:**

- Make one package's candidate file changes the unit of commit-to-working-copy or discard.
- Continue through independent selected packages while retaining successful earlier results.
- Enforce narrow path ownership by default, with reviewed explicit exceptions for shared paths.
- Preserve the caller's initial working-copy state and detect conflicts at safe integration boundaries.

**Non-Goals:**

- Roll back network requests, external service changes, process side effects, or other actions outside the staged checkout.
- Run package updaters concurrently.
- Require all package definitions to be relocated into per-package directories as part of this change.
- Create jj commits, bookmarks, branches, or publish changes automatically.

## Decisions

### Use per-package staged filesystem snapshots, not VCS mutation

Stage one package attempt from the current repository state into an isolated temporary tree. Run the normal shared updater there; collect the resulting file changes and validate their paths against that package's declared write set. If the updater exits nonzero or validation fails, remove the staged tree and record failure. If it succeeds, integrate its allowed changes into the caller's working copy before starting the next package.

The implementation uses a disposable jj workspace based on the caller's current working copy, so uncommitted edits are present in the candidate baseline. Successful declared paths are copied back into the original workspace; failed candidates are forgotten. It does not create commits or rewrite jj history. Promotion is file-level and is not crash-atomic across multiple files. The runner requires jj and is not a filesystem-independent transaction engine. It does not sandbox or roll back external side effects.

**Alternative:** run scripts in the caller's tree and attempt to undo changes on failure. Rejected because restoring from a baseline risks deleting unrelated user edits and cannot distinguish a script's partial writes from pre-existing changes. **Alternative:** create temporary jj commits/workspaces and abandon or squash them. Rejected as the initial implementation because it would couple a package app to jj workspace mutation and make its safety depend on concurrent working-copy state; retain as a fallback only if filesystem staging cannot satisfy the preservation requirements.

### Keep the batch sequential and cumulative

Process selected packages in the existing deterministic lexical order. After one successful package result is applied, start the next staged attempt from the new effective tree. This preserves current behavior where later package updates can see earlier edits, while keeping rollback local to the current package. A failed package does not prevent later packages from running, but the batch exits nonzero after reporting all outcomes.

### Declare constrained path ownership

Extend each package registration with an optional write-set override. Without one, derive the default package root from the package registration/definition convention; reject registrations for which this boundary cannot be determined, rather than silently granting the repository root. Explicit shared files/directories require a reason recorded adjacent to registration. Before applying a successful result, compare its complete changed-path set to its allowed write set. Also detect ownership overlap among selected packages; serial execution alone does not make two declarations for the same path safe, because later writes could overwrite earlier successful results.

The existing Bifrost policy must be mapped before selecting its final default: confirm whether the UI hash edit lies under the Bifrost package directory and enumerate all paths its real updater changes. If a path is structurally shared, declare that narrow exception. Prefer deriving repeated config from Bifrost's package output instead of widening the write set solely to keep a duplicate pin synchronized.

### Surface per-package outcomes in reports

Represent every selected package as updated, unchanged, or failed. Failures include a concise updater exit/diagnostic and any rejected path/conflict. Preserve the successful entries and report artifacts even when the overall batch exits nonzero. Keep the human and machine report ordered by the selected deterministic order.

## Risks / Trade-offs

- **Filesystem staging misses a file type or metadata change** → Tests cover additions, modifications, deletions, renames, executable bits, symlinks and untracked files; if the chosen mechanism cannot preserve a class safely, reject it explicitly.
- **Applying multiple files can be interrupted partway through** → Stage a complete validated package result and use per-file atomic replacement where possible; detect/report an interrupted application and do not claim process-crash atomicity for a multi-file tree. A directory swap may provide a stronger boundary only when the complete package directory is exclusively owned and replacement semantics are safe.
- **A script writes outside its declared set through an absolute path or external command** → Repository diff validation catches checkout writes, not arbitrary filesystem effects; retain the trusted-script restrictions and do not claim sandboxing.
- **Initial working copy changes during a run** → Capture the baseline and re-check target paths before applying each package; on a conflicting concurrent edit, fail that package without touching the conflict.
- **Many package definitions are flat or shared today** → Write-set defaults need to reflect actual repo layout, not an assumed `pkgs/<name>/` convention; migration can explicitly declare narrowly owned flat files or defer enforcement for an unclassifiable package only if the spec permits it.

## Migration Plan

1. Add write-set policy to package registration and classify Bifrost's observed updater paths; test validation independently before changing batch semantics.
2. Implement staging and path-validation utilities with adversarial fixtures for user edits, updater failure after multiple writes, undeclared paths and conflicts.
3. Change the runner to process packages independently and emit the complete result report; preserve the existing CLI flags and overall nonzero-on-any-failure convention.
4. Document package-local ownership, explicit exceptions, jj working-copy preservation and the external-side-effect limit.
5. Run focused tests, formatting, package-update check, all-system evaluation, and a real isolated Bifrost update/idempotence experiment.

Rollback consists of reverting the runner/module change; no automatic cleanup or history mutation should be required in the user's working copy.
