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

| Output                          | From                                                           |
| ------------------------------- | -------------------------------------------------------------- |
| `packages.<system>.cache-root`  | every other package (`flakeModules.cacheRoot`)                 |
| `checks.<system>.cache-root`    | the same root, so a pull request builds what the merge retains |
| `herculesCI`                    | `ci.effects.*`                                                 |
| `apps.<system>.update-packages` | `packageUpdates.*` (`flakeModules.packageUpdates`)             |

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
| `packageUpdates.packages = [ "<package>" ]`                | the package through nix-update and its `passthru.updateScript`                  |
| `packageUpdates.lockfiles.<n> = { ecosystem; directory; }` | `cargo update`, `bun update` or `npm update --package-lock-only` in `directory` |
| `packageUpdates.commands.<n> = { program; paths; }`        | anything else: `program` runs at the root and may change only `paths`           |

An update writing outside its write set is not adopted. A lockfile refresh builds
only if the package reads the lockfile (`cargoLock.lockFile`, crane,
`importNpmLock`, bun2nix); a vendored dependency hash needs a command that
recomputes it.

`ci.updates.autoMerge` requests auto-merge; where GitHub refuses it because the
pull request is already mergeable, the helper merges directly. That relies on the
ruleset `ci-enrol` creates: on a repository without required checks it would merge
an unchecked proposal.

## The operator

The instance descriptor is a flake with no inputs, so it adds nothing to a
repository's lock:

```nix
# <operator repository>/ci/flake.nix
{ outputs = _: { lib.instance = { system = "x86_64-linux"; cacheUrl = "…"; writeEndpoint = "…"; }; }; }
```

The repository list, `{ "<owner>/<name>" = { branch ? "main"; }; }`, drives three
consumers and is restated in none:

```nix
imports = [ inputs.nix-fleet.flakeModules.ciFederation ];
ciFederation = {
  repositories = import ./policy/ci-repositories.nix;
  appId = …;            # the nixbot App: the integration required checks come from
  installationId = …;   # null leaves installation to the operator
  nixbotUrl = "…";
};
# NixOS, on the cache host and the controller:
services.niks3-cache.nixbot = { issuer = "<nixbot URL>"; repositories = …; };
services.nixbot.github.repoAllowlist = builtins.attrNames repositories;
```

`services.niks3-cache.nixbot` renders two rules per repository: a push to
`refs/heads/<branch>` from `default.cache-retain` may move `<name>-<branch>-*`, and a
push of `refs/tags/*` from `default.cache-release` may move `<name>-release-*`.
Overlapping pin namespaces, a missing issuer or a hand-written
`oidc.providers.nixbot` fail evaluation.

`nix run .#ci-enrol` reconciles each listed repository: installs the App, allows
auto-merge, creates or updates the `nixbot` ruleset, and enables the nixbot project
through `nbo`. It reads before it writes; `--dry-run` prints the changes only. It
uses `GH_TOKEN` or `gh auth token`, and `NIXBOT_TOKEN` (an admin token from the
instance's `/settings`) for `nbo`.

## Enrolling a repository

1. Operator: add it to the list, deploy the cache host and the controller, run
   `nix run .#ci-enrol`.
2. Repository: adopt the interface (below) and push to the default branch.
3. Check: both `<name>-main-<system>` pins point at the current
   `packages.<system>.cache-root`.

### A new repository

```console
nix flake init -t github:Shrub24/nix-fleet#ci
```

Replace the `ci-instance` placeholder with the operator's descriptor and
`packages.default` with the project.

### An existing repository

Convert the flake to flake-parts, add the template's inputs and imports, and move
packages and checks under `perSystem`. Then:

- Build from lockfiles, not vendored hashes, and register each lockfile.
- Keep `checks` to what a pull request should pay for on every push; heavy suites
  (VM tests, every-architecture fixtures) belong behind a smaller `checks` set or in
  a separate attribute set nixbot does not build.
- Remove any `herculesCI` and any `nixbot.toml` that only restates the defaults.

To run the update now rather than on its schedule:

```console
NIXBOT_URL=<instance> NIXBOT_TOKEN=bnix_... \
  nix run github:Mic92/nixbot#nixbot-cli -- schedule run package-updates update -f
```

## Not yet observed

- A tag push's token carrying `event = push`; the release rule binds it.
- The admin-role ruleset bypass on a personal repository.
- `PUT /user/installations/{id}/repositories/{id}` on a personal account's
  installation; leave `installationId` null and install by hand if it is refused.
- Whether GitHub echoes a ruleset in exactly the shape `ci-enrol` sends; a
  difference makes every run report an update, which rewrites the same ruleset.

## Retiring the Actions path

The cache's GitHub Actions rules stay until a repository has had one observed
nixbot default-branch cycle; removing a rule revokes that repository's write.
