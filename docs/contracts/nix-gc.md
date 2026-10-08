# Store cleanup (`nix-gc`)

`flake.modules.nixos.nix-gc` owns scheduled Nix store cleanup. Selection is
enablement: importing the aspect is the whole configuration, and every value it
sets is a plain default on the upstream option, so a host overrides one directly
when its storage differs. The aspect registers its own units' failures with
[notify](README.md) when that aspect is co-selected.

## The fleet's cleanup

Three units, each with one job:

| Unit                | Timer  | Job                                                                  |
| ------------------- | ------ | -------------------------------------------------------------------- |
| `nh-clean`          | daily  | `nh clean all --keep 3 --keep-since 7d --keep-one --no-gc`           |
| `fast-nix-gc`       | hourly | Collect everything unreferenced that is older than `keepRecent` (1d) |
| `fast-nix-optimise` | weekly | Hardlink dedup of paths written before `auto-optimise-store`         |

Pruning is ordered `before` the collector, so when both timers fire the
collector sees the pruned roots.

Turning a unit off is the override this contract invites, and it leaves no
trace: the failure registration and the `before` ordering follow the same
`enable` flag that decides whether the unit exists. Without that,
disabling one unit would either leave notify rejecting a registration for a
unit that is not there, or declare `nh-clean` on its own — a unit with no
`ExecStart`.

The collector is installed on every host that selects the aspect: the tool that
runs hourly is the same one an operator reaches for by hand when a store needs
attention.

## Why collection is unconditional

A free-space threshold sounds frugal and is not. Deferring collection until the
store filesystem is 15% free means the store grows to fill the disk before
anything is deleted, and the run that finally triggers has the most work to do
at the worst moment. The fleet instead collects every hour and deletes
everything unreferenced, so the store hovers near its real working set instead
of near the disk's capacity.

`keepRecent = "1d"` is the counterweight: paths registered in the last day are
held, so a build's dependencies are never collected while it is still the
newest thing on the machine. Raising it trades disk for rebuild avoidance;
setting it to null makes each run the strictest possible statement about what
is still needed.

This is not a guarantee that a disk cannot fill — one build can do that between
two hourly runs. It removes the slow leak, not the spike.

## Why the collector is `fast-nix-gc`

Two properties, both about not fighting builds:

- It reads the store database once instead of querying per path, which is what
  makes an hourly schedule cheap enough to be unconditional.
- It serves the gc-roots socket while running, so a concurrent build registers
  its temporary roots instead of blocking on `gc.lock`.

## Why roots are pruned separately

Collection never removes what a live root pins, and the usual cause of a growing
store is not missing collection but forgotten roots: `result` links, direnv
environments and old profile generations. `nh-clean` therefore runs with
`--no-gc`: it deletes old generations and stale gcroots and never collects, and
`fast-nix-gc` does the collecting.

Retention belongs to nh on this path — `--keep 3 --keep-since 7d --keep-one` —
so `services.fast-nix-gc.deleteOlderThan` stays at its null default. Setting
both would put two generation-retention rules in the same configuration.
`--keep-since 7d` is explicit because nh's own default is `0h`, which can remove
a live `result` link.

## Why optimise is still scheduled

`nix-baseline` sets `auto-optimise-store`, which dedups each path as it is
written, so the periodic pass only catches paths written before that was on. It
is a safety net rather than a space strategy, and it does nothing useful on a
filesystem that dedups itself (btrfs, ZFS). It takes only a shared `gc.lock`, so
it does not block builds.

## Overriding

There is no `services.nix-gc` namespace. The fleet's values are defaults on the
options that own them, so a host states its difference and nothing else:

```nix
# A host whose data filesystem already dedups.
services.fast-nix-optimise.enable = false;

# A host that keeps long-lived results and can afford the disk.
programs.nh.clean.extraArgs = "--keep 10 --keep-since 30d --keep-one --no-gc";

# A host that wants a free-space threshold after all.
services.fast-nix-gc.ensureFree = "50G";
services.fast-nix-gc.dates = "daily";
```

## Footguns

- **Do not reach for the daemon's `min-free`/`max-free` instead.** They run the
  stock collector inside the daemon and stall the build that triggered it.
  Setting `min-free` without `max-free` can collect every unreferenced path,
  because `max-free` defaults to unbounded. Thresholds depend on disk size, so
  the fleet baseline sets none; a small-disk host may set both as a last-resort
  backstop.
- **A full disk can defeat collection.** Deletion runs in batches whose
  write-ahead log grows roughly 10 KiB per dead path, and `nix-daemon` pins the
  log, so a collection started on a nearly full disk can fail. Keep the default
  chunk size; on never-idle builders set `services.fast-nix-gc.noVacuum = true`.
- **Pruning is destructive to unrooted work.** A project whose only root is an
  old `result` link loses it after seven days. Hosts that keep long-lived
  results should extend `--keep-since`.
- **Only the usual gcroot directories are covered.** Roots elsewhere need
  `services.fast-nix-gc.gcRootsDirs`.

## Ownership

nix-fleet owns the mechanism, the schedule above and its rationale. Consumers
own what depends on a machine: retention for long-lived results, optimise on a
filesystem that dedups itself, any `min-free` backstop, and which hosts select
the aspect.

Verify a host by evaluation: `checks.<system>.nix-gc-defaults` asserts the
defaults — unconditional hourly collection, separate pruning that never
collects, weekly optimise, one failure registration per unit — and that a host
override on the upstream option takes effect. It also asserts the off case:
with every unit disabled there is no registration left and no rendered unit,
and notify raises no "registered but has no systemd service implementation".
