## MODIFIED Requirements

### Requirement: Batch failure and working-copy behavior

A batch SHALL process packages in deterministic order, staging each candidate against the caller's current working-copy change and earlier successes. A failed candidate SHALL be reported and discarded while later packages continue. The batch SHALL exit nonzero if any package fails. It SHALL preserve caller edits outside successful declared write sets and SHALL NOT create user commits, move bookmarks, merge, deploy, publish, or rewrite caller commits.

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

## ADDED Requirements

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
