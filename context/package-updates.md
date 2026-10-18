# Package updates

## Versions and changelogs are read from the derivation, not the updater's output

**Id:** faff9539-71f2-4b3f-aef7-178d4b8e1428
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** package-updates reporting, `pkgs/package-updates/src/package_updates/runner.py`, `docs/contracts/package-updates.md`, 2026-10-10

The report's before and after versions, and its changelog links, come from one
`nix eval` per package per phase reading
`packages.<system>.<name>.version` and `.meta.changelog`.

**Reason:** `nix-update`'s stdout is not a stable interface, and for the packages
that matter most here it cannot be the source at all: `--use-update-script` hands
discovery to the package's own script, so the version a batch is expected to
produce is only visible after evaluation. Reading the derivation also means a
failed read degrades to null versions in the report instead of aborting a batch
whose pin does not currently evaluate.

**Rejected alternative:** parse `nix-update`'s output, or ask the forge for the
newest tag. Both make the report depend on an interface or an endpoint this repo
does not control.

**Rejected alternative:** a `${version}`/`${oldVersion}` substitution layer in the
report renderer. `meta.changelog` is a Nix string, so interpolation belongs in the
package's own attribute; the renderer-side copy was written and then removed as
generality with no user.

## The refresh batch owns package pins; renovate owns the lock file

**Id:** dcb855ef-a94d-4acf-8dbd-43a7f146b085
**Type:** decision
**Status:** superseded
**Superseded by:** ff7db418-75dc-41b9-b8b0-a4b019125ba7
**Evidence:** confirmed
**Source:** `docs/contracts/package-updates.md`, `.github/workflows/package-updates-refresh.yml`, 2026-10-10

Historical: the batch's own evaluations passed `--no-write-lock-file`, and the scheduled workflow never committed a `flake.lock` change. Superseded by the producer decision below.

**Reason:** `flake.lock` is the fleet's shared-input authority — consumers alias
the inputs they want held in step — so it has one owner (renovate) and one review
path. A refresh that also moved nixpkgs would put the package pin and the
toolchain bump in the same commit, and a lock conflict would block an otherwise
finished refresh.

**Rejected alternative:** one batch that owns both. The candidate becomes
unreviewable, and the lock bump hides inside a package pull request.

## The report is written outside the checkout

**Id:** 96c51777-3f35-4d0c-ad89-28fe7b14deac
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `.github/workflows/package-updates-refresh.yml`, 2026-10-10

The workflow writes `--json` and `--markdown` into `$RUNNER_TEMP`, passes the
markdown through the action's `body-path`, and also prints the JSON in the step
log and uploads it as an artifact.

**Reason:** the reports are evidence for the pull request, not repository content.
Inside the checkout the create-pull-request action would commit them, so every
refresh would carry a generated file that churns on each run and belongs to no
one; keeping them only in the log loses them when the run's retention ends.

**Rejected alternative:** commit the report alongside the pin changes. The review
then reads a generated file as though it were a change, and the next run rewrites
it.

## Release-note bodies are deferred; the report carries a link

**Id:** a9611135-1af2-4569-85b6-88a2bc89d9b8
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `docs/contracts/package-updates.md`, 2026-10-10

An entry carries a changelog link read from `meta.changelog`; it does not fetch or
embed release notes. `bifrost` needs a percent-encoded slash
(`transports%2Fv<version>`) because its tags are `transports/vX.Y.Z`.

**Reason:** fetching release notes needs a token and per-forge handling, which
moves network access into the runner and breaks its offline evaluation check —
the property that lets the batch run from a checkout with no ambient credentials.

**Revisit when:** a consumer adopts the workflow and wants renovate-style note
bodies. The fetch then belongs in the workflow, which already holds a token, while
the runner keeps reading only the derivation.

## An Actions-created pull request has two environment prerequisites

**Id:** 192140f2-3972-473e-ae59-d91a92c1de70
**Type:** constraint
**Status:** active
**Evidence:** confirmed
**Source:** GitHub Actions permissions API and workflow-trigger documentation, 2026-10-10

Creating the refresh pull request with `GITHUB_TOKEN` requires the repository
setting _Allow GitHub Actions to create and approve pull requests_
(`can_approve_pull_request_reviews`); the workflow's own
`permissions: { contents: write, pull-requests: write }` grants the scopes but
cannot lift that setting, which is off by default on a personal repository. A
`pull_request` run caused by `GITHUB_TOKEN` is then created in an
approval-required state, so a user with write access approves it before `ci.yml`
runs; a fine-grained PAT or a GitHub App token makes those runs start on their
own.

**Reason:** neither fact is visible anywhere in the tree, and both fail at the
last step of an otherwise successful run — the refresh, the evaluation and the
artifact upload all succeed first.

**Related:** the producer now creates its pull request with the automation App token (see `update-candidates.md`), so this setting no longer gates the refresh. It still applies if the App is removed.

**Related:** the step also requests two labels, and adding a label the repository
does not have returns 404, which fails the same step. `dependencies` and
`automated` were created for that reason.

## Package staging uses disposable jj workspaces

**Id:** 5597d9b3-ffed-412d-a124-943639676279
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `docs/contracts/package-updates.md`, package-update transaction design, 2026-10-11

The update app bundles jj and stages each package in a disposable jj workspace
based on the caller's current working-copy state. The app does not create user
commits, bookmarks, or branches, or rewrite caller commits; jj does record the
temporary workspace changes and add/forget operations in its operation log.

**Reason:** package updates run in a jj-managed fleet, and bundling jj makes the
staging tool available to downstream app users without a global installation.
The workspace carries uncommitted starting edits and earlier successful package
updates into each candidate, while failed candidates can be discarded without
reconstructing the caller's state.

**Rejected alternative:** filesystem snapshots and per-file copy-back avoid a jj
dependency but cannot make multi-file promotion crash-atomic; they also require
reimplementing workspace isolation and safe recovery. Bundling jj makes that
trade-off unnecessary for this fleet.

## One interactive `update` over plain commands

**Id:** 0c4f0a7e-6b1d-4f5e-9d2a-3e7b8c1f2a90
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `pkgs/package-updates/src/package_updates/interactive.py`, `pkgs/package-updates/src/package_updates/flake_update.py`, `modules/flake/package-updates.nix`, 2026-10-12

Plain `update-packages` stays scriptable and never prompts. There is no `update-flake` wrapper: `nix flake update [INPUT…]` already updates named inputs and prints their revisions, so a wrapper added only a second name for it. The only interactive command is `update`, a single fzf list of flake inputs and package updates, which applies only what is accepted.

**Reason:** a picker on each command multiplies the surfaces to learn and test. One interactive command over the two candidate sources keeps the picker in one place, and the plain commands remain the CI-safe, scriptable path.

**Rejected alternative:** a picker in `update-flake` alone. It leaves package updates without the same review step.

**Rejected alternative:** a Python TUI. fzf is already in nixpkgs, multi-select with a shell preview is enough, and the packaged runner stays stdlib-only.

**Mechanism:** flake candidates come from `nix flake update --output-lock-file` into a scratch lock, so `flake.lock` is untouched until a choice is made; accepted inputs are applied by name. Package candidates come from `passthru.checkUpdate`.

**Rejected alternative:** a jj workspace for the flake preview. `flake.lock` is one file, so a copy is the whole isolation boundary.

## Cheap release checks come from the package, not the runner

**Id:** 7d2e9b41-5c8a-4f1e-b6d3-2a9f0c4e8b15
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `pkgs/package-updates/src/package_updates/check.py`, `pkgs/bifrost/default.nix`, `docs/contracts/package-updates.md`, 2026-10-12

`update-packages --check` runs each package's own `passthru.checkUpdate` and compares its printed version with `version`. The package owns where releases live.

**Reason:** a `fetchFromGitHub` source is a derivation and exposes no owner or repo, and monorepo tags such as `transports/v<version>` cannot be inferred from the version. Keeping the lookup beside the updater means the check and the updater cannot drift apart, and the runner stays ignorant of forges.

**Rejected alternative:** runner-side inference from `src` attributes. It fails silently for the `fetchFromGitHub` case, and it duplicates the release metadata the updater already knows.

**Rejected alternative:** a declared `releaseRepository` attribute on `passthru`. It duplicates data the lookup script must already contain, and nothing enforces agreement between the two.

**Consequence:** a package without `checkUpdate` reports unknown rather than a guess. Each package adopting the check must maintain its lookup, and a lookup failure is reported as a reason, never as current.

## The producer owns the flake lock and the package pins

**Id:** ff7db418-75dc-41b9-b8b0-a4b019125ba7
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `openspec/changes/update-candidate-pipeline/design.md` (decisions 6 and 7), `docs/contracts/package-updates.md` (producer run), 2026-10-11

The scheduled producer run refreshes the moving flake inputs first and then the
registered packages, in one batch and one pull request. Every package updater is
therefore staged on the lock it will land with, and the cache warms against the
tree that lands.

**Reason:** a compiled package's output depends on nixpkgs. A lock refresh
produced by another pull request would warm the cache against a lock that never
lands, and the package pins would be checked against the wrong toolchain. The
producer also needs to defer a broken input, which Renovate's lock maintenance
cannot express per input. Renovate keeps the declarations it can match by
version (tagged inputs, Actions, OCI).

**Rejected alternative:** Renovate lock PR plus a stacked package commit. It
needs `gitIgnoredAuthors` or a branch the pipeline must not touch. A separate
package PR warms the wrong lock.

**Revisit when:** a consumer needs per-input Renovate policy that the producer's
deferral list cannot express, or Renovate gains a per-input exclusion.

Each package's before version is read before the lock moves, so a version that
changed only because nixpkgs moved is reported against the pin it started from. Reading it after the refresh would report the new pin as the old.

## The batch's exit status says whether its result is proposable

**Id:** 4c6e8f16-c44b-4441-b9f9-8a9fc3f8b331
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** `pkgs/package-updates/src/package_updates/runner.py` (`EXIT_CODES`, `adopted`/`aborted`), `tests/package-updates/`, 2026-10-11

Exit 0 is a clean run, 1 is a run that completed with per-item failures and whose
tree is still proposable, and 2 is a run with nothing to propose. The report's
`outcome` carries the same value.

**Reason:** the workflow publishes only on 0 and 1, so a single failing package no
longer suppresses the refresh. Previously any failure exited nonzero, so the
workflow never reached its pull-request step and the only trace was a log line:
the operator saw "nothing to update" while a pin stayed stale. A failed updater's
own exit code is preserved in the report and on stdout, so this loses no detail.

**Rejected alternative:** keep "nonzero means do not propose" and have the
workflow publish on failure anyway. It cannot tell a partially applied tree from a
rolled-back one, so it would publish a half-updated checkout.

**Revisit when:** a caller appears that needs the failing updater's raw code as the
process exit status.
