# Beszel agent authentication and enrollment. The hub stays consumer-side.
# secretFiles.host is the two-step sops bootstrap gate: until the host-scoped
# file exists, no agent, no secret, no template, and no notify registration is
# generated. The credential is the fleet-wide KEY (hub->agent SSH auth); TOKEN
# is the outbound WebSocket registration path, only read when HUB_URL is set,
# so it is rendered into the template only when a host declares one.
# Consumer requirement: sops-nix.nixosModules.sops (credentials arrive via a
# template).
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
          host = secretHelpers.mkSecretFileOption "a host-scoped secrets file gating enrollment; may carry beszel/token (optional) alongside other host secrets";
        };

        secretKeys = {
          common = secretHelpers.mkSecretKeyOption "beszel/key";
          # null disables the TOKEN path entirely (SSH-only agents).
          host = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = "beszel/token";
            description = "SOPS YAML key path for the optional host enrollment token; null omits TOKEN from the agent environment.";
          };
        };
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
            ''
            + lib.optionalString (cfg.secretKeys.host != null) ''
              TOKEN=${config.sops.placeholder.beszel_agent_token}
            '';
          };

          sops.secrets =
            secretHelpers.mkSecretsFromMap cfg.secretFiles.common {
              beszel_agent_key = {
                key = cfg.secretKeys.common;
                path = "/run/secrets/beszel.agent.key";
              };
            }
            // (
              if cfg.secretKeys.host != null then
                secretHelpers.mkSecretsFromMap cfg.secretFiles.host {
                  beszel_agent_token = {
                    key = cfg.secretKeys.host;
                    path = "/run/secrets/beszel.agent.token";
                  };
                }
              else
                { }
            );

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
