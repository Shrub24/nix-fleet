# Federated CI

One nixbot instance is the CI for every enrolled repository. A repository
implements one interface, `flakeModules.ci`. The instance itself is a canonical fleet
fact, so no repository restates its coordinates and none depends on the operator's.

| Owner                 | Owns                                                                                                                                             |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| nix-fleet             | `flakeModules.ci`, `packages.ci-enrol`, `packages.flake-edit`, `services.niks3-cache.nixbot`, `lib.ci`, the instance facts, the nixbot input pin |
| the instance operator | the nixbot service and App, the cache, and which repositories are enrolled                                                                       |
| each repository       | its `checks`, packages, update registrations and input policy, its own `ci.*` values and effects                                                 |

## Policy

- **Which repositories.** Only enrolled ones: nixbot discovers every repository of
  the owner but builds a project only once `ci-enrol` enables it.
- **What builds.** A pull request builds when opened and on every push, drafts
  included; open it when the work should spend CI. Other branch pushes never build.
  A default-branch push whose tree matches a built pull request reuses that build.
  These are nixbot's defaults, so a repository needs no `nixbot.toml`; add one only
  to deviate. An invalid `nixbot.toml` silently falls back to the defaults.
- **Who builds.** Same-repository pull requests build automatically; fork pull
  requests wait for an admin's Approve CI, which covers that pull request's later
  pushes.
- **The verdict** is the repository's `checks`, reported as `nixbot/nix-eval` and
  `nixbot/nix-build`, required by the `nixbot` ruleset. Every built path is
  published to the cache.
- **Effects run on the default branch and tags only**, never for a pull request.
- **Merging is GitHub's.** Auto-merge is allowed on every enrolled repository and
  completes only through the required checks; admins bypass the ruleset for direct
  pushes.
- **Deployment is not CI.** No effect activates a host or holds a deploy credential.
- **Credentials are per effect.** Retention holds no secret and writes the cache
  with a workload-identity token; the update effect holds the forge token for its push
  and the instance's read-only `forge-read` token for lookups.
- **Retention is pins.** The cache collects an unpinned closure after
  `services.niks3-cache.gc.olderThan`; what outlives that is what a pin names.

## The interface

```nix
imports = [ inputs.nix-fleet.flakeModules.ci ];
```

`ci.instance` defaults to `lib.ci.instance`, which nix-fleet resolves from its
inventory: `cacheUrl` and `writeEndpoint` from the `niks3-write` service, `nixbotUrl`
from the `nixbot` service, `system` from `fleet.ci.controller`'s host, and `appId`
from `fleet.ci.githubAppId`. Moving the instance is an inventory edit here, reaching
every repository on its next nix-fleet bump.

A repository other flakes consume keeps `nix-fleet` out of its public lock by evaluating this in a flake-parts partition (`templates.ci` does):
`partitions.ci.extraInputsFlake = ./ci` names an inputs-only `ci/flake.nix` with its
own `ci/flake.lock`, and `partitionedAttrs` routes `checks` and `herculesCI` to it.
The partition re-evaluates the whole flake, so it sees every package; consumers
evaluate only the public outputs and never fetch the CI inputs. `cache-root` and the
update app then exist only inside the partition. A repository that already depends
on nix-fleet (nix-homelab, nix-dotfiles) imports the module directly.

| Output                         | From                                                           |
| ------------------------------ | -------------------------------------------------------------- |
| `packages.<system>.cache-root` | every other package                                            |
| `checks.<system>.cache-root`   | the same root, so a pull request builds what the merge retains |
| `herculesCI`                   | `ci.effects.*`                                                 |
| `apps.<system>.update-all`     | the update transaction, as the scheduled effect runs it        |
| `apps.<system>.update`         | a picker over the same updates, applying only what is accepted |

Every option, its type and default is in the generated
[option reference](../reference/ci-options.md).

### Effects

Every effect is an entry of `ci.effects`, the fleet's included, as a function of
`{ primaryRepo, pkgs, effects, perSystem, ... }` (`effects` is nixbot's library,
`perSystem` the instance system's per-system config). Returning null skips it for
that push. A repository adds its own beside them, or replaces or removes a fleet
entry with ordinary module priority:

```nix
ci.effects.onPush.docs = { primaryRepo, effects, pkgs, ... }:
  if primaryRepo.branch == "main" then effects.mkEffect { … } else null;
```

| Effect            | Runs                    | Does                                                                                                                                     |
| ----------------- | ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `cache-retain`    | each push to the branch | per system: push the root; if it moved, shift `<pin>-<k>` generations; move `<name>-<branch>-<system>`; fail unless the root substitutes |
| `cache-release`   | each pushed tag         | the same under `<name>-release-<tag>-<system>` (`/` in a tag becomes `-`)                                                                |
| `package-updates` | `ci.updates.when`       | `update-all --refresh-inputs`; if the tree changed, push the branch and open or update one pull request                                  |

Retention has no changed-only guard: rerunning it repairs a missed upload. A failure
on one system stops before the next. Generations shift only when the rolling pin
moves, so a rerun keeps history; nothing deletes pins, since deletion needs the
cache's admin scope.

### Updates

One run moves every flake input by its policy and runs every registered update, in
one transaction and one pull request, so CI builds the combination once. An
`aborted` batch or an unchanged tree publishes nothing.

#### Where each policy lives

Each update policy sits with the thing it governs, so nothing restates a name:

| Policy                         | Lives                                                                                      |
| ------------------------------ | ------------------------------------------------------------------------------------------ |
| the repository's CI            | one `modules/flake/ci.nix`: `ci.retention.*`, `ci.updates.when`, `.autoMerge`, lockfiles   |
| that a package is updated      | the feature owning it: `ci.updates.packages.<name> = { };` beside its other definitions    |
| how a package's version moves  | the derivation: `passthru.updateScript = nix-update-script { extraArgs = [ … ]; }`         |
| how a flake input's ref moves  | its flake-file declaration: `flake-file.inputs.<name>.update = { … };`, beside its URL     |
| anything else (generated pins) | `ci.updates.commands.<name> = { program; paths; }` in the feature owning the written paths |

The input policy is declared by `flakeModules.ci` on flake-file's input submodule;
`write-flake` renders only flake reference attributes, so it never reaches
`flake.nix`. A repository without flake-file has no declaration to carry it, so its
inputs follow the derived default.

#### Flake inputs

| `update.version` | Moves                                                                                              |
| ---------------- | -------------------------------------------------------------------------------------------------- |
| (unset)          | as its locked ref implies: a release tag is `stable`, a branch or no ref `branch`, a `rev` `fixed` |
| `stable`         | to the repository's latest release, else its highest release tag of the same prefix                |
| `unstable`       | as `stable`, admitting pre-releases                                                                |
| `branch`         | the lock to the ref's current head; the declaration is untouched                                   |
| `fixed`          | never on schedule; needs `update.reason`, or evaluation fails                                      |

Whether a ref is a tag is asked of the remote (`git ls-remote --tags`), not read
from its shape: `nixos-25.11` looks like a version and is a branch. Without a
release, a tag of another prefix never qualifies (`bolt-v1.2.1` never moves to
`pi-v2.0.0`), nor does a pre-release (`rc.13-v0.23.2`). `update.versionRegex` narrows
the candidates further: only tags it matches qualify, and its one capture group is
the version compared, as nix-update's `--version-regex`:

```nix
flake-file.inputs.noctalia = {
  url = "github:noctalia-dev/noctalia/v5.4.1";
  update.versionRegex = "v(5\\..*)"; # stay on the 5.x line
};
flake-file.inputs.nixpkgs.update = {
  version = "fixed";
  reason = "held until the toolchain bump is reviewed";
};
```

A tag move is chosen by flake-edit (`packages.<system>.flake-edit`, nixpkgs' with
nix-fleet's selection patches) on a scratch copy of `flake.nix`, then written back
to the one file in this repository that declares the input's URL; `write-flake`
regenerates `flake.nix`, which must then declare the new URL, and only that input is
relocked. A literal that is not exactly once in its file, a regeneration that drops
the move, or a release that does not lock is reported with its reason and leaves
that input as it was; the other inputs still move.

`--input <name>` moves exactly the named inputs by their derived policy, a `fixed`
one included; that is how a held input is moved once its upstream is fixed. An
unknown name, or a policy for an input the lock does not have, fails the input
refresh by name; the registered updates still run against the old lock.

#### Registered updates

| Registration                                           | Updates                                                                         |
| ------------------------------------------------------ | ------------------------------------------------------------------------------- |
| (automatic, inside a partition)                        | the partition's lock, as the `ci-inputs` update                                 |
| `ci.updates.packages.<name> = { };`                    | the package through nix-update, or its `passthru.updateScript`                  |
| `ci.updates.lockfiles.<n> = { ecosystem; directory; }` | `cargo update`, `bun update` or `npm update --package-lock-only` in `directory` |
| `ci.updates.commands.<n> = { program; paths; }`        | `program` runs at the root and may change only `paths`                          |

A package writes only `pkgs/<name>/` unless `paths` says otherwise, which needs a
`reason` (evaluation fails without one). A package family with shared pins has one
registered owner; derived outputs follow it. A name registered as both a package
and a command is refused. A lockfile refresh builds only if the package reads the
lockfile (`cargoLock.lockFile`, crane, `importNpmLock`, bun2nix); a vendored
dependency hash needs a command that recomputes it.

The batch runs the repository's own evaluated `nix-update` with
`--use-update-script`, with `NIX_PATH` pinned to the evaluated nixpkgs. Each update
runs in a disposable jj workspace on the current tree and is adopted before the
next starts; one that fails or writes outside its paths is discarded and reported,
and the rest still run. Update scripts are trusted repository code: they must not
commit, publish or deploy, and nothing rolls back their side effects elsewhere.

#### Outcome and report

| Exit | `outcome`  | Meaning                                                                     |
| ---- | ---------- | --------------------------------------------------------------------------- |
| 0    | `complete` | everything selected ran without failure                                     |
| 1    | `partial`  | proposable, carrying failures: an update, an input, or the lock refresh     |
| 2    | `aborted`  | nothing proposable: the registry was unusable, or adoption stopped part-way |

The effect reads `outcome` from the report file, which exists only if the run
reached its own end. The pull request body lists moved inputs (old → new, compare
link, and release link for a tag), updated packages with their changelog, and each
input or update that did not move, with its reason. Refresh is not acceptance: the
pull request merges only through the repository's checks.

`ci.updates.autoMerge` requests auto-merge. Where GitHub refuses it, as it does on a
repository without required checks, the effect fails and the pull request stays
open; it is never merged directly.

#### Tokens

The push uses the effect's forge token, which the batch never sees. The batch runs
with the instance's `forge-read` secret, a read-only GitHub token, as `GITHUB_TOKEN`
(flake-edit, nix-update and update scripts read it) and as a Nix `access-tokens`
entry; it only lifts the anonymous API rate limit, so every updater may see it. The
operator binds it once for the owner on the nixbot host:

```nix
services.nixbot.effects.perRepoSecretFiles."github:<owner>/*" = <JSON file>;
# { "forge-read": { "data": { "token": "<read-only token>" } } }
```

#### Locally

```console
nix run .#update                 # pick flake inputs and package updates; applies what is accepted
nix run .#update-all             # every registered update, or the named ones
nix run .#update-all -- --check  # newer releases per package's passthru.checkUpdate; edits nothing
```

#### What stays with Renovate

Container image digests and GitHub Actions pins: neither rebuilds anything
significant, and neither is a flake input or a package.

## The operator

The instance's facts live in nix-fleet's inventory, so the operator repository
derives its service from them and asserts its own routes agree. Discovery and cache
trust are by owner, so nothing about a repository's enrolment is instance
configuration:

```nix
# NixOS, on the cache host and the controller:
services.niks3-cache.nixbot = {
  issuer = "<nixbot URL>";
  owners = [ "<owner>" ];
  repositories = …; # only repositories outside `owners` or retaining another branch
};
services.nixbot.github.userAllowlist = [ "<owner>" ];
```

The App is installed on every repository of the owner, so nixbot discovers all of
them; a discovered project stays disabled until enrolled.

`services.niks3-cache.nixbot.owners` renders two rules per owner: a push to
`refs/heads/main` from `default.cache-retain` may move `*-main-*` pins, and a push
of `refs/tags/*` from `default.cache-release` may move `*-release-*`. niks3 pin
patterns cannot name the token's repository, so any of the owner's repositories
can move another's pins. That reaches retention only: paths are content-addressed
and signed by the cache, and nothing resolves a pin by name. Each entry of
`repositories` renders the same pair scoped to `<name>-<branch>-*` and
`<name>-release-*`. Overlapping per-repository namespaces, a missing issuer or a
hand-written `oidc.providers.nixbot` fail evaluation.

Enrolment is the state nixbot and GitHub already hold, changed by one command, so
enrolling a repository needs no deploy. `packages.<system>.ci-enrol` carries the
instance facts already; an operator installs it on a workstation (nix-dotfiles)
beside `nbo`:

```console
ci-enrol [--dry-run] [--withdraw] [OWNER/REPO ...]
```

| Command      | nixbot   | GitHub                                                                          |
| ------------ | -------- | ------------------------------------------------------------------------------- |
| `ci-enrol`   | enabled  | auto-merge allowed; `nixbot` ruleset requiring the checks on the default branch |
| `--withdraw` | disabled | `nixbot` ruleset removed first                                                  |

With no repository it acts on the current checkout's GitHub repository. It reads
before it writes, so a rerun changes nothing; `--dry-run` prints the changes only.
It needs `GH_TOKEN` (or `gh auth token`) with admin on the repository and
`NIXBOT_TOKEN`, an instance admin token from `/settings`. Disable through
`--withdraw`, not the UI toggle: the toggle leaves the ruleset requiring checks
nothing will post.

## Enrolling a repository

1. Repository: adopt the interface (below) and push it.
2. Operator: `ci-enrol <owner>/<name>`, or `ci-enrol` from its checkout. Enrolling
   before adopting makes the ruleset require checks the repository does not yet
   produce.
3. Check: after the next default-branch push, both `<name>-main-<system>` pins
   point at the current `packages.<system>.cache-root`.

`ci-enrol --withdraw <owner>/<name>` withdraws it.

### A new repository

```console
nix flake init -t github:Shrub24/nix-fleet#ci
```

Replace `packages.default` with the project and lock both flakes
(`nix flake lock --flake ./ci`, then `nix flake lock`).

### An existing repository

Convert the flake to flake-parts, add the template's `ci/` flake, partition and
imports, and move packages and checks under `perSystem`. Then:

- Build from lockfiles, not vendored hashes, and register each lockfile.
- Keep `checks` to what a pull request should pay for on every push; heavy suites
  (VM tests, every-architecture fixtures) belong behind a smaller `checks` set or in
  a separate attribute set nixbot does not build.
- Remove any `herculesCI` and any `nixbot.toml` that only restates the defaults.
- Don't partition `apps`: a partitioned attribute is replaced wholesale, and running
  a public app would then fetch the CI inputs.

## The operator's client

`nbo` is nixbot's CLI; nothing in CI runs it. Install it from a flake that follows
nix-fleet's pin, so it matches the server the instance runs:

```nix
inputs.nixbot.follows = "nix-fleet/nixbot";
home.packages = [ inputs.nixbot.packages.${pkgs.system}.nixbot-cli ];
home.sessionVariables.NIXBOT_URL = "<instance>";
```

The token stays out of Nix: export `NIXBOT_TOKEN`, an admin token from the
instance's `/settings`, when running it. To run a repository's update now rather
than on its schedule, from its checkout:

```console
nbo schedule run package-updates update -f
```

## Not yet observed

- A scheduled run moving a tag-pinned input through its declaring module.
- A tag push's token carrying `event = push`; the release rule binds it.
- The admin-role ruleset bypass on a personal repository.
- Whether GitHub echoes a ruleset in exactly the shape `ci-enrol` sends beyond
  `do_not_enforce_on_create`; a difference makes every run rewrite the same ruleset.

## No Actions path

nix-fleet ships no GitHub Actions workflows. A cache rule an operator still holds for
Actions tokens serves only workflows outside this repository, and is the operator's
to remove.
