# Tasks

## 1. nix-fleet

- [x] 1.1 Runner: command updates, inputs-only runs; lockfile adapters
- [x] 1.2 `flakeModules.ci` and `lib.ci`; retention generations and releases
- [x] 1.3 `services.niks3-cache`: release rules, `gc.olderThan`
- [x] 1.4 `ci-enrol`, packaged from the canonical instance facts (`lib.ci.instance`)
- [x] 1.5 `templates.ci`; contract doc
- [x] 1.7 Partition support: the partition's lock refreshes as `ci-inputs`; template partitioned
- [x] 1.6 Owner-wide cache rules; publish fails closed
- [x] 1.8 `ci-enrol [--withdraw] [REPO ...]`, defaulting to the current checkout; no enrolment list

## 2. Consumers (each its own change)

- [ ] 2.1 nix-homelab: `flakeModules.ci`, service derived from the instance facts, first
      `ci-enrol`; observe a main cycle, a tag release and a scheduled update
      (open at archive: main cycle and scheduled update observed; the tag release is not yet)
- [x] 2.2 nix-fleet adopts the interface (`modules/flake/ci-adoption.nix`); its legacy Actions stack is wiped in the same change
- [x] 2.3 Per repository after its first observed cycle: drop its Actions rules (homelab #99 removed the `github` provider and every Actions rule)
