# flakeModules.ci: retention. `cache-root` is the artefact set a pin protects — a
# linkFarm over the published packages. A default-branch push pins it per system
# under the rolling `<name>-main-<system>` pin with optional earlier generations;
# a tag push pins it under `<name>-release-<tag>-<system>`. Pull requests build
# `cache-root` as a check, so the merge reuses it.
{ lib, ... }:
let
  claims = import ../../lib/ci.nix lib;

  module =
    { config, lib, ... }:
    let
      cfg = config.ci;
      inherit (cfg) retention instance;

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
            cfg.nixPackage
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
    in
    {
      key = "nix-fleet#ci.retention";

      options.ci.retention = {
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

        perSystem =
          { config, pkgs, ... }:
          {
            # Verdicts are not here: they answer questions about a revision, and a
            # selection containing them would change on every commit.
            packages.cache-root = pkgs.linkFarm "cache-root" (
              lib.mapAttrsToList (name: path: { inherit name path; }) (
                lib.filterAttrs (name: _: name != "cache-root") config.packages
              )
            );
            checks = lib.mkIf retention.enable { cache-root = config.packages.cache-root; };
          };
      };
    };
in
{
  imports = [ module ];
  flake.modules.flake.ci = module;
}
