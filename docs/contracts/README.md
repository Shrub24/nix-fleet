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

| Contract                 | File                               | Surface                                                                         |
| ------------------------ | ---------------------------------- | ------------------------------------------------------------------------------- |
| Machine identity + trust | [hosts.md](hosts.md)               | `fleet.hosts.*` (canonical), known-hosts, ssh Host blocks                       |
| Builders + scheduling    | [builders.md](builders.md)         | `fleet.builders.*`, `fleet.builderSets.*`, `config.fleet.realization`           |
| CI builds + cache push   | [ci.md](ci.md)                     | `packages.ci` / `packages.<set>`, `.github/templates/build-push-cache.yml`      |
| Tooling (treefmt base)   | README, "Tooling contract"         | `flakeModules.tooling`                                                          |
| Secrets helpers          | README, "Tooling contract"         | `lib.secrets`                                                                   |
| Notification events      | README, aspect 6                   | `services.notify.events.<unit>` (fragment; realization when notify co-selected) |
| Tailscale baseline       | README, aspect 1                   | `secretFiles.auth` two-step bootstrap                                           |
| Beszel agent enrollment  | README, aspect 2                   | `secretFiles.{common,host}` gate; KEY-only (no TOKEN)                           |
| niks3 cache / publisher  | README, aspects 4–5                | `services.niks3-cache.*`, `secretFiles.apiToken`                                |
| Flake input declarations | [flake-inputs.md](flake-inputs.md) | generated `flake.nix` — composition policy, no fleet surface                    |

Aspect-level contracts (the lower four) are documented in README's aspect
list; they follow the same tier rule — mechanism here, placement/policy/
secrets downstream.

All fleet surfaces hang off one import: `flakeModules.fleet` (schema +
canonical inventory + validation + CI bundles + the realization at
`config.fleet.realization`). There is deliberately no separate
registry/realization import pair — see builders.md for why.

## Reading order for a new consumer

1. [hosts.md](hosts.md) — the canonical identity you derive from, and the
   trust you get for free.
2. [builders.md](builders.md) — builder participation, sets, and the
   evaluation-local realization (`config.fleet.realization`).
3. [ci.md](ci.md) — to let GitHub Actions build against the same builders.
