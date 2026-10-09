# Fleet cleanup defaults: nh prunes stale profile generations and gcroots
# without collecting, then the fast collector reclaims unreferenced paths.
#
# Every value here is an ordinary default on the option that owns it
# (`programs.nh.clean.*`, `services.fast-nix-gc.*`,
# `services.fast-nix-optimise.*`), so a host states its difference directly
# instead of going through a fleet option namespace. Contract:
# docs/contracts/nix-gc.md.
{
  inputs,
  lib,
  ...
}:
{
  flake.modules.nixos.nix-gc =
    { config, ... }:
    {
      imports = [
        ../../lib/notify-contract.nix
        inputs.fast-nix-gc.nixosModules.default
      ];

      programs.nh = {
        enable = lib.mkDefault true;
        clean = {
          enable = lib.mkDefault true;
          dates = lib.mkDefault "daily";
          # `--no-gc` keeps pruning and collection independent; `--keep-since`
          # is explicit because nh's own default of 0h can drop live `result`
          # links and direnv roots.
          extraArgs = lib.mkDefault "--keep 3 --keep-since 7d --keep-one --no-gc";
        };
      };

      # Collection is unconditional: without a free-space threshold the store
      # hovers near its working set instead of near the disk's capacity, and
      # `keepRecent` stops a fresh build's paths from being the victim.
      services.fast-nix-gc = {
        enable = lib.mkDefault true;
        automatic = lib.mkDefault true;
        dates = lib.mkDefault "hourly";
        keepRecent = lib.mkDefault "1d";
      };

      # Safety net for paths written before `auto-optimise-store` deduped
      # inline; it does nothing useful on a filesystem that dedups itself.
      services.fast-nix-optimise = {
        enable = lib.mkDefault true;
        automatic = lib.mkDefault true;
        dates = lib.mkDefault "weekly";
      };

      # The collector is also the manual tool for inspecting and reclaiming
      # store space on a live host.
      environment.systemPackages = [ config.services.fast-nix-gc.package ];

      # The ordering drop-in and the three failure registrations follow the
      # units they describe, because both fail loudly against a unit that is not
      # there: notify rejects a registration whose unit has no service
      # implementation, and an ordering drop-in on its own would create a
      # phantom `nh-clean` unit with no ExecStart (the same failure as the
      # unconditional `tailscaled-autoconnect`). Turning a unit off is the
      # override this aspect's contract invites, so it must leave no trace.
      # `mkIf` sits on `systemd.services` itself, not on `nh-clean.before`: a
      # conditional drop-in would still declare the unit. `optionalAttrs` rather
      # than `mkIf` keeps each registration a plain definition, as the
      # alertmanager aspect does.
      systemd.services = lib.mkIf config.programs.nh.clean.enable {
        # When both timers fire at the same moment, collection must see the
        # roots nh just pruned.
        nh-clean.before = [ "fast-nix-gc.service" ];
      };

      services.notify.events =
        lib.optionalAttrs config.programs.nh.clean.enable {
          "nh-clean".failure = { };
        }
        // lib.optionalAttrs config.services.fast-nix-gc.enable {
          "fast-nix-gc".failure = { };
        }
        // lib.optionalAttrs config.services.fast-nix-optimise.enable {
          "fast-nix-optimise".failure = { };
        };
    };
}
