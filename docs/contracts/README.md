# Consumer contracts

Quick reference for repositories consuming nix-fleet (nix-homelab, dotfiles,
future hosts): what each published contract is, who owns what, and the
minimum wiring to onboard.

The recurring shape: **nix-fleet is the authority for canonical fleet facts
(identity, participation, cross-fleet sets) and the mechanism code; consumers
derive from those facts and own everything downstream** — compositions,
placement, per-relationship policy, local additions, secrets. Fact tiers:

1. **Canonical fact** — declared in nix-fleet; consumers derive, never restate.
2. **Shared default** — mechanism defaults; overridable normally.
3. **Consumer-local policy** — belongs downstream, additive only.

| Contract                 | File                        | Surface                                                                    |
| ------------------------ | --------------------------- | -------------------------------------------------------------------------- |
| Machine identity + trust | [hosts.md](hosts.md)        | `flake.hosts.*`, known-hosts, ssh Host blocks                              |
| Builders + scheduling    | [builders.md](builders.md)  | `fleet.builders.*`, `fleet.builderSets.*`, `config.fleet.realization`      |
| CI builds + cache push   | [ci.md](ci.md)              | `packages.ci` / `packages.<set>`, `.github/templates/build-push-cache.yml` |
| Tooling (treefmt base)   | README, "Tooling contract"  | `flakeModules.tooling`                                                     |
| Secrets helpers          | README, "Consumer contract" | `lib.secrets`                                                              |
| Notification events      | README, aspect 6            | `services.notify.events.<unit>`                                            |

## Reading order for a new consumer

1. [hosts.md](hosts.md) — declare who your machines are (inventory only).
2. [builders.md](builders.md) — if any of them build for others, or you use
   one as a build client.
3. [ci.md](ci.md) — to let GitHub Actions build against the same builders.
