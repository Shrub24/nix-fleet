# The federation plane: the instance operator's one repository list, reconciled on
# the forge by `nix run .#ci-enrol`. The same list drives the operator's nixbot
# `repoAllowlist` and `services.niks3-cache.nixbot.repositories`.
#
# Contract: docs/contracts/federated-ci.md.
{ inputs, ... }:
let
  ciFederationModule =
    { config, lib, ... }:
    let
      cfg = config.ciFederation;
    in
    {
      key = "nix-fleet#flakeModules.ciFederation";

      options.ciFederation = {
        repositories = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options.branch = lib.mkOption {
                type = lib.types.str;
                default = "main";
                description = "The repository's retained branch, where its checks are required.";
              };
            }
          );
          default = { };
          example = {
            "owner/repo" = { };
          };
          description = "Enrolled repositories, `owner/name`.";
        };
        appId = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
          description = "The nixbot GitHub App's id: the integration its required checks must come from.";
        };
        installationId = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
          description = "The App's installation on the owner; null leaves installation to the operator.";
        };
        nixbotUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "The instance's public URL, for enabling projects.";
        };
        requiredChecks = lib.mkOption {
          type = lib.types.nonEmptyListOf lib.types.str;
          default = [
            "nixbot/nix-eval"
            "nixbot/nix-build"
          ];
          description = "Checks a pull request needs before merging.";
        };
        bypassAdmins = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Let repository admins push to the retained branch without the checks.";
        };
      };

      config.perSystem =
        { pkgs, system, ... }:
        let
          need = value: option: if value == null then throw "ciFederation: ${option} must be set" else value;
          plan = pkgs.writeText "ci-enrol-plan.json" (
            builtins.toJSON {
              inherit (cfg)
                repositories
                installationId
                requiredChecks
                bypassAdmins
                ;
              appId = need cfg.appId "appId";
              nixbotUrl = need cfg.nixbotUrl "nixbotUrl";
            }
          );
        in
        {
          apps.ci-enrol = {
            type = "app";
            program = lib.getExe (
              pkgs.callPackage ../../pkgs/ci-enrol { inherit (inputs.nixbot.packages.${system}) nixbot-cli; } plan
            );
          };
        };
    };
in
{
  flake.flakeModules.ciFederation = ciFederationModule;

  perSystem =
    { pkgs, ... }:
    {
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
