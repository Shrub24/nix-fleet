# Aspect: beszel-agent — Beszel agent authentication and enrollment (OPS-8).
#
# Extracted from nix-homelab's `observability-agent` aspect. The agent enrols
# itself once the host-scoped SOPS file exists, which preserves the two-step
# sops bootstrap: binding `secretFiles.host` is the operator's second step, and
# until then no agent, no secret, and no template is registered. The Beszel hub
# stays a consumer-side admin service; this aspect owns the agent only.
#
# Consumer requirement: import `sops-nix.nixosModules.sops` (agent credentials
# are delivered through a sops template), because this aspect writes
# `sops.secrets`/`sops.templates`.
_: {
  flake.modules.nixos.beszel-agent =
    { config, lib, ... }:
    let
      secretHelpers = import ../lib/secrets.nix { inherit lib; };

      cfg = config.services.beszel-agent;

      # Two-step bootstrap predicate: enrollment only exists once the host-scoped
      # SOPS file the consumer bound is actually present.
      enrolled = cfg.secretFiles.host != null && builtins.pathExists cfg.secretFiles.host;
    in
    {
      options.services.beszel-agent = {
        secretFiles = {
          common = secretHelpers.mkSecretFileOption "the fleet-wide Beszel agent key";

          host = secretHelpers.mkSecretFileOption "the host-scoped Beszel agent enrollment token";
        };

        secretKeys = {
          common = lib.mkOption {
            type = lib.types.str;
            default = "beszel/key";
            description = "SOPS key path of the agent key inside `secretFiles.common`.";
          };

          host = lib.mkOption {
            type = lib.types.str;
            default = "beszel/token";
            description = "SOPS key path of the enrollment token inside `secretFiles.host`.";
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

        # Wiring stays gated on both secret files so a half-bound contract fails
        # through the named assertion above instead of a raw type error.
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
