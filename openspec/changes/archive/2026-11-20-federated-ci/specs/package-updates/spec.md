## MODIFIED Requirements

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
