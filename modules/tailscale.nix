# Tailscale baseline. Selection is enablement. Identity comes from
# networking.hostName; tailnet suffix, tags, and routes are consumer policy.
# secretFiles.auth is a two-step sops bootstrap: unbound or missing registers
# nothing. Consumer requirement: sops-nix.nixosModules.sops when binding auth.
_: {
  flake.modules.nixos.tailscale =
    { config, lib, ... }:
    let
      secretHelpers = import ../lib/secrets.nix { inherit lib; };

      cfg = config.services.tailscale;
      hostName = config.networking.hostName;

      authKeyReady = cfg.secretFiles.auth != null && builtins.pathExists cfg.secretFiles.auth;
    in
    {
      options.services.tailscale = {
        debugMtu = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
          description = ''
            Optional Tailscale TUN MTU override, written as TS_DEBUG_MTU into the
            tailscaled unit environment. Packet-size workaround only.
          '';
        };

        secretFiles.auth = secretHelpers.mkSecretFileOption "the Tailscale auth key";

        secretKeys.auth = secretHelpers.mkSecretKeyOption "tailscale/auth_key";
      };

      config = lib.mkMerge [
        {
          assertions = [
            {
              assertion = cfg.debugMtu == null || (cfg.debugMtu >= 576 && cfg.debugMtu <= 65535);
              message = "tailscale: services.tailscale.debugMtu must be null or an MTU between 576 and 65535.";
            }
          ];

          systemd.services = {
            tailscaled = {
              restartIfChanged = false;
              stopIfChanged = false;
            };

            tailscaled-autoconnect = {
              restartIfChanged = false;
              stopIfChanged = false;
              wants = [ "sops-install-secrets.service" ];
              after = [ "sops-install-secrets.service" ];
            };
          };

          services.tailscale = {
            enable = true;
            openFirewall = false;
            extraSetFlags = [ "--ssh" ];
            extraUpFlags = lib.mkDefault [ "--hostname=${hostName}" ];
            authKeyFile = lib.mkIf authKeyReady "/run/secrets/tailscale.auth_key";
          };

          systemd.services.tailscaled.environment = lib.mkIf (cfg.debugMtu != null) {
            TS_DEBUG_MTU = toString cfg.debugMtu;
          };
        }

        (lib.mkIf authKeyReady {
          sops.secrets.tailscale_auth_key = {
            sopsFile = cfg.secretFiles.auth;
            key = cfg.secretKeys.auth;
            path = cfg.authKeyFile;
            mode = "0400";
          };
        })
      ];
    };
}
