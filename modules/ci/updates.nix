# flakeModules.ci: the update transaction. One registry of what this repository
# updates — its packages, ecosystem lockfiles and commands, and every flake input by
# its version policy (inputs.nix) — run by the shared runner as `update-all` and
# proposed by the scheduled `package-updates` effect as one pull request.
_:
let
  module =
    moduleArgs@{
      config,
      lib,
      self,
      ...
    }:
    let
      cfg = config.ci;
      inherit (cfg) updates;

      # The repository-relative directory of the partition this module is evaluated in, if any.
      partitionLock =
        let
          # flake-parts passes it as a special argument, so only the module's arguments see it.
          stack = moduleArgs.partitionStack or [ ];
          source = builtins.tryEval config.partitions.${lib.last stack}.extraInputsFlake;
          root = "${builtins.unsafeDiscardStringContext self.outPath}/";
        in
        if stack == [ ] || !source.success || builtins.typeOf source.value != "path" then
          null
        else if lib.hasPrefix root (toString source.value) then
          lib.removePrefix root (toString source.value)
        else
          throw "ci: partition ${lib.last stack} reads its inputs from outside this repository";

      # A lockfile refresh is the ecosystem's own command; the build must read the
      # lockfile (cargoLock.lockFile, crane, importNpmLock, bun2nix) rather than a
      # vendored hash, or the refreshed lock no longer builds.
      lockfileAdapters = {
        cargo = {
          tool = pkgs: pkgs.cargo;
          run = "cargo update";
          files = [ "Cargo.lock" ];
        };
        bun = {
          tool = pkgs: pkgs.bun;
          run = "bun update";
          files = [
            "bun.lock"
            "package.json"
          ];
        };
        npm = {
          tool = pkgs: pkgs.nodejs;
          run = "npm update --package-lock-only";
          files = [
            "package-lock.json"
            "package.json"
          ];
        };
      };
      lockfileCommand =
        name: lockfile:
        let
          adapter = lockfileAdapters.${lockfile.ecosystem};
          at = file: if lockfile.directory == "." then file else "${lockfile.directory}/${file}";
        in
        {
          program =
            { pkgs, ... }:
            lib.getExe (
              pkgs.writeShellApplication {
                name = "update-${name}";
                runtimeInputs = [ (adapter.tool pkgs) ];
                text = ''
                  cd ${lib.escapeShellArg lockfile.directory}
                  ${adapter.run}
                '';
              }
            );
          paths = map at adapter.files;
        };

      updatesJob =
        {
          primaryRepo,
          pkgs,
          effects,
          perSystem,
          ...
        }:
        let
          publish = pkgs.callPackage ../../pkgs/nixbot-update-publish { };
        in
        {
          inherit (updates) when;
          outputs.effects.update = effects.mkEffect {
            name = "package-updates";
            checkout = true;
            # One producer: an overlapping run would refresh from a moved base.
            lock = "package-updates";
            # `forge-read` is the instance's read-only GitHub token, bound for every
            # enrolled repository; it only lifts the anonymous API rate limit.
            secretsMap = {
              token.type = "GitToken";
              forge = "forge-read";
            };
            # Entries must be derivations: stdenv sources any regular file it
            # finds among an input's paths as a setup hook. The app is reached
            # by its absolute program path in the script, which carries it in.
            inputs = [
              pkgs.git
              pkgs.jq
              pkgs.jujutsu
              cfg.nixPackage
              publish
            ];
            passthru = { inherit publish; };
            effectScript = ''
              set -euo pipefail
              cd "''${NIXBOT_EFFECT_CHECKOUT:?nixbot must supply the checkout}"
              work=$(mktemp -d)
              report=$work/package-updates.json
              body=$work/package-updates.md

              # The batch sees only the read-only token, which every updater
              # reads as GITHUB_TOKEN and nix as an access token; the token that
              # can push stays with the publish step.
              token=$(jq -r '.token.data.token' "$HERCULES_CI_SECRETS_JSON")
              forge=$(jq -r '.forge.data.token' "$HERCULES_CI_SECRETS_JSON")
              unset HERCULES_CI_SECRETS_JSON

              # The sandbox carries no jj user config, so the transaction's
              # commits and the publish push need an author from the environment.
              export JJ_USER=${lib.escapeShellArg updates.identity.name}
              export JJ_EMAIL=${lib.escapeShellArg updates.identity.email}

              # The batch stages through a jj workspace; the clone starts as plain git.
              [ -d .jj ] || jj git init --colocate >/dev/null

              status=0
              GITHUB_TOKEN=$forge NIX_CONFIG="access-tokens = github.com=$forge" \
                ${perSystem.apps.update-all.program} --refresh-inputs --json "$report" --markdown "$body" || status=$?
              if [ ! -f "$report" ]; then
                echo "package-updates: the batch wrote no report (exit $status)" >&2
                exit 1
              fi
              outcome=$(jq -r .outcome "$report")
              echo "package-updates: outcome=$outcome (exit $status)"
              # `partial` is proposable and names what failed; `aborted` carries no tree.
              case "$outcome" in
                complete | partial) ;;
                *)
                  echo "package-updates: nothing proposable" >&2
                  exit 1
                  ;;
              esac

              if [ -z "$(git status --porcelain)" ]; then
                echo "package-updates: nothing to publish"
                exit 0
              fi

              jj describe -m ${lib.escapeShellArg updates.title} -r @
              # A previous proposal may still hold the branch; the fresh clone
              # leaves it untracked, and jj refuses to push over an untracked one.
              jj bookmark track ${lib.escapeShellArg "${updates.branch}@origin"}
              jj bookmark set ${lib.escapeShellArg updates.branch} -r @ --allow-backwards
              jj git push --bookmark ${lib.escapeShellArg updates.branch}

              TOKEN="$token" ${lib.getExe publish} ${lib.optionalString updates.autoMerge "--auto-merge"} \
                ${lib.escapeShellArg primaryRepo.remoteHttpUrl} \
                ${lib.escapeShellArg "${primaryRepo.owner}/${primaryRepo.name}"} \
                ${lib.escapeShellArg updates.branch} \
                ${lib.escapeShellArg (primaryRepo.branch or "main")} \
                ${lib.escapeShellArg updates.title} \
                "$body"
            '';
          };
        };
    in
    {
      key = "nix-fleet#ci.updates";

      options.ci.updates = {
        enable = lib.mkEnableOption "the scheduled update transaction" // {
          default = true;
        };
        when = lib.mkOption {
          type = lib.types.attrsOf lib.types.raw;
          # After nix-fleet's own 03:43 run, so a consumer picks up its merged lock.
          default = {
            minute = 43;
            hour = [ 7 ];
            dayOfWeek = [
              "Mon"
              "Thu"
            ];
          };
          description = "nixbot `onSchedule` `when` for the update run.";
        };
        branch = lib.mkOption {
          type = lib.types.str;
          default = "automation/package-updates";
          description = "Branch the update is pushed to.";
        };
        title = lib.mkOption {
          type = lib.types.str;
          default = "chore(deps): Refresh flake inputs and package pins";
          description = "Commit and pull request title.";
        };
        autoMerge = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Request auto-merge on the update pull request.";
        };
        identity = {
          name = lib.mkOption {
            type = lib.types.str;
            default = "nixbot";
            description = "Author name the effect's commits carry.";
          };
          email = lib.mkOption {
            type = lib.types.str;
            default = "nixbot@users.noreply.github.com";
            description = "Author email the effect's commits carry.";
          };
        };

        packages = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                paths = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = ''
                    Repository-relative paths the updater may change, replacing the
                    default `pkgs/<name>`. A shared path needs a `reason`.
                  '';
                };
                reason = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Why the paths belong to this updater; refused by name when `paths` is set without one.";
                };
              };
            }
          );
          default = { };
          example = lib.literalExpression "{ bifrost = { }; }";
          description = ''
            `packages.<system>` outputs this repository owns and updates, each through
            nix-update and its own `passthru.updateScript`. A package family with
            shared pins has exactly one registered owner. Register a package in the
            file that defines it.
          '';
        };

        lockfiles = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                ecosystem = lib.mkOption {
                  type = lib.types.enum (builtins.attrNames lockfileAdapters);
                  description = "Which ecosystem's lockfile to refresh within its declared ranges.";
                };
                directory = lib.mkOption {
                  type = lib.types.str;
                  default = ".";
                  description = "Repository-relative directory holding the manifest.";
                };
              };
            }
          );
          default = { };
          example = {
            cargo.ecosystem = "cargo";
            web = {
              ecosystem = "bun";
              directory = "web";
            };
          };
          description = "Ecosystem lockfiles refreshed in the transaction, each as a command.";
        };

        commands = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                program = lib.mkOption {
                  type = lib.types.functionTo lib.types.str;
                  description = ''
                    Given `{ pkgs, system }`, the executable run from the checkout root;
                    it may edit only `paths`.
                  '';
                };
                paths = lib.mkOption {
                  type = lib.types.nonEmptyListOf lib.types.str;
                  description = "Repository-relative paths the command may change.";
                };
              };
            }
          );
          default = { };
          description = ''
            Updates that are neither a package nor an input, keyed by name: a generated
            file, a vendored artefact. Each runs in the same transaction.
          '';
        };
      };

      config = {
        ci.updates.commands = lib.mkMerge [
          (lib.mapAttrs lockfileCommand updates.lockfiles)
          # Inside a partition the CI inputs have their own lock; refresh it with the rest.
          (lib.mkIf (partitionLock != null) {
            ci-inputs = {
              program =
                { pkgs, ... }:
                toString (
                  pkgs.writeShellScript "update-ci-inputs" "exec nix flake update --flake ./${partitionLock}"
                );
              paths = [ "${partitionLock}/flake.lock" ];
            };
          })
        ];

        ci.effects.onSchedule.package-updates = lib.mkIf updates.enable updatesJob;

        perSystem =
          {
            config,
            pkgs,
            system,
            ...
          }:
          let
            registry = pkgs.writeText "package-updates-registry.json" (
              builtins.toJSON {
                inherit system;
                registered = builtins.attrNames updates.packages;
                available = builtins.attrNames config.packages;
                writeSets = lib.mapAttrs (
                  name: package:
                  lib.throwIf (
                    package.reason == null || lib.trim package.reason == ""
                  ) "ci: ci.updates.packages.${name}.paths needs a reason" { inherit (package) paths reason; }
                ) (lib.filterAttrs (_: package: package.paths != [ ]) updates.packages);
                commands = lib.mapAttrs (_: command: {
                  program = command.program { inherit pkgs system; };
                  inherit (command) paths;
                }) updates.commands;
                inputs = updates.inputPolicies;
                # A flake-file repository regenerates flake.nix (flake-file exports
                # write-flake as a package); any other repository edits it directly.
                writeFlake = if config.packages ? write-flake then lib.getExe config.packages.write-flake else null;
              }
            );

            runnerPackage = pkgs.callPackage ../../pkgs/package-updates { };
            runtime = [
              runnerPackage
              pkgs.nix
              pkgs.nix-update
              (pkgs.callPackage ../../pkgs/flake-edit { })
              pkgs.jujutsu
              pkgs.git
            ];

            # Pin nixpkgs for nix-update's flake --use-update-script path rather
            # than the ambient channel.
            registryEnv = ''
              export PACKAGE_UPDATES_REGISTRY=${registry}
              export NIX_PATH="nixpkgs=${pkgs.path}''${NIX_PATH:+:$NIX_PATH}"
            '';
            mkApp =
              name: runtimeInputs: text:
              lib.getExe (pkgs.writeShellApplication { inherit name runtimeInputs text; });
          in
          {
            apps = {
              # The whole transaction, or the named updates: the scriptable command.
              update-all = {
                type = "app";
                program = mkApp "update-all" runtime (registryEnv + ''exec update-all "$@"'');
              };
              # A picker over flake inputs and package updates, applying only what is accepted.
              update = {
                type = "app";
                program = mkApp "update" (
                  runtime
                  ++ [
                    pkgs.fzf
                    pkgs.gh
                  ]
                ) (registryEnv + ''exec update "$@"'');
              };
            };
          };
      };
    };
in
{
  imports = [ module ];
  flake.modules.flake.ci = module;
}
