# Published package-update flakeModule: a typed per-system registry of locally
# owned package outputs plus one batch app over the shared runner
# (`pkgs/package-updates/`). Consumers select it
# (`imports = [ inputs.nix-fleet.flakeModules.packageUpdates ];`), register
# their own outputs, and get `nix run .#update-packages`.
#
# The module is bound in a `let` and used twice: flake.flakeModules entries are
# published only, never auto-applied to the defining flake. Its perSystem
# contributes the option and the app only — the regression checks below are
# contributors of *this* repository, so a consumer never inherits a fixture
# pinned to the producer's evaluated packages.
#
# Contract: docs/contracts/package-updates.md.
{ inputs, ... }:
let
  packageUpdatesModule = _: {
    perSystem =
      {
        config,
        lib,
        pkgs,
        system,
        ...
      }:
      let
        registry = pkgs.writeText "package-updates-registry.json" (
          builtins.toJSON {
            inherit system;
            registered = config.packageUpdates.packages;
            available = builtins.attrNames config.packages;
            writeSets = lib.mapAttrs (_: set: {
              inherit (set) paths reason;
            }) config.packageUpdates.writeSets;
            deferredInputs = config.packageUpdates.deferredInputs;
          }
        );

        runnerPackage = pkgs.callPackage ../../pkgs/package-updates { };

        # Registry-bound commands export the registry and pin nixpkgs for
        # nix-update's flake --use-update-script path, rather than the ambient
        # channel.
        registryEnv = ''
          export PACKAGE_UPDATES_REGISTRY=${registry}
          export NIX_PATH="nixpkgs=${pkgs.path}''${NIX_PATH:+:$NIX_PATH}"
        '';

        mkApp =
          name: runtimeInputs: text:
          pkgs.writeShellApplication {
            inherit name runtimeInputs text;
          };

        # Batch update of registered packages; the plain, scriptable command.
        updatePackages = mkApp "update-packages" [
          runnerPackage
          pkgs.nix
          pkgs.nix-update
          pkgs.jujutsu
          pkgs.git
        ] (registryEnv + ''exec update-packages "$@"'');

        # The one interactive command: a picker over flake inputs and package
        # updates, applying only what is accepted.
        interactiveUpdate = mkApp "update" [
          runnerPackage
          pkgs.nix
          pkgs.nix-update
          pkgs.jujutsu
          pkgs.git
          pkgs.fzf
          pkgs.gh
        ] (registryEnv + ''exec update "$@"'');
      in
      {
        options.packageUpdates.packages = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            `packages.<system>` attribute names this repository owns and
            updates. A package family with shared pins has exactly one
            registered owner; derived packages are not registered separately.
          '';
        };

        options.packageUpdates.writeSets = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                paths = lib.mkOption {
                  type = lib.types.nonEmptyListOf lib.types.str;
                  description = "Repository-relative paths the updater may change, in addition to its package directory.";
                };
                reason = lib.mkOption {
                  type = lib.types.str;
                  description = "Why the shared paths belong to this updater. Refused by name when empty.";
                };
              };
            }
          );
          default = { };
          description = ''
            Shared write-set exceptions per registered package, keyed by the
            package name. The default write set is the package's own
            definition directory; a shared path needs an explicit reason.
          '';
        };

        options.packageUpdates.deferredInputs = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = ''
            Flake inputs the lock refresh leaves at their locked revision,
            keyed by input name, each with a non-empty reason. An explicit
            `--input` request still moves a deferred input.
          '';
        };

        config.apps = {
          update-packages = {
            type = "app";
            program = lib.getExe updatePackages;
          };
          update = {
            type = "app";
            program = lib.getExe interactiveUpdate;
          };
        };
      };
  };

  # A harmless updater stand-in, so the consumer fixture's effective binding is
  # distinguishable from this repository's own pin.
  consumerStandIn = final: _prev: {
    nix-update = final.writeShellScriptBin "nix-update" ''
      printf '%s\n' "$NIX_PATH"
    '';
  };

  # A minimal consumer evaluated in-process. It overrides pkgs explicitly so
  # the check proves the app binds the *consumer's* evaluated updater, and it
  # exposes that updater so the check can compare against it.
  consumerFor =
    system:
    (inputs.flake-parts.lib.evalFlakeModule { inherit inputs; } {
      systems = [ system ];
      imports = [ packageUpdatesModule ];
      perSystem =
        { pkgs, ... }:
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [ consumerStandIn ];
          };
          packageUpdates.packages = [
            "alpha"
            "beta"
          ];
          packageUpdates.writeSets.alpha = {
            paths = [
              "pkgs/alpha"
              "lib/shared-fixture.nix"
            ];
            reason = "fixture: alpha shares one catalog file";
          };
          packageUpdates.deferredInputs.nixpkgs = "fixture: upstream pin held";
          packages = {
            alpha = pkgs.runCommand "alpha" { } "touch $out";
            beta = pkgs.runCommand "beta" { } "touch $out";
            consumer-nix-update = pkgs.nix-update;
          };
        };
    }).config.flake;
in
{
  flake.flakeModules.packageUpdates = packageUpdatesModule;

  imports = [ packageUpdatesModule ];

  perSystem =
    {
      lib,
      pkgs,
      system,
      ...
    }:
    let
      consumer = consumerFor system;
      runnerSrc = lib.cleanSource ../../pkgs/package-updates;
      runner = pkgs.callPackage ../../pkgs/package-updates { };
    in
    {
      # Offline runner contract: selection, ordering, refusals and fail-fast.
      # No test queries a moving upstream release.
      checks.package-updates-runner =
        pkgs.runCommand "package-updates-runner-check"
          {
            # jj and git let the transaction tests run here rather than skip:
            # staging needs both, and the harness pins the real git for jj.
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.git
              pkgs.gnugrep
              pkgs.jujutsu
              pkgs.python3
            ];
          }
          ''
            set -euo pipefail
            env -u PYTHONPATH ${lib.getExe runner} --help >/dev/null
            export PYTHONPATH=${runnerSrc}/src
            ${pkgs.python3.interpreter} -m unittest discover -s ${../../tests/package-updates} -v
            touch "$out"
          '';

      # The producer's decision step and credential boundary: a missing report or
      # nothing-to-propose fails the step, and the job that runs updaters holds
      # no credential.
      checks.package-updates-producer =
        pkgs.runCommand "package-updates-producer-check"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.jq
              (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
            ];
          }
          ''
            python ${../../tests/ci/producer_check.py} ${../../.github/workflows/package-updates-refresh.yml}
            touch "$out"
          '';

      # Minimal-consumer contract: the exported module gives a consumer its own
      # registry, and its app binds the consumer's evaluated updater — never
      # this repository's pin.
      checks.package-updates-consumer =
        pkgs.runCommand "package-updates-consumer-check"
          {
            nativeBuildInputs = [
              pkgs.coreutils
              pkgs.gnugrep
              pkgs.jq
              pkgs.jujutsu
            ];
            program = "${consumer.apps.${system}.update-packages.program}";
            consumerUpdater = "${consumer.packages.${system}.consumer-nix-update}";
            producerUpdater = "${pkgs.nix-update}";
          }
          ''
            set -euo pipefail

            grep -q "$consumerUpdater" "$program" || {
              echo "package-updates: consumer app does not bind the consumer's own nix-update"
              cat "$program"
              exit 1
            }
            if grep -q "$producerUpdater" "$program"; then
              echo "package-updates: producer-pinned nix-update leaked into the consumer app"
              cat "$program"
              exit 1
            fi

            registry=$(grep -oE 'PACKAGE_UPDATES_REGISTRY=[^ ]+' "$program" | head -n1 | cut -d= -f2)
            test -f "$registry" || {
              echo "package-updates: consumer registry $registry is missing"
              exit 1
            }

            test "$(jq -r '.registered | sort | join(",")' "$registry")" = "alpha,beta" || {
              echo "package-updates: consumer registry is not the consumer's own"
              jq . "$registry"
              exit 1
            }
            jq -e '.available | (index("alpha") != null) and (index("beta") != null)' "$registry" >/dev/null
            jq -e '.registered | index("bifrost") == null' "$registry" >/dev/null || {
              echo "package-updates: fleet dogfood registration leaked into the consumer"
              exit 1
            }
            # The shared write set and the deferral must reach the registry the
            # runner reads; each was once declared in the contract but dropped here.
            jq -e '.writeSets.alpha.paths | index("lib/shared-fixture.nix") != null' "$registry" >/dev/null || {
              echo "package-updates: declared write set did not reach the registry"
              jq . "$registry"
              exit 1
            }
            jq -e '.deferredInputs | has("nixpkgs")' "$registry" >/dev/null || {
              echo "package-updates: declared input deferral did not reach the registry"
              jq . "$registry"
              exit 1
            }

            NIX_PATH=extra=/consumer-fixture PATH=${pkgs.jujutsu}/bin:$PATH "$program" --help > consumer-run.log
            grep -Fq 'nixpkgs=${pkgs.path}' "$program" || {
              echo "package-updates: consumer NIX_PATH entries were lost"
              cat consumer-run.log
              exit 1
            }

            touch "$out"
          '';
    };
}
