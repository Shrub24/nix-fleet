# Store cleanup (`nix-gc`)

`flake.modules.nixos.nix-gc` owns scheduled Nix store cleanup. Selection is
enablement; schedules and retention are options. It registers its own units'
failures with [notify](README.md) when that aspect is co-selected; success is not
reported, since a scheduled cleanup has no news worth sending.

## Collectors

`services.nix-gc.implementation` selects one:

| Value          | Behaviour                                                                                                      |
| -------------- | -------------------------------------------------------------------------------------------------------------- |
| `nh` (default) | `nh clean all` on a daily timer, ending in the stock collector. Retention is `extraArgs` (default `--keep 3`). |
| `fast-nix-gc`  | Threshold-driven CSR-graph collector, with root pruning and optimise (below).                                  |

`fast-nix-gc` reads the store database once instead of querying per path, and
serves the gc-roots socket while running, so concurrent builds register temp
roots without blocking on `gc.lock`. That removes the GC-versus-build race on
busy builders.

## The fast-nix-gc contract

Three units, each with one job:

| Unit                | Default | Job                                                                         |
| ------------------- | ------- | --------------------------------------------------------------------------- |
| `fast-nix-gc`       | hourly  | Free only the shortfall below `ensureFree`; do nothing above it.            |
| `nix-gc-roots`      | daily   | `nh clean all --no-gc`: prune stale generations and gcroots, never collect. |
| `fast-nix-optimise` | weekly  | Hardlink dedup of pre-existing paths, ordered after collection.             |

### Why threshold-driven

A calendar collector empties the store on a schedule whether or not space is
needed, so the next build rebuilds or re-substitutes what it just deleted.
`ensureFree = "15%"` (a percentage of the store filesystem, or a size such as
`"50G"`) makes the hourly timer cheap: above the threshold the run exits at once;
below it, only the shortfall is collected. `keepRecent = "1d"` additionally pins
paths registered within that period so a fresh build result is never the victim.
`ensureFree = null` restores unconditional collection on every run.

This is the fleet's answer to storage ballooning between runs. It is not a
guarantee: one build can fill a disk between two hourly runs.

### Why roots are pruned separately

Collection never removes what a live root pins. The usual cause of a growing
store is not missing collection but forgotten roots: `result` links, direnv
environments and old profile generations. `nix-gc-roots` runs nh with `--no-gc`
so pruning and collection are independent, and fast-nix-gc then sees the pruned
roots. The pruning unit is ordered `before` the collector.

Its retention is `roots.keep` (default 3 generations) and `roots.keepSince`
(default `7d`). nh's own `--keep-since` default is `0h`, which can remove live
`result` links, so the aspect always passes an explicit value; `--keep-one` keeps
one direnv root per project. nh owns generation retention on this path, so
`generationsOlderThan` defaults to null; setting both makes two rules that can
disagree.

### Optimise

`nix-baseline` already sets `auto-optimise-store`, which dedups each path as it
is written. The periodic pass only catches paths written before that was on, and
does nothing useful on a filesystem that dedups itself (btrfs, ZFS). It is a
safety net, on by default with `fast-nix-gc` and switchable with
`optimise.enable`. It takes only a shared `gc.lock`, so it does not block builds,
and the module warns if it is combined with `nix.optimise.automatic`.

## Options

`implementation`, `dates`, `ensureFree`, `keepRecent`, `generationsOlderThan`,
`noVacuum`, `fastNixGcPackage`, `roots.{prune,dates,keep,keepSince}`,
`optimise.{enable,dates}`. Options specific to `fast-nix-gc` warn or do nothing
under `nh`.

## Footguns

- **Do not rely on the daemon's `min-free`/`max-free` instead.** They run the
  stock collector inside the daemon and stall the build that triggered it.
  Setting `min-free` without `max-free` can collect every unreferenced path,
  because `max-free` defaults to unbounded. Thresholds depend on disk size, so
  the fleet baseline sets none; a small-disk host may set both as a last-resort
  backstop.
- **A full disk can defeat collection.** Deletion runs in batches whose write-ahead
  log grows roughly 10 KiB per dead path, and `nix-daemon` pins the log, so a
  collection started on a nearly full disk can fail. Keep the default chunk size.
  On never-idle builders set `noVacuum = true`.
- **`ensureFree` warns when it falls short.** Paths reachable from live roots or
  pinned by `keepRecent` are not freed; the shortfall is logged, and a failed
  unit reaches notify. The answer is pruning roots, not a lower threshold.
- **Pruning is destructive to unrooted work.** A project whose only root is an
  old `result` link loses it after `roots.keepSince`. Hosts that keep long-lived
  results should raise it or set `roots.prune = false`.
- **Only the pruned profiles are covered.** Roots outside the usual gcroot
  directories need `services.fast-nix-gc.gcRootsDirs`.

## Ownership

nix-fleet owns the mechanism, the defaults above and their rationale. Consumers
own the thresholds that depend on a machine (disk size, any `min-free` backstop),
retention that differs from the fleet's, and which hosts select the aspect.
Verify a host by evaluation: `checks.<system>.nix-gc-defaults` asserts the
defaults, that pruning never collects, and that each default can be switched off.
