## Purpose

Decides, for every flake input of a repository using the fleet CI, which revision the
scheduled update moves it to, where that decision is declared, and how a moved
release tag is written back to the file that owns it.

## ADDED Requirements

### Requirement: Every input has a version policy derived from its ref

Each flake input SHALL have one policy: `stable`, `unstable`, `branch` or `fixed`.
Without an override, an input whose ref is a tag on its remote SHALL be `stable`, an
input with a branch ref or no ref SHALL be `branch`, and an input pinned to a `rev`
SHALL be `fixed`.

#### Scenario: A release tag

- **WHEN** an input is `github:vicinaehq/vicinae/v0.29.2` and `v0.29.2` is a tag
- **THEN** its policy is `stable`

#### Scenario: A version-shaped branch

- **WHEN** an input is `github:NixOS/nixpkgs/nixos-25.11` and `nixos-25.11` is a
  branch, not a tag
- **THEN** its policy is `branch`

#### Scenario: A revision pin

- **WHEN** an input's ref is a `rev`
- **THEN** its policy is `fixed`

### Requirement: Overrides are declared on the input declaration

A repository SHALL override an input's policy and `versionRegex` on that input's
flake-file declaration. The override SHALL NOT appear in the generated `flake.nix`.

#### Scenario: An override leaves flake.nix unchanged

- **WHEN** `flake-file.inputs.hermes-agent.update.versionRegex` is set
- **THEN** the generated `flake.nix` is identical to the one generated without it

### Requirement: Stable follows the maintainer's latest release

A `stable` input without `versionRegex` SHALL move to the forge's latest-release
marker when the repository publishes releases, and otherwise to the highest tag of
the same prefix that is not a pre-release. It SHALL never move to a lower version.

#### Scenario: Mixed tag schemes

- **WHEN** the input is at `v0.22.4`, the latest release is `v0.23.3`, and the repository
  also carries `rc.13-v0.23.2`, `v0.23.2+canary.…` and `v2026.9.24`
- **THEN** the input moves to `v0.23.3`

#### Scenario: A repository without releases

- **WHEN** the repository publishes tags only
- **THEN** the input moves to the highest non-pre-release tag sharing its prefix

#### Scenario: Already current

- **WHEN** the input is at the latest release
- **THEN** it does not move and the run reports it unchanged

### Requirement: A version regex filters and extracts

When `versionRegex` is set, only tags it matches SHALL be candidates, and its single
capture group SHALL be the version compared, as nix-update's `--version-regex` does.
A regex without exactly one capture group SHALL fail with a named error.

#### Scenario: Holding a release line

- **WHEN** `versionRegex = "v(5\\..*)"`, the input is at `v5.4.1`, and `v5.5.0` and
  `v6.0.0` exist
- **THEN** the input moves to `v5.5.0`

#### Scenario: One product of several in a repository

- **WHEN** `versionRegex = "bolt-v(.*)"` and the repository also tags `pi-v2.0.0`
- **THEN** only `bolt-v` tags are candidates

### Requirement: Unstable admits pre-releases

An `unstable` input SHALL select by the same rules as `stable` with pre-releases
included.

#### Scenario: A newer pre-release

- **WHEN** an `unstable` input is at `v1.0.0` and `v1.1.0-rc.1` exists
- **THEN** it moves to `v1.1.0-rc.1`

### Requirement: Branch inputs refresh their lock entry

A `branch` input SHALL move to its branch's current head in `flake.lock`, and only
that input's lock entry SHALL change.

#### Scenario: A branch input moved upstream

- **WHEN** a `branch` input's branch has a newer commit
- **THEN** its lock entry records that commit and its declaration is unchanged

### Requirement: Fixed inputs do not move on schedule

A `fixed` input SHALL NOT move in a scheduled run and SHALL carry a non-empty
`reason`; a `fixed` override without one SHALL fail with a named error before any
write. An explicit request for the input SHALL still move it.

#### Scenario: Fixed without a reason

- **WHEN** an input declares `update.version = "fixed"` and no `reason`
- **THEN** evaluation fails naming the input, and no update runs

#### Scenario: An explicit request

- **WHEN** an operator runs the batch requesting a `fixed` input by name
- **THEN** that input moves by its ref's derived policy

### Requirement: A moved tag is written to its declaring file

A moved `stable` or `unstable` input SHALL be rewritten in the one file that declares
it, `flake.nix` SHALL then be regenerated where flake-file is in use, and only the
moved inputs SHALL be relocked. A declaration that cannot be located exactly once
SHALL fail the input with a named error and leave no change.

#### Scenario: The declaration is in a module

- **WHEN** `hermes-agent` is declared in `modules/agents/hermes.nix` and moves
- **THEN** that file, `flake.nix` and `flake.lock` change, and nothing else does

#### Scenario: The reference occurs twice

- **WHEN** the input's URL literal appears twice in its declaring file
- **THEN** the input fails with a named error, the rest of the transaction proceeds,
  and the report lists it as not updated

### Requirement: Each move is reported with its changes

The update report SHALL list each moved input with its old and new version, the
compare link, and the release notes link where the forge publishes releases, and
SHALL list each input that failed with its reason.

#### Scenario: A tag moved

- **WHEN** `vicinae` moves from `v0.29.2` to `v0.30.1`
- **THEN** the pull request body shows `v0.29.2 → v0.30.1` with the compare and
  release links
