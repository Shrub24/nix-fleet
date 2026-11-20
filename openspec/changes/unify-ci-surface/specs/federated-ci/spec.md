## MODIFIED Requirements

### Requirement: One interface builds, retains and updates a repository

A repository importing `flakeModules.ci` MUST get retention, release pins and the
update transaction with no further CI code, configured under one flake-level `ci`
namespace and no other fleet module, and pull requests MUST build the root retention
pins.

#### Scenario: A new repository from the template

- **WHEN** a repository is created from `templates.ci`
- **THEN** its `herculesCI` defines `cache-retain` for a default-branch push and
  `package-updates` on schedule, its `checks` include `cache-root`, and its CI
  settings live in `modules/flake/ci.nix`

#### Scenario: No second module to import

- **WHEN** a repository imports only `flakeModules.ci`
- **THEN** `ci.updates.packages`, `ci.updates.lockfiles` and `ci.updates.commands` are
  available and `packages.<system>.cache-root` is defined

### Requirement: Updates are one transaction over every source

Inputs, packages, lockfiles and commands MUST be proposed in one pull request, each
input moved by its version policy; an update writing outside its write set MUST NOT
be adopted; an empty registry MUST still refresh every input that is not `fixed`.

#### Scenario: Only flake.lock

- **WHEN** nothing is registered, no input is tag-pinned, and the scheduled run
  refreshes inputs
- **THEN** the run completes with only the lock changed

#### Scenario: A tag and a package together

- **WHEN** one tag-pinned input and one registered package both have newer versions
- **THEN** both changes land in the same pull request and are built once

## ADDED Requirements

### Requirement: The interface documents its own options

nix-fleet SHALL publish a reference of every `ci` option, generated from the module's
option declarations, and a check SHALL fail when the committed reference differs from
the generated one.

#### Scenario: An option description changes

- **WHEN** an option's description changes and the reference is not regenerated
- **THEN** `nix flake check` fails naming the stale reference
