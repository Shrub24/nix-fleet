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
**Status:** active
**Evidence:** confirmed
**Source:** `docs/contracts/package-updates.md`, `.github/workflows/package-updates-refresh.yml`, 2026-10-10

Every evaluation the batch performs passes `--no-write-lock-file`, and the
scheduled workflow never commits a `flake.lock` change.

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
based on the caller's current working-copy state; the app does not create or
rewrite jj history.

**Reason:** package updates run in a jj-managed fleet, and bundling jj makes the
staging tool available to downstream app users without a global installation.
The workspace carries uncommitted starting edits and earlier successful package
updates into each candidate, while failed candidates can be discarded without
reconstructing the caller's state.

**Rejected alternative:** filesystem snapshots and per-file copy-back avoid a jj
dependency but cannot make multi-file promotion crash-atomic; they also require
reimplementing workspace isolation and safe recovery. Bundling jj makes that
trade-off unnecessary for this fleet.
