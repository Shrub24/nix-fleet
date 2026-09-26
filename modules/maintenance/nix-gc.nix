# Scheduled Nix store garbage collection with a selectable implementation:
# Selection is enablement.
# "nh" keeps nh clean's profile orchestration UX; "fast-nix-gc" uses the
# CSR-graph collector (serves the gc-roots socket while running, so
# concurrent builds register temp roots without blocking on gc.lock —
# kills the GC-vs-build race on builder hosts) and handles profile
# generations itself via deleteOlderThan. Selection is enablement; the
# schedule and retention are consumer-tunable options. The aspect owns the
# unit in either mode, so it also owns its notification registration:
# failure events fire only when the notify aspect is co-selected. Success
# is deliberately not registered: a scheduled cleanup has no start/stop
# news worth reporting.
{
  inputs,
  lib,
  ...
}:
{
  flake.modules.nixos.nix-gc =
    { config, pkgs, ... }:
    let
      cfg = config.services.nix-gc;
    in
    {
      imports = [
        ../notifications/notify/_notify-events.nix
        inputs.fast-nix-gc.nixosModules.default
      ];

      options.services.nix-gc = {
        implementation = lib.mkOption {
          type = lib.types.enum [
            "nh"
            "fast-nix-gc"
          ];
          default = "nh";
          description = "Collector implementation: nh clean orchestration or the fast-nix-gc CSR collector.";
        };

        dates = lib.mkOption {
          type = lib.types.str;
          default = "daily";
          description = "systemd calendar interval for the cleanup timer.";
        };

        extraArgs = lib.mkOption {
          type = lib.types.str;
          default = "--keep 3";
          description = "nh path only: arguments passed to nh clean all (retention policy).";
        };

        generationsOlderThan = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "30d";
          description = "fast-nix-gc path only: remove profile generations older than this.";
        };

        noVacuum = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "fast-nix-gc path only: skip the post-GC database VACUUM (recommended on never-idle builders — the WAL-growth reason nix itself disabled vacuuming).";
        };

        fastNixGcPackage = lib.mkOption {
          type = lib.types.package;
          default = inputs.fast-nix-gc.packages.${pkgs.system}.default;
          defaultText = "inputs.fast-nix-gc.packages.<system>.default";
          description = "fast-nix-gc implementation package.";
        };
      };

      config = lib.mkMerge [
        {
          warnings = lib.optional (
            cfg.implementation == "nh" && cfg.noVacuum
          ) "services.nix-gc: noVacuum applies only to the fast-nix-gc implementation.";

          # Registration is unconditional: the shared fragment declares the
          # namespace, and the notify aspect realizes it only when co-selected.
          services.notify.events."nix-gc".failure = { };
        }

        (lib.mkIf (cfg.implementation == "nh") {
          programs.nh = {
            enable = true;
            clean = {
              enable = true;
              inherit (cfg) dates;
              inherit (cfg) extraArgs;
            };
          };
        })

        (lib.mkIf (cfg.implementation == "fast-nix-gc") {
          services.fast-nix-gc = {
            enable = true;
            automatic = true;
            inherit (cfg) dates;
            deleteOlderThan = cfg.generationsOlderThan;
            inherit (cfg) noVacuum;
          };
        })
      ];
    };
}
