# Scheduled Nix store cleanup with a selectable collector. Selection is
# enablement; schedules and retention are consumer-tunable options.
#
# "nh" keeps nh clean's profile orchestration, ending in the stock collector.
# "fast-nix-gc" uses the CSR-graph collector (it serves the gc-roots socket
# while running, so concurrent builds register temp roots without blocking on
# gc.lock) and is threshold-driven: it runs often but frees only the shortfall
# below `ensureFree`, a no-op when there is room. The store stays warm instead
# of being emptied on a calendar.
#
# Collection never removes what a live root pins, so on that path stale roots
# (`result` links, direnv) are pruned by nh in a separate unit that runs no GC.
# A weekly fast-nix-optimise is a safety net for paths written before
# `auto-optimise-store` dedups inline.
#
# The aspect owns these units, so it registers their failures; events fire only
# when the notify aspect is co-selected. Success is deliberately not registered:
# a scheduled cleanup has no start/stop news worth reporting.
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
      fast = cfg.implementation == "fast-nix-gc";
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
          default = if fast then "hourly" else "daily";
          defaultText = ''"hourly" for fast-nix-gc (cheap when above ensureFree), "daily" for nh'';
          description = "systemd calendar interval for the collection timer.";
        };

        extraArgs = lib.mkOption {
          type = lib.types.str;
          default = "--keep 3";
          description = "nh path only: arguments passed to nh clean all (retention policy).";
        };

        ensureFree = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "15%";
          description = ''
            fast-nix-gc path only: free only until this much of the store's
            filesystem is available ("50G" or "15%"); a run above it does nothing.
            It cannot stop one huge build from filling the disk between runs.
            Null collects every unreferenced path on each run.
          '';
        };

        keepRecent = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "1d";
          description = "fast-nix-gc path only: pin paths registered within this period, so fresh build results survive.";
        };

        generationsOlderThan = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = if cfg.roots.prune then null else "30d";
          defaultText = "null when roots.prune is on (nh owns retention), otherwise \"30d\"";
          description = "fast-nix-gc path only: remove profile generations older than this. Leave null when nh prunes roots so two retention rules cannot disagree.";
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

        roots = {
          prune = lib.mkOption {
            type = lib.types.bool;
            default = fast;
            defaultText = "true for fast-nix-gc";
            description = "Prune stale profile generations and gcroots with `nh clean all --no-gc` before collecting (fast-nix-gc path; the nh path already does).";
          };
          dates = lib.mkOption {
            type = lib.types.str;
            default = "daily";
            description = "systemd calendar interval for root pruning.";
          };
          keep = lib.mkOption {
            type = lib.types.ints.positive;
            default = 3;
            description = "Keep at least this many generations per profile.";
          };
          keepSince = lib.mkOption {
            type = lib.types.str;
            default = "7d";
            description = "Keep gcroots and generations younger than this (humantime). nh's own default is 0h, which can remove live `result` links.";
          };
        };

        optimise = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = fast;
            defaultText = "true for fast-nix-gc";
            description = "Run fast-nix-optimise on a schedule, ordered after collection. It only helps paths written before inline `auto-optimise-store`; it does nothing useful on a filesystem that dedups itself (btrfs, ZFS).";
          };
          dates = lib.mkOption {
            type = lib.types.str;
            default = "weekly";
            description = "systemd calendar interval for the optimiser.";
          };
        };
      };

      config = lib.mkMerge [
        {
          warnings =
            lib.optional (
              !fast && cfg.noVacuum
            ) "services.nix-gc: noVacuum applies only to the fast-nix-gc implementation."
            ++ lib.optional (
              !fast && cfg.optimise.enable
            ) "services.nix-gc: optimise applies only to the fast-nix-gc implementation.";

          # Registration is unconditional: the shared fragment declares the
          # namespace, and the notify aspect realizes it only when co-selected.
          services.notify.events."nix-gc".failure = { };
        }

        (lib.mkIf (!fast) {
          programs.nh = {
            enable = true;
            clean = {
              enable = true;
              inherit (cfg) dates;
              inherit (cfg) extraArgs;
            };
          };
        })

        (lib.mkIf fast {
          services.fast-nix-gc = {
            enable = true;
            automatic = true;
            inherit (cfg) dates ensureFree keepRecent;
            package = cfg.fastNixGcPackage;
            deleteOlderThan = cfg.generationsOlderThan;
            inherit (cfg) noVacuum;
          };
        })

        (lib.mkIf (fast && cfg.roots.prune) {
          systemd.services.nix-gc-roots = {
            description = "Prune stale Nix profile generations and gcroots";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = lib.escapeShellArgs [
                (lib.getExe pkgs.nh)
                "clean"
                "all"
                "--no-gc"
                "--keep"
                (toString cfg.roots.keep)
                "--keep-since"
                cfg.roots.keepSince
                "--keep-one"
                "--elevation-strategy"
                "none"
              ];
            };
            startAt = cfg.roots.dates;
            # Collection sees the pruned roots when both fire together.
            before = [ "fast-nix-gc.service" ];
            restartIfChanged = false;
          };
          systemd.timers.nix-gc-roots.timerConfig.Persistent = true;
          services.notify.events."nix-gc-roots".failure = { };
        })

        (lib.mkIf (fast && cfg.optimise.enable) {
          services.fast-nix-optimise = {
            enable = true;
            automatic = true;
            inherit (cfg.optimise) dates;
            package = cfg.fastNixGcPackage;
          };
          services.notify.events."fast-nix-optimise".failure = { };
        })
      ];
    };
}
