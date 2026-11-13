# Published nixbot effects for a repository built by the fleet's controller: main-push
# cache retention and the scheduled update transaction. The module owns `herculesCI`
# (flake-parts cannot merge two of them); consumer effects join through `extra`.
#
# Contract: docs/contracts/nixbot-effects.md.
{ config, inputs, ... }:
let
  claims = import ../../lib/nixbot-effects.nix;
  fleetModules = config.flake.flakeModules;

  nixbotEffectsModule =
    {
      config,
      lib,
      withSystem,
      ...
    }:
    let
      cfg = config.nixbotEffects;
      retain = cfg.cacheRetain;
      updates = cfg.packageUpdates;
      need = value: option: if value == null then throw "nixbotEffects: ${option} must be set" else value;

      cacheRetainFor =
        { effects }:
        primaryRepo:
        let
          cacheUrl = need retain.cacheUrl "cacheRetain.cacheUrl";
          roots = lib.genAttrs retain.systems (system: config.flake.packages.${system}.cache-root);
          pin = system: "${claims.pinNamespace primaryRepo.name retain.branch}-${system}";
          # A pin refuses a root the cache does not hold, so each root is pushed first.
          # No changed-only guard: rerunning on an unchanged root is how a missed
          # streaming upload is repaired.
          step = system: ''
            niks3 push "''${auth[@]}" ${roots.${system}}
            niks3 pins create "''${auth[@]}" ${pin system} ${roots.${system}}
            nix path-info --store ${lib.escapeShellArg cacheUrl} ${roots.${system}} >/dev/null \
              || { echo "cache-retain: ${system} root is not substitutable from ${cacheUrl}" >&2; exit 1; }
          '';
        in
        lib.optionalAttrs
          ((primaryRepo.branch or null) == retain.branch && (primaryRepo.tag or null) == null)
          {
            ${claims.retainName} = effects.mkEffect {
              name = claims.retainName;
              idTokenAudiences = [ cacheUrl ];
              secretsMap = { };
              lock = "cache";
              # niks3 queries the closure through the runner's daemon proxy with the Nix CLI.
              inputs = [
                retain.niks3Package
                cfg.nixPackage
              ]
              ++ lib.attrValues roots;
              effectScript = ''
                set -euo pipefail
                export NIKS3_SERVER_URL=${lib.escapeShellArg (need retain.writeEndpoint "cacheRetain.writeEndpoint")}
                auth=(--auth-token-script "nixbot-id-token ${cacheUrl} --json")
                ${lib.concatMapStringsSep "\n" step retain.systems}
              '';
            };
          };

      packageUpdatesFor =
        {
          pkgs,
          effects,
          updater,
        }:
        primaryRepo:
        let
          publish = pkgs.callPackage ../../pkgs/nixbot-update-publish { };
        in
        {
          when = need updates.when "packageUpdates.when";
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
              cfg.nixPackage
              updater
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
              nix run .#update-packages -- --refresh-inputs --json "$report" --markdown "$body" || status=$?
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

      joined =
        what: ours: theirs:
        let
          clash = builtins.attrNames (builtins.intersectAttrs ours theirs);
        in
        if clash != [ ] then
          throw "nixbotEffects: extra.${what} redefines fleet-owned ${lib.concatStringsSep ", " clash}"
        else
          ours // theirs;
    in
    {
      key = "nix-fleet#flakeModules.nixbotEffects";
      imports = [
        fleetModules.cacheRoot
        fleetModules.packageUpdates
      ];

      options.nixbotEffects = {
        system = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "System the controller evaluates and runs effects on.";
        };
        nixPackage = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default = null;
          description = "Nix CLI the effects call; match the controller's daemon.";
        };

        cacheRetain = {
          enable = lib.mkEnableOption "main-push cache retention: push each root, move its rolling pin, prove it substitutes";
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
          cacheUrl = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Public read URL of the cache; also the token audience.";
          };
          writeEndpoint = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "niks3 server URL the effect pushes and pins through.";
          };
          niks3Package = lib.mkOption {
            type = lib.types.package;
            default = inputs.niks3.packages.${need cfg.system "system"}.default;
            defaultText = lib.literalMD "nix-fleet's niks3 input";
            description = "niks3 client used to push and pin.";
          };
        };

        packageUpdates = {
          enable = lib.mkEnableOption "the scheduled update transaction: refresh inputs and package pins, propose one pull request";
          when = lib.mkOption {
            type = lib.types.nullOr (lib.types.attrsOf lib.types.raw);
            default = null;
            example = {
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

        extra = {
          onPush = lib.mkOption {
            type = lib.types.functionTo (lib.types.attrsOf lib.types.raw);
            default = _: { };
            description = "Consumer effects under the `${claims.pushJob}` onPush job, given the herculesCI arguments.";
          };
          onSchedule = lib.mkOption {
            type = lib.types.functionTo (lib.types.attrsOf lib.types.raw);
            default = _: { };
            description = "Consumer `onSchedule` jobs, given the herculesCI arguments.";
          };
        };
      };

      config.flake.herculesCI =
        args:
        withSystem (need cfg.system "system") (
          { pkgs, config, ... }:
          let
            effects = inputs.nixbot.lib.effects { inherit pkgs; };
            nix = need cfg.nixPackage "nixPackage";
            ctx = { inherit pkgs effects; };
            ours = {
              onPush = lib.optionalAttrs retain.enable (cacheRetainFor { inherit effects; } args.primaryRepo);
              onSchedule = lib.optionalAttrs updates.enable {
                package-updates = packageUpdatesFor (
                  ctx // { updater = config.apps.update-packages.program; }
                ) args.primaryRepo;
              };
            };
          in
          builtins.seq nix {
            onPush.${claims.pushJob}.outputs.effects = joined "onPush" ours.onPush (cfg.extra.onPush args);
            onSchedule = joined "onSchedule" ours.onSchedule (cfg.extra.onSchedule args);
          }
        );
    };
in
{
  flake.flakeModules.nixbotEffects = nixbotEffectsModule;
  flake.lib.nixbotEffects = claims;
}
