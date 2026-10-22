# Adopting fleet CI in a repository

Pin external workflow calls to a full nix-fleet SHA containing the composition
fixes; let Renovate update that pin. Release tags mark contract milestones. `v2`
is retained for legacy callers but predates bundled actions and nested retention.
In the examples below, replace `<sha>` with the selected full commit.

A consumer repository declares **what** to build. nix-fleet owns **how**: the
builders, the cache, the coordinator configuration and the validation. Nothing
here requires importing `flakeModules.fleet`, re-exporting builder metadata or
copying workflow bodies.

Three levels, cumulative. Pick by what the repository wants to know, not by how much
Nix it contains.

| level                                | for                                                                                     | adds                                                                        |
| ------------------------------------ | --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| **A — build and publish**            | any repository that is built at all                                                     | one workflow file                                                           |
| **A+ — pin and verify your closure** | repositories that want their own last-known-good protected from GC                      | A, plus one module import and a pin prefix                                  |
| **B — plus the update lifecycle**    | repositories whose dependency updates you want validated, built, evidenced and promoted | A+, plus five thin trigger files, an App, an environment, labels, a ruleset |

State today: **A and A+ are proven** on nix-fleet itself (runs 39543925779 for the
build, 39593416105 for the pin). **B is unproven end to end** — the mechanism exists
and every part has run in nix-fleet, but no consumer has completed a promotion, and
nix-fleet's own `PROMOTION_POLICY` is `label`. Adopt B expecting to debug it.

## 0. Prerequisites that are not in the consumer's hands

Do these first; each fails closed with a specific error, and guessing at them
costs more than reading them.

1. **A cache rule for the repository.** nix-fleet's cache claims bind
   `repository` per caller, so a repository absent from the list cannot upload or
   pin (`401`). `nix-homelab`, `nix-dotfiles`, `memex`, `Pi-Bolt.nix` and
   `agent-radar` are listed; verify rather than assume — `docs/runbooks/cache-pins.md`
   §2 shows how to read the rendered claims off the cache host.
2. **A tailnet identity that matches the caller.** The Tailscale credential's
   `job_workflow_ref` names nix-fleet's workflow file, and the repository/ref
   claims name the consumer. A repository that is not in the credential joins and
   then fails at the API, or fails to join — both are credential changes, not
   workflow changes.
3. **Nothing else.** No fleet flake input is needed for the build. For cache
   _locality_ (substituting a consumer's own closure rather than rebuilding it),
   add `nixpkgs.follows` on the fleet input — a flake change, and the single
   highest-value one for a consumer with a different `nixpkgs` revision.

## 1. Path A — one file

Add the builder key once:

```sh
gh secret set FLEET_BUILDER_SSH_KEY --repo <owner>/<repo> < ~/.ssh/fleet_builder
```

Then one workflow. Dispatch-only is the safe default; add `push`/`pull_request`
only after it has run green by hand.

```yaml
name: fleet-build
on:
  workflow_dispatch:
concurrency:
  group: fleet-build
  cancel-in-progress: false
permissions:
  contents: read
  id-token: write # the cache token; a call with less fails at startup
jobs:
  build:
    uses: Shrub24/nix-fleet/.github/workflows/build-push-cache.yml@<sha>
    with:
      targets: .#checks
      systems: x86_64-linux aarch64-linux
      runner_system: x86_64-linux
      profile: ci
    secrets:
      BUILDER_SSH_KEY: ${{ secrets.FLEET_BUILDER_SSH_KEY }}
```

Do not name the consumer's concurrency group `fleet-build-stage`: that group belongs
to the called workflow's build job, and a job cannot acquire a group its own run
already holds — the call then fails at startup with no steps. Any other name is
fine; the two groups serialise independently.

Inputs, all optional: `runner_system` (coordinator architecture, default
`aarch64-linux`), `systems` (targets, default both), `profile` (fleet builder
profile, default `ci`), `targets` (default `.#checks`), `revision` (default the
triggering ref), and the escape hatches `tailnet`, `ts_client_id`,
`ts_audience`, `cache_api_url`. The caller must grant `contents: read` and
`id-token: write`; GitHub validates every job in the called workflow against that
grant, so a narrower grant fails the whole call before any job starts.

Verify from the run, not from the workflow text:

- the log shows `coordinator=<store path>` and an `install.sh` with no error;
- the report lists the effective builder value and per-builder `runner` and
  `root` SSH results;
- **builder-side**, confirm work actually went remote. The coordinator's log
  cannot tell you: `ssh <builder> 'sudo journalctl -u nix-daemon --since -20min | grep "accepted connection"'`
  and the derivation logs under `/nix/var/log/nix/drvs`. A silent local fallback
  still reports success.

A repository that already builds in its own CI should **stop** doing so once this
path is green. Routine CI evaluates and formats; this workflow is the only thing
that builds and publishes, and two publishers for one closure is how a cache
starts lying.

## 2. Path A+ — pin and verify your own closure

Both workflows read the cache route, the tailnet identity and the API from the fleet
revision that defines them (`job.workflow_repository` / `job.workflow_sha`), so no
cache coordinate goes into your flake. What they need from you is one attribute per
system: the aggregate whose closure is everything you publish.

Import the published module — a package module, not the fleet schema:

```nix
imports = [ inputs.nix-fleet.flakeModules.cacheRoot ];
```

or define the same attribute yourself if you would rather not take the input:

```nix
packages.<system>.cache-root = pkgs.linkFarm "cache-root" (
  lib.mapAttrsToList (name: path: { inherit name path; }) (
    lib.filterAttrs (name: _: name != "cache-root") config.packages
  )
);
```

`verify-cache` is the one worth having on every push: it reports coverage with
notices and never fails on a miss.

```yaml
jobs:
  verify:
    uses: Shrub24/nix-fleet/.github/workflows/verify-cache.yml@<sha>
    with:
      systems: x86_64-linux aarch64-linux
```

Pinning moves a name that means "our current main", so it belongs to the event that
lands a revision, not to a diagnostic. Path B calls it automatically after
promotion. A build-only consumer may call it in a dependent job after a successful
build, or expose its own manual trigger:

```yaml
jobs:
  pin:
    permissions:
      contents: read
      id-token: write # the cache token; pin-cache joins the tailnet
    uses: Shrub24/nix-fleet/.github/workflows/pin-cache.yml@<sha>
    with:
      pin_name: auto # <repository>-main, one pin per system
      systems: x86_64-linux aarch64-linux
```

`subject` defaults to `cache-root`; set it if your aggregate derivation has another
name. A jobset such as `hydraJobs` is an attrset, not a pin root: aggregate the
selected outputs with a `linkFarm` first. The pin protects only the chosen root's
closure; everything outside it remains reclaimable.

Two things shape the aggregate, and both fail quietly:

- **Artefacts only, never checks.** A check's output is rebuilt whenever its inputs
  move, so a verdict in the set moves the pin on every commit.
- **Everything you publish.** A missing package is reclaimed by GC while the pin
  still looks correct.

Pin names share one server-side registry, so keep them namespaced
(`<repository>-main`); the cache's `pins` rule for your repository reserves that
prefix.

## 3. Path B — the update lifecycle

Everything in Path A, plus the pieces below. Add them in this order; each is
verifiable on its own.

1. **Validate.** A workflow named `ci` calling `validate.yml@<sha>` with
   `generated_files: check`. Its `pull_request` types include `labeled`, so
   acceptance revalidates. Do not copy nix-fleet's `ci.yml`: its `$/` references
   are for internal composition. No scripts or actions need copying either.
   The consistency guard deliberately reads the preparation action from fleet
   `main`; this is the exception to pinned validation, preserving fleet PR trust.
2. **The pipeline trigger.** `on: workflow_run: {workflows: [ci], types: [completed]}`
   → `uses: .../pipeline.yml@<sha>`, with `secrets: inherit` and the permission
   union its jobs need (`contents: write`, `statuses: write`,
   `pull-requests: write`, `id-token: write`). `on:` cannot be inherited, so this
   file is the consumer's; the orchestration is not.
3. **The App and environment.** Register a GitHub App, install it on the
   consumer repository, and create an environment named `automation` holding
   `AUTOMATION_APP_PRIVATE_KEY` with a branch policy restricted to the default
   branch. Variables: `AUTOMATION_APP_ID`, `AUTOMATION_APP_SLUG`,
   `PROMOTION_POLICY=label`, and optionally `CANDIDATE_TARGETS`,
   `CANDIDATE_SYSTEMS`, `CANDIDATE_RUNNER_SYSTEM`, `CANDIDATE_PROFILE`,
   `AUTOMATION_UPDATE_AUTHORS`, `CACHE_PIN_NAME`. Set `CANDIDATE_SYSTEMS` to the
   systems the repository actually exposes. Retention defaults to
   `.#packages.<system>.cache-root`; `CACHE_PIN_TARGETS` and `CACHE_PIN_SUBJECT`
   override it independently of the build selection.
4. **Labels.** `accept-update`, `dependencies`, `automated`. Creating a label the
   repository does not have fails the producer at its pull-request step with a
   `404`.
5. **Promotion and acceptance.** A thin `on: status` caller of
   `promote-candidate.yml` grants **both** `contents: write` and `id-token: write`,
   and passes `secrets: inherit`. The dependent pin job receives the revision
   actually pushed; a human-status no-op starts no pin job. A failed pin turns
   the run red without undoing the successful promotion. `accept.yml` uses
   `pull_request_target: {types: [labeled, unlabeled]}` and `statuses: write`;
   `candidate-sweep.yml` needs `contents: write` and a scheduled caller.
6. **The ruleset.** Require `update-candidate` on the default branch, pinned to
   the App's integration id, with **no** bypass and **no** pull-request rule.
   Do not require `update-accepted`: revoking the label posts it as `failure`
   deliberately, and requiring it blocks every pull request whose acceptance was
   withdrawn. Enable nothing here until a candidate has validated and promoted
   by hand once.

With `PROMOTION_POLICY=label`, applying `accept-update` is what authorises
promotion, and the marker is bound to the head it was applied to: a push after
labelling invalidates it and the revision must be re-validated.

A promotion caller for an x86-only consumer:

```yaml
name: promote
on:
  status:
permissions:
  contents: read
jobs:
  promote:
    uses: Shrub24/nix-fleet/.github/workflows/promote-candidate.yml@<sha>
    permissions:
      contents: write
      id-token: write
    with:
      systems: x86_64-linux
      targets: .#packages
      subject: cache-root
    secrets: inherit
```

Before enabling `CACHE_PIN_NAME`, include the retention root in the approved build.
For example, dotfiles may keep building `.#ciRoot`, add
`packages.x86_64-linux.cache-root` over its deployable outputs, and include that
root in `ciRoot`. Its formatting checks still build but need not be retained.
Homelab can select its desired host toplevels the same way; importing the default
package aggregate does not automatically include `nixosConfigurations`.

## 4. What a consumer does not get, and why

- **Old entry points with new behaviour.** A SHA pin only receives these fixes
  when updated. Existing `v1` and `v2` tags remain unchanged. A Tailscale claims
  failure on a SHA-pinned call is a fleet credential issue, not a reason to
  duplicate its configuration in the consumer.
- **Renovate-managed tagged flake inputs.** nix-fleet has none yet, and its
  Renovate config keeps only `github-actions`.
- **A linear history on the default branch.** Preparation merges the base into
  the candidate, so a promoted revision is a merge commit whenever the source was
  behind.

## 5. Order of adoption

1. **`nix-homelab`** — already the closest, and the only repository that will
   carry stale copies until it moves. It pins an older nix-fleet SHA and passes
   `builder_attr` in `fleet-build.yml`; bump the pin and rename the input in the
   same change. It also has its own 83-line `package-updates-refresh.yml` and its
   own `ci.yml`, both of which Path B supersedes — its producer is a separate
   copy of a workflow nix-fleet now owns end to end, so adopting B is partly
   deletion. Do A first (two-line change, immediately verifiable), then B.
2. **`agent-radar`** — smallest Path A: no existing Nix CI to unwind, so it
   proves that a repository with no fleet input builds and publishes.
3. **`memex`** — Path A on a real, foreign closure. Both `memex` and
   `agent-radar` track `nixpkgs-unstable` directly and have no fleet input, which
   is the honest default for a standalone consumer: the build works, but almost
   nothing of its own closure substitutes, so expect a first run that compiles.
   `nixpkgs.follows` on a fleet input, or a cache warmed by a local `nix-fast-build`,
   is what changes that — not the workflow.
4. **`nix-dotfiles`** — Path A, replacing the checks it builds locally today.
   Its flake already follows nix-fleet's `flake-parts`, `flake-file` and
   `import-tree`, so locality should be good.
5. **`Pi-Bolt.nix`** — Path A when its CI next changes.

Each adoption is one pull request per repository, plus the prerequisite changes
in the cache claims and the tailnet credential. Nothing in nix-fleet changes to
adopt a consumer.
