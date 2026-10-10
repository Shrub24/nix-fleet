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

Run the batch from the checkout:

```console
nix run .#update-packages            # every registered package
nix run .#update-packages -- alpha   # a registered subset
```

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
all selected packages and exits nonzero if any failed. It never creates a user
commit, bookmark or branch, publishes, or rewrites the caller's existing commits.
jj does record temporary workspace working-copy changes and workspace
add/forget operations in the repository operation log. Writes outside the
declared set fail that package. Promotion is file-level, not crash-atomic across
several files.
The runner does not sandbox or roll back external side effects of trusted updater
scripts.

The default write set for package `NAME` is `pkgs/NAME/`. A package can declare
an exception under `perSystem.packageUpdates.writeSets.NAME`, with explicit
repository-relative `paths` and a non-empty `reason`. Shared generated catalogs
or genuinely coupled definitions can justify a broader set; duplicated package
versions should normally be derived from the package definition instead.

## Refresh is not acceptance

The app edits package pins and reports status only. It does not write
`flake.lock`, update OCI references, run repository checks, or merge. A
candidate is accepted only after the requested updates complete **and** the
repository's declared acceptance checks pass; a hash-prefetch build is not an
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

Consumer migration, refresh schedules and PR creation, combined flake.lock
ownership, automerge and branch rules are separate adoption work. Renovate
remains responsible for OCI images and Actions references in the meantime.
