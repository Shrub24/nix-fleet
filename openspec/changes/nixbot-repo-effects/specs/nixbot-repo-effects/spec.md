# nixbot-repo-effects

## ADDED Requirements

### Requirement: Retention follows the repository's default branch

The retention effect MUST run on every push to the repository's default branch
and on no other ref. For each configured system it MUST push the root before
moving that system's pin, and MUST fail if the root cannot be substituted from
the public cache afterwards.

#### Scenario: A default-branch push

- **WHEN** a push to the default branch is built
- **THEN** each system's root is pushed, its `<repo>-<branch>-<system>` pin moves
  to it, and the effect fails if the root is not substitutable

#### Scenario: A push of a missed upload

- **WHEN** the streaming uploader missed paths and the effect is rerun on an
  unchanged root
- **THEN** the push repairs the cache and the pin is moved again

#### Scenario: A tag or a non-default branch

- **WHEN** a tag or another branch is pushed
- **THEN** no retention effect is defined

### Requirement: Updates are one transaction with one proposal

The scheduled update MUST refresh inputs and package pins in one run and publish
at most one branch and one pull request. It MUST publish nothing when nothing
changed or when the batch is aborted, and MUST NOT expose the write credential
to the update scripts.

#### Scenario: Something changed

- **WHEN** the batch completes or partially completes with changes
- **THEN** one automation branch is pushed and one pull request is opened or
  updated, with auto-merge requested only if the repository enabled it

#### Scenario: Nothing changed or aborted

- **WHEN** the batch reports no changes or `aborted`
- **THEN** nothing is pushed

### Requirement: Consumer effects extend, never replace

Consumer effects MUST render beside the fleet's. A consumer effect or schedule
job with a fleet-owned name MUST fail evaluation with a named error.

#### Scenario: A colliding name

- **WHEN** a consumer declares `extra.onPush.cache-retain`
- **THEN** evaluation fails naming the collision

### Requirement: Cache trust is derived from one repository list

Each listed repository MUST receive exactly one nixbot rule granting write and
its own pin namespace, bound to its default-branch push of the retention effect.
The effect claim and pin namespace MUST come from the same definition the
effects module uses. Overlapping pin namespaces MUST fail evaluation.

#### Scenario: A repository is listed

- **WHEN** a repository is added to `services.niks3-cache.nixbot.repositories`
- **THEN** its default-branch retention effect can push and move only its own
  pins

#### Scenario: Overlapping namespaces

- **WHEN** two repositories' pin globs overlap
- **THEN** evaluation fails naming both
