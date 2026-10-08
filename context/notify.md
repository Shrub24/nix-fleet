# Notifications

## A registration and a drop-in follow the unit they describe

**Id:** 45ffb31d-672b-40bb-bc30-c59da49d1752
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** consumer failure migrating to `0e02a75c` (`events.fast-nix-optimise is registered but has no systemd service implementation`) and `checks.<system>.nix-gc-defaults`, 2026-10-08

An aspect registers a failure event, and attaches any unit configuration of its own, only while the unit exists — both following the same `enable` flag that decides whether the unit is defined. A conditional drop-in is gated at the unit collection (`systemd.services = lib.mkIf …`) rather than on the drop-in itself.

**Reason:** the notify contract fails closed on a registration whose unit has no service implementation, so a registration that outlives its unit turns a supported override into an evaluation failure. A consumer that disabled `fast-nix-optimise` on a deduplicating filesystem hit exactly that, and the same held for the other two units. The ordering drop-in needed the same treatment for a different reason: `systemd.services.nh-clean.before = lib.mkIf …` still declares the unit, rendering `nh-clean` with no `ExecStart` — the failure class the unconditional `tailscaled-autoconnect` had. Gating the collection level removes the declaration itself.

**Rejected alternative:** relax the notify rule to tolerate a registration without a unit. That rule is what catches an aspect registering a unit it does not own, which is how the nix-gc registration once named `nix-gc` — NixOS's own always-defined but inert unit — while the work ran in `nh-clean`, leaving every real failure unreported.

**Rejected alternative:** register the units unconditionally and treat the enable flags as documentation. The flags are ordinary upstream options a consumer sets directly, so the registration would be correct only for hosts that never disable anything.
