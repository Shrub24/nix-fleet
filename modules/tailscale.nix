# Aspect: tailscale — Tailscale baseline (FND-1).
#
# Extracted from nix-homelab's `tailscale` foundation aspect. Selecting the
# aspect is the enablement: it turns on the service, keeps Tailscale SSH and the
# firewall closed, and pins the systemd restart/ordering behavior that keeps an
# enrolled node from bouncing. The node's identity comes from the host itself
# (`networking.hostName`); the tailnet suffix, tags, and route advertisement are
# consumer policy and are deliberately absent here.
#
# The auth key arrives as a typed `secretFiles.auth` option. When the consumer
# binds a path that exists, its SOPS key is registered and wired as
# `authKeyFile`; when it is unbound or not yet present (two-step sops
# bootstrap), nothing is registered and the node simply stays unauthenticated
# until the operator adds the scope.
#
# Consumer requirement: import `sops-nix.nixosModules.sops` when binding
# `secretFiles.auth`.
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
            Optional Tailscale TUN MTU override. When set, the module writes
            TS_DEBUG_MTU into the tailscaled unit environment. Host-scoped packet
            size workaround only: no enrollment, identity, tag, firewall, route,
            or experimental PMTUD change.
          '';
        };

        secretFiles.auth = secretHelpers.mkSecretFileOption "the Tailscale auth key";

        secretKeys.auth = lib.mkOption {
          type = lib.types.str;
          default = "tailscale/auth_key";
          description = "SOPS key path of the auth key inside `secretFiles.auth`.";
        };
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
            path = "/run/secrets/tailscale.auth_key";
            mode = "0400";
          };
        })
      ];
    };
}
