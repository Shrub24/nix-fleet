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
**Status:** superseded
**Superseded by:** https://github.com/Shrub24/nix-fleet — 96903ada-82b9-463b-a5e5-eec3eafed9be — as of 2026-11-18
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
**Status:** superseded
**Superseded by:** 21713763-f5e2-4d43-8a61-7db01a6756b1
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

## One CI module, one namespace, each policy beside what it governs

**Id:** fc822977-5a0e-4e88-bb64-a28570b7bff1
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** design conversation, 2026-11-19; `openspec/changes/unify-ci-surface/design.md`

`flakeModules.ci` is the only CI module and `ci` its only namespace; the update
registry (`ci.updates.packages`, `.lockfiles`, `.commands`) is flake-level. A
repository's CI policy sits in one `modules/flake/ci.nix`, a package is registered
by the feature that owns it, a package's version policy is its
`passthru.updateScript`, and an input's is its flake-file declaration.

**Reason:** the feature had spread across `flakeModules.ci`, `flakeModules.packageUpdates`
and `flakeModules.cacheRoot`, two namespaces and two scopes, and consumers imported
modules `ci` already imported. What a repository updates does not vary by system, so
a per-system registry only invited per-system drift. A policy kept beside what it
governs cannot name something that no longer exists.

**Rejected alternative:** package version policy as `ci.updates.packages.<name>.version`.
`passthru.updateScript` is nixpkgs' convention and travels with the package when it is
upstreamed; a second field would restate it.

**Rejected alternative:** keeping `packageUpdates` as a standalone module for repositories
without CI. None exists, and the update effect is what runs it.

## Flake inputs move by a policy on their declaration

**Id:** 21713763-f5e2-4d43-8a61-7db01a6756b1
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** design conversation, 2026-11-19; `openspec/changes/unify-ci-surface/design.md`
**See:** package-updates.md#the-producer-owns-the-flake-lock-and-the-package-pins — ff7db418-75dc-41b9-b8b0-a4b019125ba7 — as of 2026-11-20
**Revisit when:** flake-file declares an update policy of its own, or flake-edit gains release selection and `version_regex` upstream

The scheduled run moves every flake input by one of four policies — `stable`,
`unstable`, `branch`, `fixed` — derived from its locked ref unless its flake-file
declaration sets `update.*`. A `fixed` input needs a reason; that replaces the
deferral list. Release-tag pins move in the same transaction as the lock and the
packages, so the producer still owns everything the build reads.

**Reason:** tag-pinned inputs are the large rebuilds (vicinae, noctalia, Pi-Bolt), and
Renovate could not move them: its nix manager does not bump refs, a regex manager edits
only the file it matched while flake-file needs `flake.nix` regenerated and the input
relocked, and hosted Renovate runs no post-upgrade command. Three of dotfiles' five
tag inputs had never moved. The declaration is the one place the input already lives,
and `write-flake` renders only flake reference attributes, so the policy never reaches
`flake.nix`.

**Rejected alternative:** a `ci.updates.inputs.<name>` table. It is a second list keyed
by input name that drifts from the inputs and needs an unknown-input check.

**Rejected alternative:** a comment marker in the declaration, Renovate-style. It is a
grammar of our own, unevaluated and untyped, and flake-file would have to emit it into
the generated `flake.nix`.

**Rejected alternative:** following a release branch. Most upstreams have none, and it
builds unreleased code.

**Consequence:** a repository without flake-file has no declaration to carry an
override and follows the derived default. Tag-vs-branch is asked of the remote
because a name such as `nixos-25.11` looks like a version and is a branch.

## flake-edit chooses tag moves, patched here until upstream

**Id:** 7f402e09-af33-4f10-8591-eda851edf704
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** design conversation, 2026-11-19; `pkgs/flake-edit/`
**See:** package-updates.md#flake-inputs-move-by-a-policy-on-their-declaration — 21713763-f5e2-4d43-8a61-7db01a6756b1 — as of 2026-11-20
**Revisit when:** both patches are released upstream, at which point the package is nixpkgs' unchanged

flake-edit picks the new tag on a scratch copy of `flake.nix`; the runner writes the
result back to the declaring file. nix-fleet packages nixpkgs' flake-edit with two
patches: a per-input `version_regex` with nix-update's semantics, and selection that
prefers the forge's latest release, else the highest same-prefix tag, excluding
pre-releases unless admitted.

**Reason:** flake-file already invokes flake-edit inside `write-flake`, so it is a tool
the fleet carries anyway. Unpatched, it chose `rc.13-v0.23.2` for hermes-agent over the
`v0.23.3` release, because it strips any non-digit prefix and ranks the result
`13.0.0`; it never consults the latest-release marker, which was right for every
input that publishes releases.

**Rejected alternative:** a resolver inside the update runner. It would be a second
implementation of what flake-edit does, maintained here alone.

**Rejected alternative:** updatecli, which needs a manifest per input restating
`flake.lock`; nvchecker, which only discovers versions.

**Consequence:** flake-edit edits only `flake.nix`, so the write-back into a module file,
the `write-flake` regeneration and its comparison stay in the runner.
