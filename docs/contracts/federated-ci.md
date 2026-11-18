# Federated CI

One nixbot instance is the CI for every enrolled repository. A repository
implements one interface, `flakeModules.ci`; the instance's operator keeps one
repository list, reconciled everywhere from Nix.

| Owner                 | Owns                                                                                                          |
| --------------------- | ------------------------------------------------------------------------------------------------------------- |
| nix-fleet             | `flakeModules.ci`, `flakeModules.ciFederation`, `services.niks3-cache.nixbot`, `lib.ci`, the nixbot input pin |
| the instance operator | the nixbot service and App, the cache, the instance descriptor, the repository list                           |
| each repository       | its `checks`, packages and update registrations, its own `ci.*` values and effects                            |

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
  with a workload-identity token; the update effect holds only the forge token.
- **Retention is pins.** The cache collects an unpinned closure after
  `services.niks3-cache.gc.olderThan`; what outlives that is what a pin names.

## The interface

```nix
imports = [ inputs.nix-fleet.flakeModules.ci ];
ci.instance = inputs.ci-instance.lib.instance;
```

A repository other flakes consume keeps `nix-fleet` and the descriptor out of its
public lock by evaluating this in a flake-parts partition (`templates.ci` does):
`partitions.ci.extraInputsFlake = ./ci` names an inputs-only `ci/flake.nix` with its
own `ci/flake.lock`, and `partitionedAttrs` routes `checks` and `herculesCI` to it.
The partition re-evaluates the whole flake, so it sees every package; consumers
evaluate only the public outputs and never fetch the CI inputs. `cache-root` and the
update app then exist only inside the partition. A repository that already depends
on nix-fleet (nix-homelab, nix-dotfiles) imports the module directly.

| Output                          | From                                                                                   |
| ------------------------------- | -------------------------------------------------------------------------------------- |
| `packages.<system>.cache-root`  | every other package (`flakeModules.cacheRoot`)                                         |
| `checks.<system>.cache-root`    | the same root, so a pull request builds what the merge retains                         |
| `herculesCI`                    | `ci.effects.*`                                                                         |
| `apps.<system>.update-packages` | `packageUpdates.*` (`flakeModules.packageUpdates`); the update effect runs it directly |

| Option                                           | Default                                  | Meaning                                                                      |
| ------------------------------------------------ | ---------------------------------------- | ---------------------------------------------------------------------------- |
| `ci.instance`                                    | required                                 | `{ system; cacheUrl; writeEndpoint; }`, bound from the operator's descriptor |
| `ci.nixPackage`, `ci.niks3Package`               | nix-fleet's, for `instance.system`       | the clients effects call                                                     |
| `ci.retention.enable`                            | `true`                                   | retain the branch's roots                                                    |
| `ci.retention.branch`                            | `"main"`                                 | must match the repository's entry in the operator's list                     |
| `ci.retention.systems`                           | the flake's `systems`                    | roots pushed and pinned                                                      |
| `ci.retention.generations`                       | `0`                                      | earlier roots kept as `<pin>-1` … `<pin>-<n>`                                |
| `ci.retention.releases`                          | `true`                                   | pin each pushed tag's roots                                                  |
| `ci.updates.enable`                              | `true`                                   | the scheduled update transaction                                             |
| `ci.updates.when`                                | Monday 04:43                             | nixbot `onSchedule` `when`                                                   |
| `ci.updates.branch`, `.title`, `.autoMerge`      | `automation/package-updates`, …, `false` | the proposal                                                                 |
| `ci.effects.onPush.<name>`, `.onSchedule.<name>` | the fleet's entries                      | effects, each a function returning an effect (or a schedule job) or null     |

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
| `package-updates` | `ci.updates.when`       | `update-packages --refresh-inputs`; if the tree changed, push the branch and open or update one pull request                             |

Retention has no changed-only guard: rerunning it repairs a missed upload. A failure
on one system stops before the next. Generations shift only when the rolling pin
moves, so a rerun keeps history; nothing deletes pins, since deletion needs the
cache's admin scope.

### Updates

One run refreshes `flake.lock` and every registered update, in one transaction and
one pull request, so CI builds the combination once. An `aborted` batch or an
unchanged tree publishes nothing.

| Registration                                               | Updates                                                                         |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------- |
| none                                                       | `flake.lock` only                                                               |
| (automatic, inside a partition)                            | the partition's lock, as the `ci-inputs` update                                 |
| `packageUpdates.packages = [ "<package>" ]`                | the package through nix-update and its `passthru.updateScript`                  |
| `packageUpdates.lockfiles.<n> = { ecosystem; directory; }` | `cargo update`, `bun update` or `npm update --package-lock-only` in `directory` |
| `packageUpdates.commands.<n> = { program; paths; }`        | anything else: `program` runs at the root and may change only `paths`           |

An update writing outside its write set is not adopted. A lockfile refresh builds
only if the package reads the lockfile (`cargoLock.lockFile`, crane,
`importNpmLock`, bun2nix); a vendored dependency hash needs a command that
recomputes it.

`ci.updates.autoMerge` requests auto-merge. Where GitHub refuses it, as it does on a
repository without required checks, the effect fails and the pull request stays
open; it is never merged directly.

## The operator

The instance descriptor is a flake with no inputs, so it adds nothing to a
repository's lock:

```nix
# <operator repository>/ci/flake.nix
{ outputs = _: { lib.instance = { system = "x86_64-linux"; cacheUrl = "…"; writeEndpoint = "…"; }; }; }
```

Discovery and cache trust are by owner, so nothing about a repository's enrolment
is instance configuration:

```nix
imports = [ inputs.nix-fleet.flakeModules.ciFederation ];
ciFederation = {
  appId = …;      # the nixbot App: the integration required checks come from
  nixbotUrl = "…";
};
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

Enrolment is the state nixbot and GitHub already hold, changed by one command from
the operator repository, so enrolling a repository needs no deploy:

```console
nix run .#ci-enrol -- [--dry-run] [--withdraw] [OWNER/REPO ...]
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
2. Operator: `nix run <operator repository>#ci-enrol -- <owner>/<name>`. Enrolling
   before adopting makes the ruleset require checks the repository does not yet
   produce.
3. Check: after the next default-branch push, both `<name>-main-<system>` pins
   point at the current `packages.<system>.cache-root`.

`ci-enrol --withdraw <owner>/<name>` withdraws it.

### A new repository

```console
nix flake init -t github:Shrub24/nix-fleet#ci
```

Replace the `ci-instance` placeholder in `ci/flake.nix` with the operator's
descriptor, `packages.default` with the project, and lock both flakes
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

- A tag push's token carrying `event = push`; the release rule binds it.
- The admin-role ruleset bypass on a personal repository.
- Whether GitHub echoes a ruleset in exactly the shape `ci-enrol` sends beyond
  `do_not_enforce_on_create`; a difference makes every run rewrite the same ruleset.

## No Actions path

nix-fleet ships no GitHub Actions workflows. A cache rule an operator still holds for
Actions tokens serves only workflows outside this repository, and is the operator's
to remove.
