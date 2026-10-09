# Tailscale baseline. Selection is enablement. Identity comes from
# networking.hostName; tailnet suffix, tags, and routes are consumer policy.
# secretFiles.auth is a two-step sops bootstrap: unbound or missing registers
# nothing. Consumer requirement: sops-nix.nixosModules.sops when binding auth.
# The tailscaled daemon registers a failure event like any other monitored
# unit (fromPackage: nixpkgs ships the unit file); autoconnect is unregistered
# — its retry exits are the mechanism working, not news.
_: {
  flake.modules.nixos.tailscale =
    {
      config,
      lib,
      ...
    }:
    let
      secretHelpers = import ../../lib/secrets.nix { inherit lib; };

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

        sshServe = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Advertise Tailscale SSH (--ssh on tailscale set). Moves SSH auth
            for tailnet peers from host keys to tailnet ACLs — deliberate
            policy, off only when a consumer needs plain sshd auth.
          '';
        };

        secretFiles.auth = secretHelpers.mkSecretFileOption "the Tailscale auth key";

        secretKeys.auth = secretHelpers.mkSecretKeyOption "tailscale/auth_key";
      };

      # Same idiom as the maintenance aspects: the fragment declares the
      # notify contract namespace unconditionally; the notify aspect realizes
      # registrations only when co-selected. The telemetry fragment is the same
      # shape: the daemon's local metrics endpoint is published as a dormant
      # scrape source, so a host that ships no metrics lane evaluates and
      # scrapes nothing.
      imports = [
        ../../lib/notify-contract.nix
        ../../lib/telemetry-contract.nix
      ];

      config = lib.mkMerge [
        {
          # The daemon's own local metrics endpoint: tailscaled serves
          # Prometheus metrics at the tailnet-local `100.100.100.100` magic
          # address on port 80, which is reachable on this host without a
          # listener of our own. Registering the source is the whole
          # integration — no `--webclient`, no OAuth client, no additional
          # firewall rule, and no tailnet-facing HTTP listener is enabled
          # here, so this adds no exposure beyond the daemon the host already
          # runs. The address is the daemon's contract, not a consumer policy
          # input, so it is a literal with the port as the one overridable
          # value: a consumer that must repoint the scrape edits the
          # registration, and the listener is still the daemon's.
          services.telemetry.scrape.tailscale = {
            target = "100.100.100.100";
            port = 80;
            metricsPath = "/metrics";
          };

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
          };

          # Same idiom as the maintenance aspects: registration is unconditional
          # (the fragment declares the namespace); the notify aspect realizes
          # it only when co-selected. tailscaled comes from systemd.packages,
          # hence fromPackage.
          services.notify.events.tailscaled = {
            fromPackage = true;
            failure = { };
          };

          services.tailscale = {
            enable = true;
            openFirewall = false;
            extraSetFlags = lib.optionals cfg.sshServe [ "--ssh" ];
            extraUpFlags = lib.mkDefault [ "--hostname=${hostName}" ];
            authKeyFile = lib.mkIf authKeyReady "/run/secrets/tailscale.auth_key";
          };

          systemd.services.tailscaled.environment = lib.mkIf (cfg.debugMtu != null) {
            TS_DEBUG_MTU = toString cfg.debugMtu;
          };
        }

        (lib.mkIf authKeyReady {
          # nixpkgs defines this unit only when authKeyFile is set, so the
          # ordering lives under the same condition: defined alone it renders a
          # unit with no ExecStart, which systemd warns about on every boot.
          systemd.services.tailscaled-autoconnect = {
            restartIfChanged = false;
            stopIfChanged = false;
            wants = [ "sops-install-secrets.service" ];
            after = [ "sops-install-secrets.service" ];
          };

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
