# This repository's checks of the update transaction: the runner's offline contract,
# and a minimal consumer of flakeModules.ci proving its registry is the consumer's own.
{ config, inputs, ... }:
let
  module = config.flake.flakeModules.ci;

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
      imports = [ module ];
      ci.updates.packages = {
        alpha = {
          paths = [
            "pkgs/alpha"
            "lib/shared-fixture.nix"
          ];
          reason = "fixture: alpha shares one catalog file";
        };
        beta = { };
      };
      flake-file.inputs.nixpkgs.update = {
        version = "fixed";
        reason = "fixture: upstream pin held";
      };
      perSystem =
        { pkgs, ... }:
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [ consumerStandIn ];
          };
          packages = {
            alpha = pkgs.runCommand "alpha" { } "touch $out";
            beta = pkgs.runCommand "beta" { } "touch $out";
            consumer-nix-update = pkgs.nix-update;
          };
        };
    }).config.flake;

  # flake-file and flakeModules.ci composed, as a flake-file consumer has them.
  withFlakeFile =
    hermes:
    (inputs.flake-parts.lib.evalFlakeModule { inherit inputs; } {
      systems = [ "x86_64-linux" ];
      imports = [
        inputs.flake-file.flakeModules.default
        module
      ];
      flake-file.inputs.hermes = hermes;
    }).config;
  url = "github:fixture/hermes/v1.0.0";
  plain = withFlakeFile { inherit url; };
  overridden = withFlakeFile {
    inherit url;
    update.versionRegex = "v(1\\..*)";
  };
  render = config: "${config.flake.packages.x86_64-linux.write-flake}";
  policyOf =
    config:
    builtins.tryEval (
      builtins.deepSeq config.ci.updates.inputPolicies.hermes config.ci.updates.inputPolicies.hermes
    );
  fixedWithoutReason = withFlakeFile {
    inherit url;
    update.version = "fixed";
  };
in
{
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
      # The input policy composed with flake-file: overrides stay out of the
      # rendered flake.nix, reach the runner with their declaring file, and a
      # fixed input without a reason fails evaluation.
      checks.ci-input-policy =
        assert lib.assertMsg (
          render plain == render overridden
        ) "ci: an input's update policy must not change the rendered flake.nix";
        assert lib.assertMsg (
          render plain != render (withFlakeFile {
            url = "github:fixture/hermes/v2.0.0";
          })
        ) "ci: the flake.nix comparison must see a changed input";
        assert lib.assertMsg (
          (policyOf overridden).value == {
            version = null;
            versionRegex = "v(1\\..*)";
            reason = null;
            file = "modules/ci/updates-checks.nix";
          }
        ) "ci: the policy and the file declaring the input must reach the runner";
        assert lib.assertMsg (
          !(policyOf fixedWithoutReason).success
        ) "ci: a fixed input without a reason must fail evaluation";
        pkgs.runCommand "ci-input-policy-check" { } "touch $out";

      # Offline runner contract: selection, ordering, refusals and transactions.
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

      # The consumer's app binds the consumer's own evaluated updater — never
      # this repository's pin — and its registry carries the consumer's own
      # registrations and input policy.
      checks.package-updates-consumer =
        pkgs.runCommand "package-updates-consumer-check"
          {
            nativeBuildInputs = [
              pkgs.coreutils
              pkgs.gnugrep
              pkgs.jq
              pkgs.jujutsu
            ];
            program = "${consumer.apps.${system}.update-all.program}";
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
            jq -e '.registered | index("bifrost") == null' "$registry" >/dev/null || {
              echo "package-updates: fleet dogfood registration leaked into the consumer"
              exit 1
            }
            jq -e '.writeSets | keys == ["alpha"]' "$registry" >/dev/null || {
              echo "package-updates: only a package with paths carries a write set"
              jq . "$registry"
              exit 1
            }
            jq -e '.inputs.nixpkgs.version == "fixed"' "$registry" >/dev/null || {
              echo "package-updates: the input policy did not reach the registry"
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
