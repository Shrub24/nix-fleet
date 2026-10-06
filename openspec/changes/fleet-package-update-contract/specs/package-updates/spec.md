## ADDED Requirements

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

A validated batch SHALL execute packages in a documented deterministic order and stop at the first failed update. It SHALL identify the failing package, exit nonzero and reject the batch as a candidate. It SHALL NOT automatically commit, merge, deploy, publish or discard working-copy changes. Earlier successful edits and partial failed edits SHALL remain inspectable.

#### Scenario: Failure cannot become a successful partial batch

- **WHEN** the second updater fails after the first succeeds
- **THEN** the batch identifies the second package and exits nonzero
- **AND** later updaters are not run
- **AND** existing edits remain available for diagnosis

### Requirement: Candidate updates and acceptance are separate

Package refresh SHALL NOT implicitly update flake inputs or OCI references. A candidate SHALL be accepted only after the requested package updates complete and the repository's declared acceptance checks pass. Hash-prefetch builds SHALL NOT be reported as full acceptance builds. Package regeneration against the same recorded target SHALL produce no further changes.

#### Scenario: An updated package fails its runtime checks

- **WHEN** package refresh succeeds but a declared runtime check fails
- **THEN** the candidate remains unaccepted
- **AND** no success claim, merge or deployment follows from refresh alone

#### Scenario: Same-target refresh is idempotent

- **WHEN** a successful candidate is refreshed again against the same recorded release targets
- **THEN** it produces no additional version or hash changes

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
