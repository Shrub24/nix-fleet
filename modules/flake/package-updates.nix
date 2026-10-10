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
          }
        );

        app = pkgs.writeShellApplication {
          name = "update-packages";
          runtimeInputs = [
            (pkgs.callPackage ../../pkgs/package-updates { })
            pkgs.nix-update
            pkgs.nix
            # The batch reads each package's version and changelog from the
            # evaluated flake and refines "unchanged" by the working-copy delta,
            # so both tools are resolved on PATH rather than assumed ambient.
            pkgs.git
          ];
          text = ''
            export PACKAGE_UPDATES_REGISTRY=${registry}
            # nix-update's flake --use-update-script path imports <nixpkgs>;
            # pin it to the evaluated nixpkgs rather than the ambient channel.
            export NIX_PATH="nixpkgs=${pkgs.path}''${NIX_PATH:+:$NIX_PATH}"
            exec update-packages "$@"
          '';
        };
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

        config.apps.update-packages = {
          type = "app";
          program = lib.getExe app;
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
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.gnugrep
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

            NIX_PATH=extra=/consumer-fixture "$program" alpha > consumer-run.log
            grep -Fq 'nixpkgs=${pkgs.path}:extra=/consumer-fixture' consumer-run.log || {
              echo "package-updates: consumer NIX_PATH entries were lost"
              cat consumer-run.log
              exit 1
            }

            touch "$out"
          '';
    };
}
