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

## The ntfy transport publishes ntfy's JSON format on the root URL

**Id:** f92bd3c3-5d96-4e40-a1db-85476baf7463
**Type:** decision
**Type:** constraint
**Status:** active
**Evidence:** confirmed
**Source:** ntfy's `docs/publish.md` ("Publish as JSON") and `server/server.go` — `transformBodyJSON` is registered for `POST /` only, and the topic route hands the raw body to `handlePublishBody`, which makes it the message text — plus the maintainer's attribute rulings, 2026-11-05
**Revisit when:** the transport moves to ntfy's header API, or ntfy renames or retypes a JSON publish field

Delivery to ntfy is one JSON POST to `{server_url}/` with `topic`, `title`, `message`, `priority` and `tags` — the server's own field names — and the topic travels in the body, not the path. Severity maps onto the priority scale at 1, 3 and 5; `tags` carries the severity and then context the notification cannot show (a unit event adds its host, since one topic carries every host's events, and webhooks pass their own); the ntfy title is the event's own, without the `[topic]` prefix Telegram keeps; a message past ntfy's 4 KiB limit is trimmed around a marker while keeping its tail. `checks.notify-alertmanager` pins the payload shape once, because every one of these drifts silently: the HTTP request succeeds either way.

**Reason:** ntfy parses JSON on the root URL only. The topic path is the header/body API, so a JSON body sent there is published verbatim as the message text — the raw object shows up in the client while title, priority and tags are dropped, and the request still returns 200. That is how this shipped and how it was noticed, months before it was traced to the endpoint rather than to the field names. The attribute choices follow from what each transport can show: Telegram's topic is a numeric thread id the reader never sees, so the title carries the use case; ntfy's topic is the subscription the notification arrives on, so repeating it in the title is noise.

**Rejected alternative:** keep the per-topic POST and correct only the field names. The endpoint is the defect: `body` is ignored (the message falls back to `triggered`) and `Tags` as a string fails ntfy's decode outright, but fixing them in place would still deliver the JSON blob as text.

**Rejected alternative:** priority 2/3/5 or 3/4/5. Low and min are both silent and differ only in whether the notification is folded under "Other notifications"; default sounds on every informational success, which makes an unreachable cache and a completed deploy equally loud.

**Rejected alternative:** tag the service or unit name, or the severity alone. The unit is already in the title (and a title override is the caller's choice), and severity alone repeats what the priority already encodes in sound and placement.

**Rejected alternative:** leave an over-long message to ntfy, or raise the server's `message-size-limit`. Past 4 KiB ntfy delivers a file attachment, so a 50-line journal arrives as something to download; raising the limit makes every notification a long one, and the limit is consumer policy rather than the transport's.
