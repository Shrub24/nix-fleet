# Package updates

`flakeModules.packageUpdates` is the fleet's one native-package refresh
interface. A repository imports it, registers the `packages.<system>` outputs
it owns, and gets a local batch app. The mechanism lives here; package
selection and package-specific policy stay in the owning repository.

```nix
# consumer flake-parts module
{ inputs, ... }:
{
  imports = [ inputs.nix-fleet.flakeModules.packageUpdates ];
  perSystem.packageUpdates.packages = [ "alpha" "beta" ];
  # Only needed when an updater owns a justified shared definition:
  # perSystem.packageUpdates.writeSets.alpha = {
  #   paths = [ "pkgs/alpha" "lib/shared-catalog.nix" ];
  #   reason = "The catalog is generated from alpha's upstream release.";
  # };
}
```

The exported module contributes only the typed option and the app; the
regression checks that pin its behavior are contributors of nix-fleet itself,
not part of the published module, so a consumer never inherits a fixture pinned
to the producer's evaluated packages.

Two commands run from the checkout:

```console
nix run .#update               # interactive: pick flake inputs and package updates
nix run .#update-packages      # plain: every registered package, or the named ones
```

`update` is the only interactive command. It shows one fzf list of flake inputs
and package updates, with a preview of each candidate, and applies only what is
accepted. Flake candidates come from `nix flake update --output-lock-file`, which
writes a candidate lock beside `flake.lock`, so nothing changes until a choice is
made. Package candidates are the registered packages whose `checkUpdate` reports
a newer release. Without fzf or a terminal, `update` refuses and names the plain
commands. The plain command does not prompt, and no command runs in CI.

Flake inputs need no wrapper command: `nix flake update [INPUT…]` already updates
the named inputs and prints each old and new revision. The picker applies its
accepted inputs that way too. The scheduled producer run refreshes the lock too (see
[Producer run](#producer-run-lock-refresh-then-packages)).

### Cheap release check: `--check`

```console
nix run .#update-packages -- --check            # newer releases, no prefetch, no edits
```

A package opts into a cheap check by declaring `passthru.checkUpdate`: a
derivation whose main program prints the newest stable release version on stdout
and exits 0. The package owns where to look (forge, repository, tag scheme), so
the runner never infers a release location from source attributes. The runner
builds the derivation, runs it, and compares its output with `version`. A package
without `checkUpdate`, a failing lookup, or a non-stable version is reported as
unknown with the reason, never guessed. Checking never edits files.

## Selection and refusal

`perSystem.packageUpdates.packages` is the typed registry of owned output
names; it defaults to empty. The app refuses, with a named `package-updates:`
error and before any updater runs, when the effective selection is empty,
duplicated, unregistered, or registered but absent from that system's
`packages`. Valid packages run in lexical order. No arguments selects the
whole registry.

A package family with shared pins has exactly one registered owner. Derived
outputs (for example a plugin built from the same upstream revision) inherit
the owner's update and are not registered or updated independently. The default
write set is `pkgs/NAME/`; an updater that genuinely owns shared files declares
them explicitly with a rationale, as in the example above.

## Update policy

The batch runs the evaluated `pkgs.nix-update` from the importing repository's
pinned package set — never a floating tool lookup — and passes
`--use-update-script`. Ordinary packages therefore get nix-update's standard
release discovery; a package needing custom release discovery or coupled-pin
handling declares `passthru.updateScript` and the same batch dispatches to it.
Stable releases are the default; branch or prerelease tracking requires that
explicit package policy. No second update engine and no arbitrary command
strings enter the registry.

`nix-update`'s `--use-update-script` path imports `<nixpkgs>`; the app pins
`NIX_PATH=nixpkgs=<evaluated nixpkgs>` so it stays on the same revision rather
than an ambient channel. The child inherits the caller's environment, so a
package update script's recorded-target variables (for example
`BIFROST_UPDATE_VERSION=2.2.6`) flow through unchanged.

Package update scripts are trusted repository code, not a sandbox. They must
not commit, reset, publish or deploy. Their repository-file changes are limited
to the package's declared write set.

## Failure and working-copy behavior

The app bundles `jj` on its runtime `PATH`; consumers do not need a global jj
installation. Each selected package runs serially in a disposable jj workspace
based on the current working copy, including uncommitted
changes and prior successful updates. A successful candidate is applied before
the next updater starts,
preserving the established cumulative behavior. A failed package's candidate is
discarded and reported; later packages still run. The batch writes reports for
all selected packages and exits with its outcome (below). It never creates a user
commit, bookmark or branch, publishes, or rewrites the caller's existing commits.
jj does record temporary workspace working-copy changes and workspace
add/forget operations in the repository operation log. Writes outside the
declared set fail that package. Promotion is file-level, not crash-atomic across
several files, which is what the `aborted` outcome exists for: a failure while
applying a successful candidate can leave the tree part-updated, so the batch
stops there rather than stacking another package on top of it.
The runner does not sandbox or roll back external side effects of trusted updater
scripts.

### Process contract

The exit status is the batch's outcome, and the same value is the `outcome` field
of the JSON report:

| Exit | `outcome`  | Meaning                                                                                                                    |
| ---- | ---------- | -------------------------------------------------------------------------------------------------------------------------- |
| 0    | `complete` | every selected package ran; no failures                                                                                    |
| 1    | `partial`  | the tree is proposable and carries per-item failures (a failed updater, an out-of-write-set write, a failed input refresh) |
| 2    | `aborted`  | nothing is proposable: the tooling or registry was unusable before any work, or adoption stopped part-way                  |

A caller that publishes a proposal keys off `outcome`: `complete` and `partial`
propose (the report names what failed), `aborted` does not. The scheduled
workflow reads it from the report file rather than from the exit status, because
the report exists only if the run reached its own end — a crash would otherwise
be indistinguishable from a completed run carrying failures. A failed updater's
own exit code stays in the report and on stdout rather than becoming the
batch's.

The default write set for package `NAME` is `pkgs/NAME/`. A package can declare
an exception under `perSystem.packageUpdates.writeSets.NAME`, with explicit
repository-relative `paths` and a non-empty `reason`. Shared generated catalogs
or genuinely coupled definitions can justify a broader set; duplicated package
versions should normally be derived from the package definition instead.

## Producer run: lock refresh, then packages

`update-packages` is the producer's batch. `--refresh-inputs` first moves every
flake input that is not deferred, and `--input NAME` (repeatable) moves exactly
the named inputs and overrides deferral. Both run `nix flake update` on the
names, and an unknown name is refused by name before anything runs. Then the
registered package updaters run against the refreshed lock.

Each package's before version is read before the refresh. A version that moved
only because the lock moved is therefore reported against the pin it started
from.

A run that names packages and no input never touches `flake.lock`.

```nix
perSystem.packageUpdates.deferredInputs.nixpkgs = "held until the toolchain bump is reviewed";
```

A deferral needs a non-empty reason, and a deferral that names no flake input
is refused by name. A refresh that fails is reported as `Flake input refresh did
not complete`; the packages still run against the old lock, and the run exits
nonzero.

The JSON report gains `inputs` (each moved input with its old and new revision,
last-modified date, source, and a comparison link) and `inputFailure`. The pull
request body lists moved inputs in their own table above the packages. The
scheduled workflow's pull request is a source for the update-candidate pipeline
([update-candidates.md](update-candidates.md)); it is not acceptance.

### The producer's two jobs

The scheduled workflow (`.github/workflows/package-updates-refresh.yml`) splits
the run, because `nix-update` executes the update scripts of the packages it
updates and must not hold a credential that can propose or push:

- **`update`** runs the batch, evaluates the refreshed tree, and records the
  proposal as a git patch plus the report files. It holds no App key and selects
  no environment. A patch is recorded only when the batch reported 0 or 1 _and_
  the evaluation passed, so `publish` is empty unless something valid exists.
- **`publish`** holds the App key (through the `automation` environment), applies
  that patch to a clean checkout of the base the refresh ran on, and opens or
  updates the pull request with the report as its body. It runs no repository
  code: the patch and the reports cross as artifact data.

The publisher refuses to apply a patch against a moved base, because a wholesale
lock rewrite taken from an older revision would revert whatever landed in
between; the next scheduled run redoes the refresh instead. `git apply` is
all-or-nothing, so a partial proposal is never published.

## Refresh is not acceptance

The app edits package pins, and in a producer run the moving inputs of
`flake.lock`. It does not update OCI references, run repository checks, or
merge. A candidate is accepted only after the requested updates complete **and**
the repository's declared acceptance checks pass; a hash-prefetch build is not an
acceptance build. Refreshing again against the same recorded release targets
must produce no further changes.

## Bifrost (initial owner)

This repository registers `bifrost`; `bifrost-voyage-plugin` derives the host
build context and is not a second writer.

Bifrost's `passthru.updateScript` (`pkgs/bifrost/update.py`) selects only
stable `transports/vX.Y.Z` tags, excluding unrelated component tags and
prereleases, and refreshes the coupled build family as one unit: transport
version, upstream source revision and hash, then the Go vendor hash and the
embedded UI npm hash through
`nix-update --flake --version=skip --no-src --subpackage ui`. Setting
`BIFROST_UPDATE_VERSION=<version>` records an exact target for the acceptance
and idempotence runs. A missing or unsupported candidate fails visibly rather
than silently selecting an older release.

Acceptance for an updated candidate is the existing native gates: the
gateway/UI startup check, the Voyage-hook check against the real binary, the
governance/CEL module check, formatting, all-system evaluation, and
fresh-store evaluation with import-from-derivation disabled. The production
pin moves only when every gate passes. See the
[recorded Bifrost update](../validation/bifrost-package-update.md) for the first
candidate, gate results and limitations.

## Deferred

Consumer migration and consumer promotion policy are separate adoption work.
Renovate keeps tagged flake inputs (no tagged input exists yet), OCI references and
Actions references. Renovate does not own `flake.lock`.
