# Fixture evaluation class: exercises every aspect on a throwaway NixOS target
# so `nix flake check` catches option/merge breakage without real hosts.
{ config, lib, ... }:
{
  configurations.nixos.fixture.module = {
    imports = with config.flake.modules.nixos; [
      # add extracted aspects here as they land
    ];
    nixpkgs.hostPlatform = "x86_64-linux";
    boot.loader.grub.enable = false;
    fileSystems."/".device = "nodev";
    system.stateVersion = "25.11";
  };
}
