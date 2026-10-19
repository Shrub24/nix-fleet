# Fleet systemd and activation patterns

These are shared fleet conventions, including cases where nix-fleet does not
ship an aspect. They guide fleet-owned modules and consumer configurations; they
do not enable a backend or imply that every host selects every policy. Published
module and option contracts remain in [consumer contracts](../contracts/README.md).

## Prefer the lifecycle owner

Use the native mechanism that owns the work rather than adding routine work to
system activation:

| Work                                                       | Preferred mechanism                                    | Boundary                                                                                                                                |
| ---------------------------------------------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------- |
| Create shared files/directories and set ownership          | `systemd.tmpfiles.settings`                            | Use for paths not wholly owned by one service.                                                                                          |
| Create a service's persistent, cache, or runtime directory | `StateDirectory`, `CacheDirectory`, `RuntimeDirectory` | Prefer the unit's directory directives when the path follows systemd's directory layout. They do not define backup or retention policy. |
| Prepare a service before launch                            | `ExecStartPre` or NixOS `preStart`                     | This runs in the service lifecycle, not once per deployment.                                                                            |
| Initialize or reconcile application state                  | A dedicated oneshot service                            | Specify what starts it, its ordering, failure behavior, and idempotence.                                                                |
| Run recurring work                                         | A systemd timer                                        | Define missed-run behavior where it matters; a timer is not a one-time switch hook.                                                     |
| React to filesystem state                                  | A systemd path unit                                    | Treat it as state observation, not a durable event queue.                                                                               |
| Reject an unsafe switch                                    | `system.preSwitchChecks` or a switch inhibitor         | Checks gate a deployment; they should not mutate post-switch state. Host-specific checks remain consumer-owned.                         |

Use imperative system activation only when the operation genuinely requires
deployment-time ordering and has no suitable native owner. Replacements are not
mechanical: service hooks run under service credentials and sandboxing, oneshots
need explicit triggers, and path units can coalesce changes.

For example, Bifrost's default `/var/lib/bifrost` state belongs to its service
and should use `StateDirectory`. A consumer-selected custom `dataDir` remains an
explicit path-management case. Neither choice implies a backup policy.

## Service readiness and network ownership

Consumers select the network backend and interface topology. nix-fleet does not
force NetworkManager, networkd, or a translation layer over native
`systemd.network` definitions. Avoid competing network managers on one host.

Do not use `network-online.target` as a proxy for arbitrary external
reachability. A service that needs a local service should express that service
dependency; a service that calls a remote service should tolerate unavailability
and retry. Use network-online ordering only where startup actually requires the
host's configured network to be brought up first. It does not prove that a
remote database, DNS resolver, or provider is reachable.

Use `restartIfChanged` and `stopIfChanged` for distinct decisions. Disabling
`restartIfChanged` can leave changed unit settings unapplied until a later
restart. Setting `stopIfChanged = false` changes a changed unit's switch from a
separate stop/start to a single restart; it is not a no-restart or
no-interruption guarantee. nix-fleet keeps `restartIfChanged = false` on both
Tailscale units: a switch may itself depend on the tailnet, so applying unit
changes must not restart its transport. Use a separately controlled restart to
apply those changes. The current pinned nixpkgs revision already supplies this
stop behavior for networkd and resolved, and reloads resolved configuration and
reloadable networkd `.network` files. Do not restate those upstream defaults in
a fleet aspect. Changes to networkd `.netdev` files can still restart
networkd and deserve host-level transition testing.

## Secrets and service ordering

Select nix-fleet's `sops-systemd-activation` aspect for regular SOPS secret
installation. Its assertion makes systemd activation the required fleet policy;
consumers still import sops-nix themselves. A consumer using legacy activation
must migrate before selecting this policy. `neededForUsers` secrets remain a
separate upstream case: sops-nix installs them in its early user-creation phase,
not through `sops-install-secrets.service`.

A service consuming a bound regular SOPS secret must order after
`sops-install-secrets.service` and want it. Do not branch service dependencies
on activation mode: under the fleet policy, the installer is part of the
contract. Services with no bound regular secret should not acquire a phantom
installer dependency.

Keep secret values out of the Nix store and process arguments. Prefer systemd
credentials when the application accepts file-based credentials; retain SOPS
templates or environment files where the application's interface requires
variables. Secret rotation must have an explicit service refresh contract.

## Service-owned policy

Fleet-owned service modules should use upstream NixOS options and systemd
settings directly where they express the behavior. Prefer service-owned state
and least privilege, but assess `DynamicUser`, sandboxing, writable paths, and
credentials per service: stable ownership, external data access, devices, and
backup/restore workflows can make a blanket setting incorrect.

A selectable aspect is appropriate when nix-fleet owns reusable behavior, not
merely because a convention is shared. Where it owns no mechanism, keep the
policy here and leave placement, topology, state location, and host-specific
exceptions to consumers.
