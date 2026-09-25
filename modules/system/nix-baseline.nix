# Shared Nix daemon baseline: the substitution catalog and daemon tuning
# both consumer repos previously duplicated. The catalog is tier-2 shared
# policy — every option carries a consumer override (mkDefault) so hosts
# extend or replace entries without fighting the aspect. The niks3-cache
# aspect's own substituter binding takes precedence over the catalog
# default when co-selected.
{ lib, ... }:
{
  flake.modules.nixos.nix-baseline =
    { config, ... }:
    {
      imports = [ ../notifications/notify/_notify-events.nix ];

      options.services.nix-baseline = {
        enable = lib.mkEnableOption "the shared Nix daemon baseline (substitution catalog + tuning)";

        extraSubstituters = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Additional substituter URLs appended to the shared catalog.";
        };

        extraTrustedPublicKeys = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Public keys for extraSubstituters (or catalog entries overridden per host).";
        };

        extraTrustedSubstituters = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Substituters the local (possibly unprivileged) user may instruct the daemon to use.";
        };
      };

      config = lib.mkIf config.services.nix-baseline.enable {
        nix.settings = {
          experimental-features = [
            "nix-command"
            "flakes"
          ];
          auto-optimise-store = lib.mkDefault true;
          always-allow-substitutes = lib.mkDefault true;
          builders-use-substitutes = lib.mkDefault true;

          substituters = lib.mkAfter [
            "https://nix-community.cachix.org"
            "https://cache.numtide.com"
            "https://cache.shrublab.xyz"
          ];
          trusted-substituters = lib.mkAfter [
            "https://nix-community.cachix.org"
            "https://cache.numtide.com"
            "https://cache.shrublab.xyz"
            "ssh-ng://eu.nixbuild.net"
          ];
          trusted-public-keys = lib.mkAfter [
            "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
            "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
            "nix-cache-1:FW0bJll9BP5ch0mHI+bXOImcD0RKLrH117WfQC+CU4A="
            "nixbuild.net/HWWKWC-1:dnSfpPDHQN/U9wexkK6r3GTaYrwqNwKS70SNGXistKg="
          ];

          connect-timeout = lib.mkDefault 5;
          stalled-download-timeout = lib.mkDefault 30;
          download-attempts = lib.mkDefault 2;
          http-connections = lib.mkDefault 50;
          max-substitution-jobs = lib.mkDefault 8;
          download-buffer-size = lib.mkDefault 268435456;
          # Misses are cheap; nix's built-in one-hour negative cache is not.
          narinfo-cache-negative-ttl = lib.mkDefault 60;
        };

        # The aspect owns the daemon baseline, so it owns the failure
        # registration: nix-daemon comes from systemd.packages (nixpkgs
        # symlinks the unit file), hence fromPackage. Registration is
        # unconditional in the class; the notify aspect realizes it only
        # when co-selected.
        services.notify.events.nix-daemon = {
          fromPackage = true;
          failure = { };
        };
      };
    };
}
