## MODIFIED Requirements

### Requirement: Batch failure and working-copy behavior

A validated batch SHALL execute selected packages in deterministic order, staging each package independently from the caller's current working-copy state and all earlier successful updates. A failed package SHALL be reported and discarded without preventing later packages from running. The batch SHALL exit nonzero if any package failed. It SHALL NOT automatically commit, merge, deploy, publish, or rewrite jj history, and SHALL preserve caller changes outside successful declared write sets.

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

Each registered package updater SHALL be limited to its declared repository-relative write set. By default, the write set SHALL be the package's own definition directory. A package may declare shared paths only with an explicit reason. A candidate that changes a path outside its write set SHALL fail and SHALL NOT be applied.

#### Scenario: Updater writes outside its declared paths

- **WHEN** an updater changes a repository path outside its registered write set
- **THEN** the package candidate is rejected
- **AND** no candidate changes are applied to the caller's working copy

#### Scenario: Shared path is explicitly owned

- **WHEN** an updater must change a shared repository path
- **THEN** that path is listed in its write set with a non-empty rationale
- **AND** the updater may apply the path only as part of its successful package candidate

### Requirement: Package candidates use disposable jj workspaces

The app SHALL stage each package candidate in a disposable jj workspace based on the current working-copy change. It SHALL bundle jj in the app's runtime environment so a consumer does not need a global jj installation. It SHALL NOT create or rewrite jj history. Promotion of a successful multi-file candidate is file-level and is not guaranteed crash-atomic; the app SHALL NOT claim to roll back external side effects of trusted updater scripts.

#### Scenario: Candidate uses the current working-copy state

- **WHEN** a package updater starts
- **THEN** its workspace includes caller edits and earlier successful package changes
- **AND** running the updater does not create a jj commit or bookmark

#### Scenario: Process stops during successful promotion

- **WHEN** the process stops while applying a successful multi-file candidate
- **THEN** the contract makes no claim that all files were atomically promoted
- **AND** external side effects are not represented as rolled back

#### Scenario: Consumer invokes the app without a global jj installation

- **WHEN** a consumer runs the package-update app from the flake
- **THEN** the app's bundled runtime provides jj
- **AND** the update does not depend on a system-installed jj executable
