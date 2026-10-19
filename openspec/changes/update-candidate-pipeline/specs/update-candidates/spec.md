## ADDED Requirements

### Requirement: Candidate preparation reconciles without refreshing

Every update PR SHALL be turned into a candidate revision by a preparation step that regenerates generated artifacts and reconciles `flake.lock` with the declared inputs, without discovering new versions or advancing moving inputs. Preparation SHALL also carry the default branch as it is at preparation time, so the candidate descends from it. Preparing an already-prepared candidate SHALL produce no further change.

#### Scenario: A source conflicts with the default branch

- **WHEN** preparation cannot carry the default branch into the source
- **THEN** preparation fails and no candidate is produced

#### Scenario: The default branch moved

- **WHEN** the source PR head already carries current generated files and the default branch has moved since
- **THEN** the candidate is the source head merged with the default branch

#### Scenario: Complete source PR needs no child

- **WHEN** the source PR head already has current generated files and a reconciled lock
- **THEN** the candidate equals the source PR head, or that head merged with the default branch when the default branch has moved since
- **AND** the pipeline still evaluates and builds it

#### Scenario: Declaration changed without lock

- **WHEN** a source PR changes an input declaration and leaves `flake.lock` unreconciled
- **THEN** the candidate is a child commit of the source head that contains the regenerated flake and reconciled lock
- **AND** unrelated moving inputs keep their locked revisions

#### Scenario: Preparation is a fixed point

- **WHEN** preparation runs on a candidate it produced
- **THEN** it yields the same revision

### Requirement: Candidates are exact, published and never written to the source branch

The pipeline SHALL build and evaluate the exact candidate SHA, checked out by SHA and not through a synthetic pull-request merge ref. It SHALL publish that SHA under an automation-owned ref outside the source PR's branch. The pipeline SHALL NOT push to a branch owned by a PR author, including Renovate.

#### Scenario: Source branch is untouched

- **WHEN** a Renovate-authored PR yields a child candidate
- **THEN** the child exists only under the automation-owned ref
- **AND** the Renovate branch is unchanged

#### Scenario: Evidence names the built tree

- **WHEN** the build runs
- **THEN** the revision built is the candidate SHA and not a merge of it with the base branch

### Requirement: Acceptance evidence is a status on the candidate SHA

On success the pipeline SHALL post a required status on the candidate SHA, whose context is `update-candidate` and stable across all pull requests. Only the pipeline identity SHALL post it, and success SHALL require an explicit success path: a skipped stage, an absent result or an output a stage did not set is a failure.

#### Scenario: Evidence requires validation and a build

- **WHEN** the status is evaluated
- **THEN** it requires the declared validation to pass and every declared build target to build

#### Scenario: Build failure withholds evidence

- **WHEN** any declared target fails to build
- **THEN** no success status is posted on the candidate SHA

#### Scenario: Cache availability does not withhold evidence

- **WHEN** the build succeeds but the configured substituter does not serve an output
- **THEN** the success status is still posted, because availability says nothing about whether the revision is correct and an unavailable cache must not block dependency updates

#### Scenario: Availability is checked only for a built revision

- **WHEN** cache availability is checked
- **THEN** it is checked for a revision that was built — a promoted candidate or an explicit dispatch — and not for every push to the default branch, because a revision whose new derivations were never realised would report them as misses

#### Scenario: A stage does not report

- **WHEN** any stage is skipped or leaves no result
- **THEN** the status is a failure that names the stage

#### Scenario: Stale candidate

- **WHEN** the base branch has moved since the candidate was prepared
- **THEN** the pipeline re-prepares the candidate before posting any status

### Requirement: Promotion is a fast-forward push gated by GitHub

The default branch SHALL require the pipeline's status and SHALL NOT require a pull request. Promotion SHALL be a non-forced push of the candidate SHA by a trusted GitHub App with no ruleset bypass, and a push SHALL be rejected when the base moved or the SHA lacks the status.

#### Scenario: The promoter checks the candidate's provenance

- **WHEN** the promoter considers a candidate
- **THEN** the candidate ref must resolve to that commit, and the commit must descend from the source revision and from the current default branch

#### Scenario: Evidence is enforced by the repository

- **WHEN** a commit without the required status is pushed to the default branch
- **THEN** the push is rejected by the repository rules

#### Scenario: Base moved

- **WHEN** the default branch advanced after the candidate was built
- **THEN** the promotion push fails and nothing lands
- **AND** the candidate is rebuilt from the new base

#### Scenario: Source PR is reflected as merged

- **WHEN** the promoted SHA descends from the source PR head
- **THEN** the source PR is marked merged

### Requirement: Promotion policy is selected per repository

The pipeline SHALL take a promotion policy. Under `auto`, a candidate with evidence SHALL be promoted automatically. Under `label`, promotion SHALL additionally require an acceptance label recorded against the specific source revision. Acceptance SHALL lapse when the source PR head changes.

#### Scenario: Automatic fleet promotion

- **WHEN** an eligible candidate has evidence under `auto`
- **THEN** it is promoted without further action

#### Scenario: Consumer awaits acceptance

- **WHEN** a candidate has evidence under `label` and no acceptance
- **THEN** it is built and cached but not promoted

#### Scenario: Label does not carry to a newer revision

- **WHEN** the source PR head changes after the acceptance label was applied
- **THEN** the earlier acceptance does not authorise promotion of the new revision

### Requirement: Human PRs are checked for consistency only

For a PR not produced by an update producer, the pipeline SHALL fail when regeneration or lock reconciliation would change the tree and SHALL otherwise report the same status on the PR head. It SHALL NOT generate a child commit or promote automatically. The required status SHALL exist on every PR, including those that need no build.

#### Scenario: Generated files out of date

- **WHEN** a human PR's generated flake would change under regeneration
- **THEN** the check fails

#### Scenario: Documentation-only PR

- **WHEN** a PR changes nothing in the Nix build graph
- **THEN** the required status is still reported

### Requirement: Privilege is separated from untrusted execution

Steps that evaluate updated inputs, run updaters or build the candidate SHALL run without the App credential. The App credential SHALL be reachable only through an environment restricted to the default branch. Builder and cache-write access for candidates SHALL be scoped by a deployment environment and SHALL NOT depend on branch-name prefixes.

The App credential SHALL NOT be present in any workflow whose definition can come from a pull request.

#### Scenario: Candidate code has no App token

- **WHEN** a candidate is built
- **THEN** the build job has no App credential

#### Scenario: The pipeline entry point cannot come from a pull request

- **WHEN** the pipeline decides what to validate
- **THEN** its entry point is defined on the default branch, the revision it validates is resolved from the GitHub API, and no artifact is consumed as an instruction

#### Scenario: Promotion runs from the default branch

- **WHEN** a candidate is promoted
- **THEN** the promoter's definition is the default branch's, and it receives the candidate SHA as data

#### Scenario: Cache write is not tied to merge

- **WHEN** a candidate is built under the candidate environment
- **THEN** its outputs may be published to the cache before and regardless of promotion

### Requirement: Non-closure updates are not forced through the build

An update PR that changes only CI references or container image tags SHALL receive the validation relevant to that change and SHALL NOT be required to build the full closure unless it affects the declared build targets.

#### Scenario: Actions pin bump

- **WHEN** a PR changes only a GitHub Actions reference
- **THEN** the closure build is not required for it

### Requirement: Candidate reports and lifecycle

The pipeline SHALL record on the source PR, in a comment that is replaced on each run, the candidate SHA, input revision changes, package version changes and build results. Superseded runs SHALL be cancelled, an in-flight promotion SHALL NOT be cancelled, and candidate refs SHALL expire after a bounded time.

#### Scenario: Run is superseded

- **WHEN** a newer revision of the same source PR starts a run
- **THEN** the older build run is cancelled
- **AND** a promotion already in progress completes or fails on its own

#### Scenario: Report is replaced

- **WHEN** the pipeline runs again for the same PR
- **THEN** the previous report comment is updated, not duplicated
