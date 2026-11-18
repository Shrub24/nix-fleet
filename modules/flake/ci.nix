# The federated CI interface: a repository imports flakeModules.ci and the fleet's
# nixbot instance builds its `checks`, retains its roots in the cache, and proposes
# its updates. Every effect is an entry of `ci.effects`, the fleet's included, so a
# repository extends or disables them with ordinary module semantics.
#
# Contract: docs/contracts/federated-ci.md.
{ config, inputs, ... }:
let
  claims = import ../../lib/ci.nix;
  fleetModules = config.flake.flakeModules;

  ciModule =
    args@{
      config,
      lib,
      self,
      withSystem,
      ...
    }:
    let
      cfg = config.ci;
      inherit (cfg) retention;
      inherit (cfg) updates;
      need = value: option: if value == null then throw "ci: ${option} must be set" else value;

      # The repository-relative directory of the partition this module is evaluated in, if any.
      partitionLock =
        let
          # flake-parts passes it as a special argument, so only `args` sees it.
          stack = args.partitionStack or [ ];
          source = builtins.tryEval config.partitions.${lib.last stack}.extraInputsFlake;
          root = "${builtins.unsafeDiscardStringContext self.outPath}/";
        in
        if stack == [ ] || !source.success || builtins.typeOf source.value != "path" then
          null
        else if lib.hasPrefix root (toString source.value) then
          lib.removePrefix root (toString source.value)
        else
          throw "ci: partition ${lib.last stack} reads its inputs from outside this repository";
      instance = need cfg.instance "ci.instance";

      effectType = lib.types.attrsOf (lib.types.functionTo (lib.types.nullOr lib.types.raw));

      # Push each system's root, then pin it, then prove it substitutes. A pin
      # refuses a root the cache does not hold, so the push comes first; there is
      # no changed-only guard, because rerunning is how a missed upload is repaired.
      retainEffect =
        {
          name,
          pkgs,
          effects,
          pinOf,
          generations,
        }:
        let
          roots = lib.genAttrs retention.systems (system: config.flake.packages.${system}.cache-root);
          # Older generations shift down only when the rolling pin moves, so a
          # rerun on the same root leaves history alone. Shifting rewrites pins
          # rather than deleting them: deletion needs the cache's admin scope.
          shift =
            pin:
            lib.optionalString (generations > 0) ''
              current=$(pinned ${pin})
              if [ -n "$current" ] && [ "$current" != "$root" ]; then
                for k in $(seq ${toString generations} -1 2); do
                  previous=$(pinned "${pin}-$((k - 1))")
                  [ -z "$previous" ] || niks3 pins create "''${auth[@]}" "${pin}-$k" "$previous"
                done
                niks3 pins create "''${auth[@]}" ${pin}-1 "$current"
              fi
            '';
          step = system: ''
            root=${roots.${system}}
            niks3 push "''${auth[@]}" "$root"
            ${shift (pinOf system)}
            niks3 pins create "''${auth[@]}" ${pinOf system} "$root"
            # The effect sandbox's Nix enables no experimental features.
            nix --extra-experimental-features nix-command path-info --store ${lib.escapeShellArg instance.cacheUrl} "$root" >/dev/null \
              || { echo "${name}: ${system} root failed the substitution check against ${instance.cacheUrl}" >&2; exit 1; }
          '';
        in
        effects.mkEffect {
          inherit name;
          idTokenAudiences = [ instance.cacheUrl ];
          secretsMap = { };
          lock = "cache";
          # niks3 queries the closure through the runner's daemon proxy with the Nix CLI.
          inputs = [
            cfg.niks3Package
            (need cfg.nixPackage "ci.nixPackage")
            pkgs.jq
          ]
          ++ lib.attrValues roots;
          effectScript = ''
            set -euo pipefail
            export NIKS3_SERVER_URL=${lib.escapeShellArg instance.writeEndpoint}
            auth=(--auth-token-script "nixbot-id-token ${instance.cacheUrl} --json")
            ${lib.optionalString (generations > 0) ''
              pins=$(niks3 pins list --json "''${auth[@]}")
              pinned() { jq -r --arg name "$1" '.[] | select(.name == $name) | .store_path' <<<"$pins"; }
            ''}
            ${lib.concatMapStringsSep "\n" step retention.systems}
          '';
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
            secretsMap.token.type = "GitToken";
            inputs = [
              pkgs.git
              pkgs.jq
              pkgs.jujutsu
              (need cfg.nixPackage "ci.nixPackage")
              perSystem.apps.update-packages.program
              publish
            ];
            passthru = { inherit publish; };
            effectScript = ''
              set -euo pipefail
              cd "''${NIXBOT_EFFECT_CHECKOUT:?nixbot must supply the checkout}"
              work=$(mktemp -d)
              report=$work/package-updates.json
              body=$work/package-updates.md

              # Update scripts never see the credential that can push.
              token=$(jq -r '.token.data.token' "$HERCULES_CI_SECRETS_JSON")
              unset HERCULES_CI_SECRETS_JSON

              # The batch stages through a jj workspace; the clone starts as plain git.
              [ -d .jj ] || jj git init --colocate >/dev/null

              status=0
              ${perSystem.apps.update-packages.program} --refresh-inputs --json "$report" --markdown "$body" || status=$?
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
              jj bookmark set ${lib.escapeShellArg updates.branch} -r @
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
      key = "nix-fleet#flakeModules.ci";
      imports = [
        fleetModules.cacheRoot
        fleetModules.packageUpdates
      ];

      options.ci = {
        instance = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                system = lib.mkOption {
                  type = lib.types.str;
                  description = "System the controller evaluates and runs effects on.";
                };
                cacheUrl = lib.mkOption {
                  type = lib.types.str;
                  description = "Public read URL of the cache; also the token audience.";
                };
                writeEndpoint = lib.mkOption {
                  type = lib.types.str;
                  description = "niks3 server URL effects push and pin through.";
                };
              };
            }
          );
          default = null;
          description = "The instance descriptor its operator publishes; bind it, do not restate it.";
        };
        nixPackage = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default =
            if cfg.instance == null then null else inputs.nixpkgs.legacyPackages.${cfg.instance.system}.nix;
          defaultText = lib.literalMD "nix-fleet's nixpkgs `nix` for the instance system";
          description = "Nix CLI the effects call.";
        };
        niks3Package = lib.mkOption {
          type = lib.types.package;
          default = inputs.niks3.packages.${instance.system}.default;
          defaultText = lib.literalMD "nix-fleet's niks3 input";
          description = "niks3 client used to push and pin.";
        };

        retention = {
          enable = lib.mkEnableOption "cache retention of the default branch's roots" // {
            default = true;
          };
          branch = lib.mkOption {
            type = lib.types.str;
            default = "main";
            description = "Branch whose pushes are retained; must match the cache's rule for this repository.";
          };
          systems = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = config.systems;
            defaultText = lib.literalExpression "config.systems";
            description = "Systems whose `cache-root` is pushed and pinned.";
          };
          generations = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 0;
            description = "Earlier roots kept as `<pin>-1` … `<pin>-<n>` behind the rolling pin.";
          };
          releases = lib.mkEnableOption "a pin per pushed tag, `<name>-release-<tag>-<system>`" // {
            default = true;
          };
        };

        updates = {
          enable = lib.mkEnableOption "the scheduled update transaction" // {
            default = true;
          };
          when = lib.mkOption {
            type = lib.types.attrsOf lib.types.raw;
            default = {
              minute = 43;
              hour = [ 4 ];
              dayOfWeek = [ "Mon" ];
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
        };

        effects = {
          onPush = lib.mkOption {
            type = effectType;
            default = { };
            description = ''
              Effects under the `${claims.pushJob}` onPush job, each a function of
              `{ primaryRepo, pkgs, effects, perSystem, ... }` returning an effect or
              null (not this push).
            '';
          };
          onSchedule = lib.mkOption {
            type = effectType;
            default = { };
            description = "Schedule jobs, each a function of the same arguments returning `{ when; outputs.effects; }` or null.";
          };
        };
      };

      config = {
        ci.effects.onPush.${claims.retainName} = lib.mkIf retention.enable (
          args@{ primaryRepo, ... }:
          if (primaryRepo.branch or null) == retention.branch && (primaryRepo.tag or null) == null then
            retainEffect {
              inherit (args) pkgs effects;
              name = claims.retainName;
              pinOf = system: "${claims.pinNamespace primaryRepo.name retention.branch}-${system}";
              inherit (retention) generations;
            }
          else
            null
        );

        ci.effects.onPush.${claims.releaseName} = lib.mkIf (retention.enable && retention.releases) (
          args@{ primaryRepo, ... }:
          if (primaryRepo.tag or null) != null then
            retainEffect {
              inherit (args) pkgs effects;
              name = claims.releaseName;
              pinOf =
                system:
                "${claims.releaseNamespace primaryRepo.name}-${
                  builtins.replaceStrings [ "/" ] [ "-" ] primaryRepo.tag
                }-${system}";
              generations = 0;
            }
          else
            null
        );

        ci.effects.onSchedule.package-updates = lib.mkIf updates.enable updatesJob;

        # Pull requests build the root retention pins, so the merge reuses it.
        perSystem =
          { config, pkgs, ... }:
          {
            checks = lib.mkIf retention.enable { cache-root = config.packages.cache-root; };
            # Inside a partition the CI inputs have their own lock; refresh it with the rest.
            packageUpdates.commands = lib.mkIf (partitionLock != null) {
              ci-inputs = {
                program = toString (
                  pkgs.writeShellScript "update-ci-inputs" "exec nix flake update --flake ./${partitionLock}"
                );
                paths = [ "${partitionLock}/flake.lock" ];
              };
            };
          };

        flake.herculesCI =
          args:
          withSystem instance.system (
            { pkgs, config, ... }:
            let
              context = args // {
                inherit pkgs;
                effects = inputs.nixbot.lib.effects { inherit pkgs; };
                perSystem = config;
              };
              render = lib.flip lib.pipe [
                (lib.mapAttrs (_: entry: entry context))
                (lib.filterAttrs (_: value: value != null))
              ];
            in
            {
              onPush.${claims.pushJob}.outputs.effects = render cfg.effects.onPush;
              onSchedule = render cfg.effects.onSchedule;
            }
          );
      };
    };
in
{
  flake.flakeModules.ci = ciModule;
  flake.lib.ci = claims;
}
