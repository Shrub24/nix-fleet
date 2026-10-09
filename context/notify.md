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

## The registration contract is shared vocabulary, not a capability

**Id:** 75571edf-3e47-470a-bfe0-1919b1a0db0a
**Type:** decision
**Status:** active
**Evidence:** confirmed
**Source:** user directive, 2026-10-08

`lib/notify-contract.nix` holds `services.notify.events` and nothing else — no config, no assertion, no unit. Every aspect that registers an event imports it directly, `notify.nix` imports the same file and is the only realizer, and the file sits in `lib/` beside `lib/telemetry-contract.nix` rather than under the capability it is consumed by.

**Reason:** a producer has to be able to write a registration on a host that has not selected notify, and the import is the declaration — so the namespace exists wherever a registration is written and stays inert without the capability. A `_`-prefixed path nested under `notify/` implies private implementation data, which a file with fifteen importers is not. The capability-side checks stay capability-side because they need the rendered service set: that is why a typo'd unit fails by name where notify is composed.

**Rejected alternative:** publish a selectable `notify-contract` aspect to mirror `nixos.telemetry`. Telemetry splits its contract from its realizations because a lane is the selectable unit; notify has one implementation and no lanes, so a contract aspect that selects no realization only reproduces the footgun a consumer hit when the bare `telemetry` aspect left `services.vmagent.enable` false.

**Rejected alternative:** drop the fragment import so a missing notify fails as an unknown option. That makes every producer a hard dependency of notify, which needs a transport, a topic and sometimes a chat ID and fails closed on each — and dependencies belong to the composition that selects both, not to a producer's registration.

**Rejected alternative:** a realized marker or an orphan guard. The fragment cannot observe which modules were imported, so such a guard would infer capability from merged configuration — the inference the telemetry contract removed.
