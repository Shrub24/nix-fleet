# niks3 closure-upload client (upstream post-build-hook module). Selection is
# enablement; the server is the niks3-cache aspect. serverUrl is provider
# policy: no default, fails closed. secretFiles.apiToken is the two-step
# sops bootstrap gate. Consumer requirement: sops-nix.nixosModules.sops.
{ inputs, ... }:
{
  flake.modules.nixos.niks3-publisher =
    { config, lib, ... }:
    let
      secretHelpers = import ../lib/secrets.nix { inherit lib; };

      cfg = config.services.niks3-publisher;

      tokenReady = cfg.secretFiles.apiToken != null && builtins.pathExists cfg.secretFiles.apiToken;
    in
    {
      imports = [ inputs.niks3.nixosModules.niks3-auto-upload ];

      options.services.niks3-publisher = {
        serverUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "URL of the niks3 server this host uploads closures to. Provider policy: consumer-supplied.";
        };

        authTokenFile = lib.mkOption {
          type = lib.types.str;
          default = "/run/secrets/niks3.api_token";
          description = "Runtime path of the push token; materialized from `secretFiles.apiToken`.";
        };

        socketPath = lib.mkOption {
          type = lib.types.str;
          default = "/run/niks3/upload-to-cache.sock";
          description = "Unix socket the root post-build hook sends store paths to.";
        };

        secretFiles.apiToken = secretHelpers.mkSecretFileOption "the niks3 push token";

        secretKeys.apiToken = lib.mkOption {
          type = lib.types.str;
          default = "niks3/api_token";
          description = "SOPS key path of the push token inside `secretFiles.apiToken`.";
        };
      };

      config = lib.mkMerge [
        {
          assertions = [
            {
              assertion = cfg.serverUrl != null;
              message = "niks3-publisher: services.niks3-publisher.serverUrl must be set to the niks3 server this host uploads closures to.";
            }
          ];
        }

        (lib.mkIf (cfg.serverUrl != null && tokenReady) {
          services.niks3-auto-upload = {
            enable = true;
            inherit (cfg) serverUrl authTokenFile socketPath;
          };

          sops.secrets.niks3_api_token = {
            sopsFile = cfg.secretFiles.apiToken;
            key = cfg.secretKeys.apiToken;
            path = cfg.authTokenFile;
            mode = "0400";
          };
        })
      ];
    };
}
