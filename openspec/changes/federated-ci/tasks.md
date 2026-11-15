# Tasks

## 1. nix-fleet

- [x] 1.1 Runner: command updates, inputs-only runs; lockfile adapters
- [x] 1.2 `flakeModules.ci` and `lib.ci`; retention generations and releases
- [x] 1.3 `services.niks3-cache`: release rules, `gc.olderThan`
- [x] 1.4 `flakeModules.ciFederation` and `ci-enrol`
- [x] 1.5 `templates.ci`; contract doc
- [x] 1.6 Owner-wide cache rules; `ci-enrol` enables and withdraws by the list; publish fails closed

## 2. Consumers (each its own change)

- [ ] 2.1 nix-homelab: descriptor subflake, `flakeModules.ci`, `ciFederation`, first
      `ci-enrol`; observe a main cycle, a tag release and a scheduled update
- [ ] 2.2 nix-fleet, nix-dotfiles, then application repositories adopt the interface
- [ ] 2.3 Per repository after its first observed cycle: drop its Actions rules
