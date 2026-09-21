# Scheduled Nix store garbage collection via nh. Selection is enablement;
# the schedule and retention are consumer-tunable options. The aspect owns
# the nh-clean unit, so it also owns its notification registration: failure
# events fire only when the notify aspect is co-selected (an unknown-option
# failure otherwise — an invalid composition). Success is deliberately not
# registered: a scheduled cleanup has no start/stop news worth reporting.
_: {
  flake.modules.nixos.nh-gc =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [ ../notifications/notify/_notify-events.nix ];

      options.services.nh-gc = {
        enable = lib.mkEnableOption "scheduled Nix store garbage collection (nh clean)";

        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.nh;
          defaultText = "pkgs.nh";
          description = "nh implementation; override only to swap it.";
        };

        dates = lib.mkOption {
          type = lib.types.str;
          default = "daily";
          description = "systemd calendar interval for the cleanup timer.";
        };

        extraArgs = lib.mkOption {
          type = lib.types.str;
          default = "--keep 3";
          description = "Arguments passed to nh clean all (retention policy).";
        };
      };

      config = lib.mkIf config.services.nh-gc.enable {
        programs.nh = {
          enable = true;
          clean = {
            enable = true;
            dates = config.services.nh-gc.dates;
            inherit (config.services.nh-gc) extraArgs;
          };
        };

        # Registration is unconditional: the shared fragment declares the
        # namespace, and the notify aspect realizes it only when co-selected.
        services.notify.events."nh-clean".failure = { };
      };
    };
}
