# Proposal

> Status: **direction chosen, implementation open.** The decisions below are
> settled; the spikes in `tasks.md` decide whether and how they are built. Nothing
> here is scheduled before the organisation move.

## Why

The build stage runs on a GitHub-hosted runner, which is ephemeral and foreign.
Every run rebuilds the trust and environment it needs: it installs Nix, fetches the
coordinator, applies its configuration, joins the tailnet, mints a cache token and
carries a builder key. Around that sits an update lifecycle (candidate preparation,
bundle handoff, an App-posted status, an acceptance marker, fast-forward promotion)
that exists for two reasons only:

1. Renovate owns its branch, so preparation could not commit onto it. A native
   producer that opens a complete pull request removes this.
2. A pull-request run on a hosted runner cannot publish to the cache, so the build
   had to run in default-branch context and hand its result back by revision.
   A persistent builder that admits the pull request removes this.

Neither reason is a requirement of the update flow itself.

## What Changes

**Replace, not preserve.** The candidate lifecycle is not ported.

- A **CI controller** (candidate: nixbot) runs on a fleet host as a NixOS aspect.
  It pulls work from GitHub, evaluates and builds on a persistent store, distributes
  builds to the existing builders, publishes to the existing cache and reports
  check runs.
- **Admission decides who builds.** Verified automation pull requests are admitted
  automatically: full build, cache publication, GitHub auto-merge on green checks.
  Every other pull request is held until explicitly approved for CI, then runs the
  same pipeline. Approval to run CI is not approval to merge.
- **GitHub owns merging.** Ordinary pull-request merge and required checks. No
  promoter, no candidate refs, no `update-candidate` or `update-accepted` status.
- **`main`** reuses the pull request's build for an identical tree, and a
  default-branch effect reconciles cache publication and moves the rolling pins.
- The **GitHub Actions updater stays** for now, to decouple migration risks. Native
  `onSchedule` production is revisited once the controller is operating.
- `build-push-cache.yml` is frozen at `v3` for fixes until the controller has built
  a real consumer.

## Capabilities

### New Capabilities

- `fleet-ci-controller`: a persistent, fleet-owned build orchestrator, its admission
  policy, and the consumer contract around it.

### Modified Capabilities

- `fleet-ci-host`: the per-run coordinator is superseded once the controller builds
  for a consumer. Recorded for the follow-up.
- `update-candidate-pipeline`: retired for repositories the controller serves.

## Non-goals

- A self-hosted Actions runner on the controller (all fleet repositories are public).
- Merge-queue adoption; deferred and orthogonal.
- Per-pull-request publication policy, build profiles or conditional uploaders. The
  admission decision replaces them.
- Moving the producer into the controller before the controller is operating.
- A new trust or provenance mechanism beyond admission and GitHub's own branch rules.

## Consumer-side changes this implies

Recorded here; made by each consumer's own change, not from this repository.

- `nix-homelab` drops `system.configurationRevision = self.rev or self.dirtyRev`
  (`modules/flake/provenance.nix`). Content provenance stays through
  `environment.etc."nixos-source".source = self.outPath`. Reason: it is the only
  `self.rev` consumer found, so removing it makes an identical tree build to
  identical outputs and lets a squash-merge reuse the pull request's build.
  `nix-fleet` and `nix-dotfiles` have no such consumer.

## Open questions

Each is a spike with an observable answer; see `design.md` and `tasks.md`.

1. Can `prApproval` express "hold unless a verified automation identity", and what
   does that do to later pushes and to polled changes?
2. Can GitHub, on a personal repository, restrict writes to automation branches to
   the App?
3. Which check name is the aggregate, and can a ruleset pin it to the controller?
4. Does the default-branch publication and pin effect run on a reused build, and can
   it be repaired without a new push?
5. Where does the webhook endpoint live, and what happens while the controller is
   down?
6. Which host, and which niks3 version against the module's requirement?

## Impact

None until accepted. Acceptance changes `docs/contracts/ci.md`, the consumer adoption
runbook, retires `candidate.yml` and its composite actions for served repositories,
and adds a fleet aspect.
