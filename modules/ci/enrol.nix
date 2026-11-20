# `ci-enrol [--dry-run] [--withdraw] [OWNER/REPO ...]`: enrol repositories in the
# fleet's nixbot instance, or withdraw them. The instance facts come from the
# canonical inventory, so an operator installs this package and configures nothing.
#
# Contract: docs/contracts/federated-ci.md.
{ config, ... }:
let
  inherit (config.flake.lib.ci) instance;
in
{
  perSystem =
    { pkgs, ... }:
    {
      packages.ci-enrol = pkgs.callPackage ../../pkgs/ci-enrol { } (
        pkgs.writeText "ci-enrol-plan.json" (
          builtins.toJSON {
            inherit (instance) appId nixbotUrl;
            requiredChecks = [
              "nixbot/nix-eval"
              "nixbot/nix-build"
            ];
            # Repository admins keep direct pushes to the default branch.
            bypassAdmins = true;
          }
        )
      );

      checks.ci-enrol =
        pkgs.runCommandLocal "ci-enrol-check"
          {
            nativeBuildInputs = [ pkgs.python3 ];
            ENROL_SCRIPT = ../../pkgs/ci-enrol/enrol.py;
          }
          ''
            python3 ${../../tests/ci/test_ci_enrol.py} -v
            touch "$out"
          '';
    };
}
