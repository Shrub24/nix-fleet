# fleet-ci-controller

## ADDED Requirements

### Requirement: A consumer declares what to build; the fleet owns how

A repository MUST need to supply only what to build, as flake outputs. It MUST NOT
carry builder configuration, a builder key, a cache credential or a pinned fleet
workflow in order to be built by the controller.

#### Scenario: A repository is enrolled

- **WHEN** a repository is enabled on the controller
- **THEN** it builds its declared outputs on the fleet's builders and publishes to
  the fleet's cache with no secret or variable of its own for the build

### Requirement: The controller pulls from the forge

Work MUST reach the controller from the forge's events. The forge MUST NOT hold a
credential that reaches the fleet's builders, cache or tailnet.

#### Scenario: A workflow wants a build result

- **WHEN** a workflow needs a build result
- **THEN** it reads the controller's reported result for that revision and does not
  call into the fleet

### Requirement: Only verified automation runs CI without approval

A pull request MUST run CI without explicit approval only when its author is a
verified automation identity. Identity MUST be established from the forge's
immutable account identity, not from a branch name, a label or a mutable login.
Every other pull request, including one from a branch in the repository itself, MUST
be held until approved for CI.

#### Scenario: An automation pull request

- **WHEN** the automation App opens a pull request
- **THEN** it is built and published without approval and auto-merges on green
  required checks

#### Scenario: A same-repository human pull request

- **WHEN** a human opens a pull request from a branch in the repository
- **THEN** it is held, shows a check that needs approval, and nothing is built or
  published until a maintainer approves CI

#### Scenario: A branch named like automation

- **WHEN** a human pushes a branch named like an automation branch
- **THEN** the name grants no admission

### Requirement: Admission is independent of merging

Approving a pull request for CI MUST NOT merge it, and a green build MUST NOT
approve it.

#### Scenario: An approved human pull request

- **WHEN** a maintainer approves CI for a human pull request
- **THEN** it builds and publishes, and merging remains a separate decision

### Requirement: Later pushes do not widen trust silently

A push that changes an admitted pull request's head MUST NOT run unreviewed code
under automation's admission unless the forge guarantees only the automation
identity can write that branch.

#### Scenario: A human pushes to an automation branch

- **WHEN** a non-automation actor pushes to an automation pull request's branch
- **THEN** the push is refused by branch rules, or the pull request is held again

### Requirement: Cache readiness is reconciled on the default branch

After a default-branch build, the controller MUST ensure the retention root is
present in the cache and pin it, and MUST be able to repeat that without a new
push. A failed upload MUST be visible, not only logged.

#### Scenario: A pull-request build is reused after merge

- **WHEN** a merge produces a tree identical to a built pull request
- **THEN** the build is reused, the retention root is verified present and pinned,
  and a failed publication is retried or reported

### Requirement: Untrusted revisions cannot publish

A revision from a fork, or from an author outside the admitted set, MUST NOT cause
anything to be published or pinned until approved for CI.

#### Scenario: A fork pull request

- **WHEN** a pull request from a fork is opened
- **THEN** it is held and nothing built for it is published
