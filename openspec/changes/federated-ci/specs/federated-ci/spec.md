# federated-ci

## ADDED Requirements

### Requirement: One interface builds, retains and updates a repository

A repository importing `flakeModules.ci` and binding `ci.instance` MUST get
retention, release pins and the update transaction with no further CI code, and
pull requests MUST build the root retention pins.

#### Scenario: A new repository from the template

- **WHEN** a repository is created from `templates.ci` with a descriptor bound
- **THEN** its `herculesCI` defines `cache-retain` for a default-branch push and
  `package-updates` on schedule, and its `checks` include `cache-root`

### Requirement: Retention keeps history without deleting

On a default-branch push the effect MUST push each root before pinning it and fail
unless it substitutes. With generations configured it MUST shift earlier pins only
when the rolling pin moves.

#### Scenario: The root moved

- **WHEN** the rolling pin names an earlier root
- **THEN** `<pin>-k` takes `<pin>-(k-1)`'s root, `<pin>-1` the earlier root, and the
  rolling pin the new one

#### Scenario: A rerun on the same root

- **WHEN** the rolling pin already names the root
- **THEN** no generation moves

### Requirement: Tags pin under their own namespace

A tag push MUST pin only under `<name>-release-<tag>-<system>`, and a branch push
MUST NOT run the release effect.

#### Scenario: A tag is pushed

- **WHEN** tag `v1/2` is pushed
- **THEN** `cache-release` pins `<name>-release-v1-2-<system>` and `cache-retain`
  does not run

### Requirement: Updates are one transaction over every source

Inputs, packages, lockfiles and commands MUST be proposed in one pull request; an
update writing outside its write set MUST NOT be adopted; an empty registry MUST
refresh `flake.lock` rather than refuse.

#### Scenario: Only flake.lock

- **WHEN** nothing is registered and the scheduled run refreshes inputs
- **THEN** the run completes with only the lock changed

### Requirement: The operator's list is the only enrolment

`ci-enrol` MUST enable each listed repository in nixbot and give it auto-merge and
the `nixbot` ruleset, MUST disable every other enabled project and remove its
ruleset, and MUST NOT write where nothing differs.

#### Scenario: A reconciled repository

- **WHEN** a listed repository is enabled, allows auto-merge and carries the current ruleset
- **THEN** a run makes no writes

#### Scenario: A repository leaves the list

- **WHEN** an enabled repository is not listed
- **THEN** it is disabled and its `nixbot` ruleset removed

### Requirement: Auto-merge never falls back to merging

When GitHub refuses auto-merge the update effect MUST fail with the pull request
left open.

#### Scenario: A repository without required checks

- **WHEN** the update pull request is already mergeable and auto-merge is refused
- **THEN** the effect fails and nothing is merged
