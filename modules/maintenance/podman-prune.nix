# Periodic Podman storage prune (unused images, containers, volumes). The
# aspect owns the unit and timer, so it also owns the notification
# registration: failure-only, and only when the notify aspect is co-selected.
_: {
  flake.modules.nixos.podman-prune =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.podman-prune;
    in
    {
      imports = [ ../notifications/notify/_notify-events.nix ];

      options.services.podman-prune = {
        enable = lib.mkEnableOption "periodic Podman storage pruning";

        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.podman;
          defaultText = "pkgs.podman";
          description = "Podman implementation; override only to swap it.";
        };

        dates = lib.mkOption {
          type = lib.types.str;
          default = "weekly";
          description = "systemd calendar interval for the prune timer.";
        };

        extraArgs = lib.mkOption {
          type = lib.types.str;
          default = "--all --force --volumes";
          description = "Arguments passed to podman system prune.";
        };
      };

      config = lib.mkIf cfg.enable {
        systemd.services.podman-prune = {
          description = "Prune unused Podman storage artifacts";
          path = [ cfg.package ];
          serviceConfig = {
            Type = "oneshot";
            Nice = 19;
            IOSchedulingClass = "idle";
          };
          script = ''
            set -euo pipefail
            podman system prune ${cfg.extraArgs}
          '';
        };

        systemd.timers.podman-prune = {
          description = "Periodic Podman storage prune";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.dates;
            RandomizedDelaySec = "1h";
            Persistent = true;
          };
        };

        # Unconditional: the shared fragment declares the namespace; the
        # notify aspect realizes it only when co-selected.
        services.notify.events."podman-prune".failure = { };
      };
    };
}
