# fleet-ci-host

## ADDED Requirements

### Requirement: The coordinator is a projection of fleet definitions

The CI coordinator artifact MUST be derived from the existing builder-profile and
service-endpoint projections. It MUST NOT introduce an additional inventory,
address list, or credential store.

#### Scenario: A profile change reaches the coordinator

- **WHEN** a fleet build profile gains a builder or changes its systems
- **THEN** the coordinator rendered for that profile carries the change, and no
  separate edit is required

#### Scenario: The coordinator stays substitutable

- **WHEN** the coordinator is published to the cache
- **THEN** its closure is small enough to substitute on a cold runner, and it
  embeds neither a Nix installation nor a build driver

### Requirement: One writer per setting

The coordinator MUST own `builders`, `builders-use-substitutes`,
`extra-substituters`, and `extra-trusted-public-keys`. It MUST NOT set
`trusted-users`, `post-build-hook`, `sandbox`, or `experimental-features`, and
MUST write substituters only in the additive form.

#### Scenario: A forbidden setting fails the artifact build

- **WHEN** the coordinator's Nix configuration sets a forbidden setting or a
  non-additive `substituters`
- **THEN** the artifact's build fails and names the setting

#### Scenario: Publication survives the coordinator

- **WHEN** the coordinator is installed and the publishing action configures its
  own user-level Nix configuration
- **THEN** the post-build hook still runs, because the coordinator did not
  override trust or the hook

### Requirement: Configuration comes from the workflow's own revision

The build workflow MUST resolve the coordinator from the repository and commit
that define the executing workflow file. It MUST NOT accept a caller-supplied
fleet revision, nor require the caller's flake to export or import fleet
configuration.

#### Scenario: A pinned caller gets matching machinery

- **WHEN** a consumer pins the workflow by commit
- **THEN** the coordinator is resolved from that same commit, and the caller's
  own flake is used only for what it selects to build

#### Scenario: A caller's flake is untouched in selection

- **WHEN** the workflow selects a runner and target systems
- **THEN** it does so without checking out or evaluating the caller's flake

### Requirement: Installation is declarative and reload-safe

The coordinator MUST render configuration for conventional system paths rather
than its own store path. Applying it MUST NOT depend on a daemon restart, and the
install step MUST read the applied value back.

#### Scenario: Applied configuration is observed, not assumed

- **WHEN** the install step completes
- **THEN** it has read `builders` back through the installed configuration

### Requirement: The bootstrap cache is the fleet's, and is checked

The runner's Nix MUST be installed with the public substituter and key
preconfigured, because the coordinator is fetched through them. Those values MUST
be asserted equal to the rendered cache artifacts.

#### Scenario: A cache move is caught

- **WHEN** the bootstrap substituter or key diverges from the rendered artifacts
- **THEN** the workflow contract check fails and names the value

#### Scenario: A coordinator miss is not a failure

- **WHEN** the coordinator is absent from the cache
- **THEN** the runner builds it locally and the build proceeds

### Requirement: Builder availability is reported, not vetoed

A run MUST report the effective builder configuration, per-builder SSH results
from the runner user and from root, and the derivations realised during the run.
It MUST NOT fail, or refuse to schedule, because a builder is unreachable.

#### Scenario: An unavailable builder does not block the build

- **WHEN** a selected builder does not answer SSH
- **THEN** the run continues and its report names that builder and the failure

#### Scenario: The report survives a failed build

- **WHEN** the build step fails
- **THEN** the report still runs and records what happened

### Requirement: Pinning and verification share the build's subject

The cache promise MUST be `packages.<system>.cache-root`. It MUST be part of the
checked closure, so a revision the pipeline builds is a revision whose pin
subject exists.

#### Scenario: A promoted revision has a pinnable root

- **WHEN** a revision passes the build stage
- **THEN** its `cache-root` was realised as part of that build
