# package-updates Specification

## Purpose

One shared update engine every fleet repository uses to refresh the packages it owns, with explicit ownership, per-package release policy and transactional staging.

## Requirements

### Requirement: Shared package-update entry point

The fleet SHALL publish an opt-in package-update module with a typed per-system package selection and a local batch app. Consumers SHALL use that same entry point without introducing a separate update engine. The updater SHALL come from the repository's evaluated, pinned package set.

#### Scenario: Consumer selects its own package set

- **WHEN** a repository imports the module and declares two owned package outputs
- **THEN** its update app runs the shared updater for those outputs using that repository's pinned package set
- **AND** fleet Bifrost policy is not imposed on those packages

### Requirement: Explicit ownership and selection

The batch SHALL update only registered, locally owned package outputs. Empty, duplicate, missing or unregistered selections SHALL fail with a named `package-updates:` error before any update runs. A package family with shared pins SHALL have one update owner; derived packages SHALL NOT independently update those pins.

#### Scenario: Invalid selection is refused before writes

- **WHEN** a selection contains a missing package or requests an unregistered package
- **THEN** the app exits nonzero with a named error
- **AND** no package updater has run

#### Scenario: Derived Voyage plugin is not a second writer

- **WHEN** the registered Bifrost family is updated
- **THEN** its Voyage plugin derives the updated host build context without independently changing Bifrost pins

### Requirement: Package-specific policy through a common interface

Ordinary packages SHALL use the shared updater's default behavior. Packages needing custom release discovery or coupled-pin handling SHALL declare that policy through the standard package update-script interface, executed by the shared batch. Stable releases SHALL be the default; branch or prerelease tracking SHALL require explicit package policy.

#### Scenario: Custom source discovery does not require another engine

- **WHEN** a package declares an update script for a nonstandard release feed
- **THEN** the same batch entry point invokes that script and observes its exit status

#### Scenario: Bifrost release selection is scoped

- **WHEN** Bifrost checks upstream updates
- **THEN** it selects stable transport releases
- **AND** unrelated component tags and prereleases are excluded

### Requirement: Batch failure and working-copy behavior

A batch SHALL process packages in deterministic order, staging each candidate against the caller's current working-copy change and earlier successes. A failed candidate SHALL be reported and discarded while later packages continue. The batch SHALL exit nonzero if any package fails. It SHALL preserve caller edits outside successful declared write sets and SHALL NOT create user commits, move bookmarks, merge, deploy, publish, or rewrite caller commits.

#### Scenario: Failure cannot become a successful partial batch

- **WHEN** the second updater fails after the first succeeds
- **THEN** the batch identifies the second package and exits nonzero
- **AND** the first package's changes remain applied

#### Scenario: Failed package is discarded and later packages continue

- **WHEN** an updater fails after writing candidate files
- **THEN** none of that package's candidate changes are applied
- **AND** the next selected package still runs from the latest successful state
- **AND** the batch reports the failure and exits nonzero

#### Scenario: Successful updates are cumulative

- **WHEN** a package succeeds before a later package runs
- **THEN** its declared changes are applied to the caller's working copy
- **AND** the later package's candidate starts from that updated state

#### Scenario: Caller changes are retained

- **WHEN** the caller has uncommitted working-copy edits before the batch
- **THEN** each package candidate starts with those edits
- **AND** an unsuccessful or out-of-scope candidate does not alter them

### Requirement: Candidate updates and acceptance are separate

Package refresh SHALL NOT implicitly update flake inputs or OCI references; inputs SHALL change only in a run asked to refresh them, as the scheduled update is. An update SHALL be accepted only through the repository's required checks on its update pull request. Hash-prefetch builds SHALL NOT be reported as full acceptance builds. Package regeneration against the same recorded target SHALL produce no further changes.

#### Scenario: An updated package fails its runtime checks

- **WHEN** package refresh succeeds but a declared runtime check fails
- **THEN** the candidate remains unaccepted
- **AND** no success claim, merge or deployment follows from refresh alone

#### Scenario: Same-target refresh is idempotent

- **WHEN** a successful candidate is refreshed again against the same recorded release targets
- **THEN** it produces no additional version or hash changes

#### Scenario: A package-only run

- **WHEN** the batch runs for a named package without refreshing inputs
- **THEN** `flake.lock` is unchanged

### Requirement: Bifrost updates preserve one coherent build family

Bifrost's updater SHALL refresh its transport version, upstream source hash, Go dependency hash and embedded UI dependency hash as one family. Gateway and plugin SHALL retain a shared compatible build context. Startup/UI, governance/CEL and Voyage-hook runtime checks SHALL pass before candidate acceptance. Evaluation SHALL remain possible in a fresh store without import-from-derivation.

#### Scenario: Real Bifrost candidate is verified

- **WHEN** the updater refreshes a recorded stable transport release candidate
- **THEN** the gateway and its UI build from the same upstream revision
- **AND** the derived plugin loads and normalizes real mock-provider requests
- **AND** governance/CEL startup and clean-store evaluation pass

#### Scenario: Dependency or toolchain changes need intervention

- **WHEN** a transport release cannot build with the declared dependency hashes or toolchain
- **THEN** the update or acceptance gate fails visibly
- **AND** the runner does not silently substitute an older release or declare the candidate accepted

### Requirement: Package updater write ownership

Each registered package updater SHALL be limited to its declared repository-relative write set. By default, the write set SHALL be the package's own definition directory. Shared paths SHALL require an explicit non-empty rationale. A candidate that changes a path outside its write set SHALL fail and SHALL NOT be applied.

#### Scenario: Updater writes outside its declared paths

- **WHEN** an updater changes a repository path outside its registered write set
- **THEN** the package candidate is rejected
- **AND** no candidate changes are applied to the caller's working copy

#### Scenario: Shared path is explicitly owned

- **WHEN** an updater must change a shared repository path
- **THEN** that path is listed in its write set with a non-empty rationale
- **AND** the updater may apply the path only as part of its successful package candidate

### Requirement: Disposable jj workspace staging

The app SHALL stage each package candidate in a disposable jj workspace based on the current working-copy change. The app SHALL bundle jj in its runtime environment so consumers need no global jj installation.

#### Scenario: Candidate uses current working-copy state

- **WHEN** a package updater starts
- **THEN** its workspace includes caller edits and earlier successful package changes

#### Scenario: Consumer has no global jj installation

- **WHEN** a consumer runs the package-update app from the flake
- **THEN** the app's bundled runtime provides jj

### Requirement: Preserve caller history and document staging limits

The app SHALL NOT create user commits, bookmarks, or branches, or rewrite the caller's existing commits. jj may record temporary workspace working-copy changes and workspace add/forget operations in its operation log. Successful multi-file promotion is file-level, not crash-atomic, and the app SHALL NOT claim to roll back external side effects of trusted updater scripts.

#### Scenario: Temporary workspace operations are distinct from caller commits

- **WHEN** the app stages and forgets a package workspace
- **THEN** the caller's commits and bookmarks remain unchanged
- **AND** temporary workspace changes may be visible in the operation log

#### Scenario: Process stops during successful promotion

- **WHEN** the process stops while applying a successful multi-file candidate
- **THEN** the contract makes no claim that all files were atomically promoted
- **AND** external side effects are not represented as rolled back
