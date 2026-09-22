# Beszel agent authentication and enrollment. The hub stays consumer-side.
# secretFiles.host is the two-step sops bootstrap gate: until the host-scoped
# file exists, no agent, no secret, no template, and no notify registration is
# generated. The credential is the fleet-wide KEY (hub->agent SSH auth). TOKEN
# (the WebSocket registration path) is deliberately not wired: WebSocket mode
# needs plain HTTP reachability of the hub URL, but the hub sits behind
# Cloudflare Access and agents reach it over tailnet SSH — no HUB_URL, no
# TOKEN. Consumer requirement: sops-nix.nixosModules.sops (credentials arrive
# via a template).
{
  flake.modules.nixos.beszel-agent =
    { config, lib, ... }:
    let
      secretHelpers = import ../../lib/secrets.nix { inherit lib; };

      cfg = config.services.beszel-agent;

      enrolled = cfg.secretFiles.host != null && builtins.pathExists cfg.secretFiles.host;
    in
    {
      # Registration is unconditional in the class: the shared fragment declares
      # the namespace, and the notify aspect realizes it only when co-selected —
      # the same idiom nh-gc uses for its own unit. The gate still applies: a
      # host with no host-scoped secret file generates neither agent nor event.
      imports = [ ../notifications/notify/_notify-events.nix ];

      options.services.beszel-agent = {
        secretFiles = {
          common = secretHelpers.mkSecretFileOption "the fleet-wide Beszel agent key";
          host = secretHelpers.mkSecretFileOption "a host-scoped secrets file gating enrollment";
        };

        secretKeys.common = secretHelpers.mkSecretKeyOption "beszel/key";
      };

      config = lib.mkMerge [
        {
          assertions = [
            (secretHelpers.mkRequiredSecretAssertion {
              enable = enrolled;
              file = cfg.secretFiles.common;
              feature = "beszel-agent";
              label = "secretFiles.common";
            })
          ];
        }

        (lib.mkIf (enrolled && cfg.secretFiles.common != null) {
          sops.templates."beszel-agent.env" = {
            owner = "root";
            group = "root";
            mode = "0400";
            content = ''
              KEY=${config.sops.placeholder.beszel_agent_key}
            '';
          };

          sops.secrets = secretHelpers.mkSecretsFromMap cfg.secretFiles.common {
            beszel_agent_key = {
              key = cfg.secretKeys.common;
              path = "/run/secrets/beszel.agent.key";
            };
          };

          services.beszel.agent = {
            enable = true;
            environmentFile = config.sops.templates."beszel-agent.env".path;
          };
        })

        # The aspect owns the unit it creates, so it owns the failure
        # registration: gated on the same enrollment predicate, because a unit
        # that does not exist must not be registered.
        (lib.mkIf enrolled {
          services.notify.events."beszel-agent".failure = { };
        })
      ];
    };
}
