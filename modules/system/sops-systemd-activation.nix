{ lib, ... }:
{
  flake.modules.nixos.sops-systemd-activation =
    { config, ... }:
    {
      sops.useSystemdActivation = lib.mkDefault true;

      assertions = [
        {
          assertion = config.sops.useSystemdActivation;
          message = "sops-systemd-activation: sops.useSystemdActivation must remain enabled; migrate consumers using legacy activation.";
        }
      ];
    };
}
