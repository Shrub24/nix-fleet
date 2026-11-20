## MODIFIED Requirements

### Requirement: Shared package-update entry point

The fleet SHALL publish the package-update registry as part of `flakeModules.ci`,
declared once at flake level under `ci.updates`, with a local batch app. Consumers
SHALL use that same entry point without introducing a separate update engine. The
updater SHALL come from the repository's evaluated, pinned package set.

#### Scenario: Consumer selects its own package set

- **WHEN** a repository imports `flakeModules.ci` and declares two owned packages
  under `ci.updates.packages`
- **THEN** its `update-all` app runs the shared updater for those outputs using that
  repository's pinned package set
- **AND** fleet Bifrost policy is not imposed on those packages

#### Scenario: One registry for every system

- **WHEN** a repository builds for two systems
- **THEN** both systems' update apps read the same registry
