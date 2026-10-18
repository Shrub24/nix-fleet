## ADDED Requirements

### Requirement: Lock refresh precedes native package updates

The producer SHALL refresh moving flake inputs first and SHALL run the registered package updaters against the refreshed lock. The resulting PR SHALL contain the lock change and the package changes together.

#### Scenario: Packages updated against the new lock

- **WHEN** the refresh changes the lock and a package has a newer release
- **THEN** the package updater runs after the lock change
- **AND** the resulting PR contains both changes

### Requirement: Package releases do not wait for lock changes

The producer SHALL run the package updaters whether or not the lock changed.

#### Scenario: Lock unchanged, package released

- **WHEN** no moving input has advanced and a registered package has a newer release
- **THEN** the producer still opens or refreshes a PR containing the package update

### Requirement: Inputs can be deferred

The producer SHALL support an exclusion list of inputs that are not refreshed, and a manual run SHALL accept an explicit input subset. An excluded input SHALL keep its locked revision.

#### Scenario: Broken upstream deferred

- **WHEN** an input is on the exclusion list
- **THEN** the refresh leaves that input unchanged and still refreshes the others

### Requirement: One ordinary PR

The producer SHALL open or refresh a single automation PR using an identity whose pushes start required checks. A run with no change SHALL open no PR and SHALL close or leave untouched any previous one without error. A failed package updater SHALL be reported in the PR and SHALL NOT block the other updates.

#### Scenario: Nothing changed

- **WHEN** neither the lock nor any package changed
- **THEN** no PR is opened and the run succeeds

#### Scenario: One updater fails

- **WHEN** a package updater fails and others succeed
- **THEN** the PR contains the successful changes
- **AND** the failure is named in the report

### Requirement: Proposals are published by a job that runs no repository code

The producer SHALL run its updaters in a job that holds no credential able to
propose or push, and SHALL publish from a separate job that applies the recorded
proposal as data against the revision it was taken from. Publication to a moved
base SHALL be refused rather than applied.

#### Scenario: An update script is compromised

- **WHEN** an updater executed by the refresh provisions an unexpected change or behaves maliciously
- **THEN** no credential able to create the PR or push a branch is reachable from that job's process

#### Scenario: The default branch moved during the run

- **WHEN** the publication job finds the base is no longer the tip of its branch
- **THEN** it publishes nothing and fails visibly, and the next run redoes the refresh

### Requirement: The batch reports whether its result is proposable

The batch SHALL exit with its outcome and record the same value in its report: a
clean run, a run that completed with per-item failures and is still proposable,
and a run whose tree cannot be proposed because adoption stopped part-way. An
adoption that stops part-way SHALL end the batch rather than continue against a
part-updated tree.

#### Scenario: A package fails and others succeed

- **WHEN** one selected package's updater fails
- **THEN** the failed package is recorded and named in the report
- **AND** the remaining packages still run
- **AND** the batch's outcome reports the failure while remaining proposable

#### Scenario: Adoption fails part-way

- **WHEN** applying a successful candidate's changes fails after it started
- **THEN** the batch stops, records the outcome that nothing can be proposed from this tree, and exits with that outcome

### Requirement: Cumulative report

The PR SHALL report each moved input as old and new revision with a link to the comparison, and each moved package as old and new version with a link to its release notes where the package provides one.

#### Scenario: Reported input change

- **WHEN** an input's locked revision moves
- **THEN** the report lists both revisions and a comparison link

### Requirement: Candidates are rebuilt when the base moves

When the default branch advances, open update PRs SHALL be re-prepared and revalidated against the new base.

#### Scenario: Base advanced under an open PR

- **WHEN** the default branch advances while an automation PR is open
- **THEN** the pipeline runs again for that PR on the new base

### Requirement: Renovate owns tagged and non-closure updates only

Renovate SHALL propose updates to tagged flake inputs, CI references and container images. It SHALL NOT run routine lock maintenance, SHALL NOT propose updates to moving inputs, and SHALL NOT automerge. Tagged-input declarations SHALL be edited in their authoritative flake-file module and not in the generated flake.

#### Scenario: Moving input

- **WHEN** an input tracks a branch
- **THEN** only the producer advances it

#### Scenario: Tagged input

- **WHEN** a newer release tag exists for a tagged input
- **THEN** Renovate edits the module declaration and the pipeline's preparation generates the flake and lock changes
