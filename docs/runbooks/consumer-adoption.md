# Adopting fleet CI in a repository

Pin external workflow calls to `@v3` or to a full commit SHA. `v3` is the current
contract milestone; `v1` and `v2` (`11a028b2`) are legacy — `v2` predates bundled
actions, nested retention, the cold-store evaluator, the runner-owned builder key
and the shared verify/pin root. In the examples below, replace `<sha>` with the
selected full commit (`git rev-parse v3` prints the tagged revision), never
`@main`.

**Keep the pin current with a tag, or a SHA plus a version comment — never a bare
SHA.** Renovate disables a `uses:` pinned to a bare SHA because it cannot tell
which tag that commit belongs to: no comment, no updates, silently stale. The two
forms it does maintain are

```yaml
uses: Shrub24/nix-fleet/.github/workflows/build-push-cache.yml@v3 # moves to v4 at the next major
uses: Shrub24/nix-fleet/.github/workflows/build-push-cache.yml@a1b2c3d # v3
```

where the trailing `# v3` is what makes the digest follow the tag. A consumer's
Renovate config that produces the second form on its own:

```json
{
  "extends": ["config:recommended", "helpers:pinGitHubActionDigests"],
  "packageRules": [{ "matchDepTypes": ["workflow"], "pinDigests": true }]
}
```

`workflow` is Renovate's depType for a job-level `uses:` of a reusable workflow, so
that rule is what covers these calls rather than ordinary actions. Nothing else is
needed from the consumer: nix-fleet is public and the pin names no credential.

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
build, 39593416105 for the pin). **B is unproven end to end** — every part has run in
nix-fleet, but no consumer has completed a promotion, and nix-fleet's own
`PROMOTION_POLICY` is `label`. Three claims are specifically unmeasured:

- a **cross-repository** call of a SHA-pinned `validate.yml` (nix-fleet only ever
  calls its own files locally, so `job.workflow_sha` has never been exercised from
  another repository);
- the **runner-owned `0600` builder key** opening a real distributed build (§1
  verification is still the only way to confirm a build went remote);
- a consumer's **promotion → nested pin** run, which is the last unrun path in B.

Adopt B expecting to debug it.

Where the two repositories stand: `nix-dotfiles` has all six Path B trigger files
but pins `11a028b2`, so it runs the pre-fix contracts — the cold-store evaluation
failure it hit comes from that pin, not its flake. `nix-homelab` is at Path A only,
pinned at `e5d74415`, which predates the `builder_attr` → `profile` rename.

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
3. **Nothing else.** No fleet flake input is needed for the build, and importing one
   does not by itself improve cache locality.

   Locality is a property of **derivation identity**, not of which flake inputs are
   connected: a consumer substitutes its own closure only when the derivations it
   evaluates are the ones the cache already holds. Those were produced from the
   nixpkgs revision this repository's `flake.lock` pins, so a consumer whose nixpkgs
   is a different revision — or the same revision with different overlays, config or
   `system` — rebuilds, however its inputs are wired.

   The direction matters. `inputs.nix-fleet.inputs.nixpkgs.follows = "nixpkgs"` makes
   the _fleet's_ artefacts use the consumer's nixpkgs; it changes nothing about the
   consumer's own derivations. To share the cache's derivations the consumer's
   `nixpkgs` must follow the **fleet's** nixpkgs (`inputs.nixpkgs.follows =
"nix-fleet/nixpkgs"`, or the same revision pinned directly), and its overlays and
   module config must leave package derivations alone. That is a flake change with a
   cost — the consumer inherits the fleet's bump cadence — so treat it as an
   optimisation to adopt deliberately, not a prerequisite.

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

`verify-cache` is the one worth having on every push: it reports whether the cache
serves the root you would pin (`<targets>.<system>.<subject>`) and never fails on a
miss. It measures the same root as retention, so a green run means the pin would be
refused-or-not for the same path.

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
   `validate.yml` requires three things of the flake: `checks.x86_64-linux.treefmt`
   (the format job builds it), evaluation under `nix flake check --no-build
--all-systems` (the evaluate job primes sources with a writable, IFD-disabled
   evaluation first, so a cold store works), and — with `generated_files: check` — a
   `write-flake` app that regenerates only `flake.nix` and `flake.lock`.

   Import-from-derivation stays off, and there is no option to re-enable it: the
   evaluation job has no builders, and a mode that builds there would restore the
   coupling the cold-store gate exists to avoid. A flake that cannot evaluate
   without IFD therefore removes it before adopting this suite. `nix-homelab` did:
   upstream `degoog` generates its `bun.nix` during evaluation with
   `runCommandLocal`, so the repository carries the generated file, passes it as
   `bunDeps.bunNix`, and keeps it honest with a check that regenerates it from the
   pinned lockfile and diffs. The one-line proof that the removal worked:
   `nix eval --option allow-import-from-derivation false --raw
.#checks.<system>.<host>.drvPath`.

   An externally pinned call runs the preparation action from its own revision.
   Only nix-fleet's own pull requests use the default-branch action, so a pull
   request cannot supply the procedure that judges it.

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

   Before B, two attributes decide it, and both fail by name rather than subtly:
   `nix eval .#checks.x86_64-linux --apply builtins.attrNames` must list `treefmt`
   (`validate.yml` builds it; homelab formats in a development shell and its check
   set does not contain one today), and the flake must evaluate with IFD off, which
   its generated `bun.nix` establishes.

2. **`agent-radar`** — smallest Path A: no existing Nix CI to unwind, so it
   proves that a repository with no fleet input builds and publishes.
3. **`memex`** — Path A on a real, foreign closure. Both `memex` and
   `agent-radar` track `nixpkgs-unstable` directly and have no fleet input, which
   is the honest default for a standalone consumer: the build works, but almost
   nothing of its own closure substitutes, so expect a first run that compiles.
   What changes that is derivation identity: its `nixpkgs` following the fleet's
   `nixpkgs` (not the fleet input following the consumer's), or a cache warmed by a
   local `nix-fast-build` of that same revision — not the workflow.
4. **`nix-dotfiles`** — Path A, replacing the checks it builds locally today.
   Its flake already follows nix-fleet's `flake-parts`, `flake-file` and
   `import-tree`, so locality should be good.
5. **`Pi-Bolt.nix`** — Path A when its CI next changes.

Each adoption is one pull request per repository, plus the prerequisite changes
in the cache claims and the tailnet credential. Nothing in nix-fleet changes to
adopt a consumer.
