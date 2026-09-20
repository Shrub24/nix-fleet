# Beszel agent authentication and enrollment. The hub stays consumer-side.
# secretFiles.host is the two-step sops bootstrap gate: until the host-scoped
# file exists, no agent, no secret, and no template is registered. Consumer
# requirement: sops-nix.nixosModules.sops (credentials arrive via a template).
{
  flake.modules.nixos.beszel-agent =
    { config, lib, ... }:
    let
      secretHelpers = import ../lib/secrets.nix { inherit lib; };

      cfg = config.services.beszel-agent;

      enrolled = cfg.secretFiles.host != null && builtins.pathExists cfg.secretFiles.host;
    in
    {
      options.services.beszel-agent = {
        secretFiles = {
          common = secretHelpers.mkSecretFileOption "the fleet-wide Beszel agent key";
          host = secretHelpers.mkSecretFileOption "the host-scoped Beszel agent enrollment token";
        };

        secretKeys = {
          common = secretHelpers.mkSecretKeyOption "beszel/key";
          host = secretHelpers.mkSecretKeyOption "beszel/token";
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
            // secretHelpers.mkSecretsFromMap cfg.secretFiles.host {
              beszel_agent_token = {
                key = cfg.secretKeys.host;
                path = "/run/secrets/beszel.agent.token";
              };
            };

          services.beszel.agent = {
            enable = true;
            environmentFile = config.sops.templates."beszel-agent.env".path;
          };
        })
      ];
    };
}
