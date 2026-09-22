# Consumer contracts

Quick reference for repositories consuming nix-fleet (nix-homelab, dotfiles,
future hosts): what each published contract is, who owns what, and the
minimum wiring to onboard.

The recurring shape across every contract: **nix-fleet owns the mechanism and
its code; the consumer owns placement, inventory, policy data, and
secrets.** A consumer binds values through typed options or flake-level
declarations; nothing host-specific ever lives in nix-fleet.

| Contract                 | File                        | Surface                                                                  |
| ------------------------ | --------------------------- | ------------------------------------------------------------------------ |
| Machine identity + trust | [hosts.md](hosts.md)        | `flake.hosts.*`, known-hosts, ssh Host blocks                            |
| Builders + scheduling    | [builders.md](builders.md)  | `flake.builders.*`, `fleet.builderSets.*`, `flakeModules.fleet-builders` |
| CI builds + cache push   | [ci.md](ci.md)              | `packages.ci-builders*`, `.github/templates/build-push-cache.yml`        |
| Tooling (treefmt base)   | README, "Tooling contract"  | `flakeModules.tooling`                                                   |
| Secrets helpers          | README, "Consumer contract" | `lib.secrets`                                                            |
| Notification events      | README, aspect 6            | `services.notify.events.<unit>`                                          |

## Reading order for a new consumer

1. [hosts.md](hosts.md) — declare who your machines are (inventory only).
2. [builders.md](builders.md) — if any of them build for others, or you use
   one as a build client.
3. [ci.md](ci.md) — to let GitHub Actions build against the same builders.
