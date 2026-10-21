# Proposal

## Why

The reusable build workflow assumes its caller is this repository. It installs a
builder bundle from `.#packages.<system>.<attr>` in the _caller's_ flake and
resolves the Tailscale and cache coordinates from that flake too, so only a
repository that imports `flakeModules.fleet` can use it. Consumers have to
re-export fleet outputs, import the fleet module, or duplicate builder
configuration — three ways to disagree with the fleet about who builds and where
the cache is.

The workflow and the configuration it installs also come from different
revisions: a caller pins a workflow reference and separately decides which fleet
outputs its own flake carries. Nothing keeps them in step.

## What Changes

- A **CI coordinator** artifact, `packages.<system>.ci-coordinator-<profile>`,
  projects the existing builder-profile and cache projections into the
  configuration an ephemeral runner installs: Nix client settings, machines,
  SSH configuration, pinned host identities, and the small public metadata the
  workflow needs. It is a projection, not a second source of truth, and is
  published through the checked package closure with no extra plumbing.
- The build workflow resolves that artifact from **the revision that defines the
  workflow** (`job.workflow_sha`), so one pinned reference yields machinery and
  fleet facts from one commit. A caller's flake stays independent: no
  `fleet_ref` input, no re-exported builder metadata, no fleet-module import.
- The runner's Nix is installed with the public cache preconfigured, because the
  coordinator is fetched through it. Those two bootstrap values are the only
  fleet facts stated in the workflow, and a check asserts they equal the rendered
  artifacts.
- `builder_attr` is renamed `profile` with no alias; `prepare` becomes selection
  only.
- Builder reachability stops being a pre-flight veto. The job reports what
  happened — effective `builders`, per-builder `runner` and `root` SSH results,
  realisations — and never refuses to schedule.
- The cache promise, `packages.<system>.cache-root`, is asserted to be part of
  the checked closure, so pinning and verification share one subject with the
  build.

## Capabilities

### New Capabilities

- `fleet-ci-host`: what an ephemeral CI runner is configured with, how it is
  obtained, what it must never own, and what a run reports.

## Impact

- `modules/fleet/feature.nix` (coordinator derivation and export),
  `modules/flake/package-closure.nix` (cache-root assertion),
  `modules/flake/tooling.nix` (one more actionlint ignore for the `job.workflow_*`
  properties its context table lacks).
- `.github/workflows/build-push-cache.yml` restructured; `ci.yml`,
  `candidate.yml`, `pipeline.yml` rename one input.
- `tests/ci/tailscale_check.py` replaced by `tests/ci/build_workflow_check.py`,
  which also gains the bootstrap-agreement assertion.
- `docs/contracts/ci.md`, `README.md`, `docs/contracts/update-candidates.md`.
- Consumers: the workflow becomes usable from any repository that can pin it and
  supply a builder key. `nix-homelab`'s pinned reference keeps working until it is
  bumped, and that bump must carry the `builder_attr` → `profile` rename.
