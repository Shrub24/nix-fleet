# Shared Nix package, daemon priorities and substitution policy.
# Selection is enablement; host resource budgets remain consumer-owned.
{ lib, ... }:
{
  flake.modules.nixos.nix-baseline =
    { pkgs, ... }:
    {
      imports = [ ../notifications/notify/_notify-events.nix ];

      config = {
        nix.package = lib.mkDefault pkgs.nixVersions.latest;
        nix.daemonCPUSchedPolicy = lib.mkDefault "batch";
        nix.daemonIOSchedClass = lib.mkDefault "best-effort";
        nix.daemonIOSchedPriority = lib.mkDefault 7;
        systemd.services.nix-daemon.serviceConfig = {
          CPUWeight = lib.mkDefault 50;
          IOWeight = lib.mkDefault 50;
        };

        nix.settings = {
          experimental-features = [
            "nix-command"
            "flakes"
          ];
          auto-optimise-store = lib.mkDefault true;
          always-allow-substitutes = lib.mkDefault true;
          builders-use-substitutes = lib.mkDefault true;

          # The fleet's own cache and builder catalog, so it has one owner. This
          # appends to what nixpkgs already contributes (`cache.nixos.org` and
          # its key) rather than restating it. Consumers append through
          # nix.conf's own `extra-substituters` / `extra-trusted-public-keys`
          # keys, or replace a list with `lib.mkForce`. Deliberately not an
          # option namespace: `substituters` is already an option, and this
          # aspect's own `extraSubstituters` was declared here once and read by
          # nothing, so a host following it silently kept the wrong catalog.
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
