# niks3 binary-cache server. Selection is enablement; upload client and
# publication/backup behavior belong to the consumer. S3 coordinates and the
# public cache URL fail closed when unbound. Consumer requirement:
# sops-nix.nixosModules.sops and the upstream niks3 module.
_: {
  flake.modules.nixos.niks3-cache =
    { config, lib, ... }:
    let
      secretHelpers = import ../../lib/secrets.nix { inherit lib; };

      cfg = config.services.niks3-cache;
    in
    {
      options.services.niks3-cache = {
        s3 = {
          endpoint = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "S3-compatible endpoint host without protocol, e.g. an endpoint your provider publishes.";
          };

          bucket = lib.mkOption {
            type = lib.types.str;
            default = "nix-cache";
            description = "S3 bucket that stores the cache.";
          };

          region = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "S3 region override; empty lets the server infer it from the endpoint.";
          };

          useSSL = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether the server talks to the S3 endpoint over TLS.";
          };

          accessKeyFile = lib.mkOption {
            type = lib.types.str;
            default = "/run/secrets/niks3.s3_access_key_id";
            description = "Runtime path of the S3 access key file; materialized from `secretFiles.host`.";
          };

          secretKeyFile = lib.mkOption {
            type = lib.types.str;
            default = "/run/secrets/niks3.s3_secret_access_key";
            description = "Runtime path of the S3 secret key file; materialized from `secretFiles.host`.";
          };
        };

        signingKeyFile = lib.mkOption {
          type = lib.types.str;
          default = "/run/secrets/niks3.signing_key";
          description = "Runtime path of the cache signing key; materialized from `secretFiles.host`.";
        };

        signKeyFiles = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ config.services.niks3-cache.signingKeyFile ];
          defaultText = lib.literalExpression "[ config.services.niks3-cache.signingKeyFile ]";
          description = ''
            Signing keys the server publishes narinfo signatures with, in
            rotation order. Defaults to the single derived `signingKeyFile`;
            extra keys are listed here and registered by the consumer itself.
          '';
        };

        cacheUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Public read URL of this cache, as consumers will reference it.";
        };

        httpAddr = lib.mkOption {
          type = lib.types.str;
          default = "0.0.0.0:5751";
          description = "Address the cache server listens on.";
        };

        secretFiles = {
          host = secretHelpers.mkSecretFileOption "the host-scoped niks3 secrets (signing key and S3 credentials)";

          apiToken = secretHelpers.mkSecretFileOption "the niks3 push/GC API token";
        };

        secretKeys = {
          signingKey = lib.mkOption {
            type = lib.types.str;
            default = "signing_key";
            description = "SOPS key path of the cache signing key inside `secretFiles.host`.";
          };

          s3AccessKeyId = lib.mkOption {
            type = lib.types.str;
            default = "s3_access_key_id";
            description = "SOPS key path of the S3 access key id inside `secretFiles.host`.";
          };

          s3SecretAccessKey = lib.mkOption {
            type = lib.types.str;
            default = "s3_secret_access_key";
            description = "SOPS key path of the S3 secret access key inside `secretFiles.host`.";
          };

          apiToken = lib.mkOption {
            type = lib.types.str;
            default = "niks3/api_token";
            description = "SOPS key path of the API token inside `secretFiles.apiToken`.";
          };
        };

        apiTokenFile = lib.mkOption {
          type = lib.types.str;
          default = "/run/secrets/niks3.api_token";
          description = "Runtime path of the API token file; materialized from `secretFiles.apiToken`.";
        };

        oidc.providers = lib.mkOption {
          type = lib.types.attrsOf lib.types.unspecified;
          default = { };
          description = ''
            OIDC providers passed through to the upstream `services.niks3.oidc.providers`
            module option (typed there). CI federation lives here: e.g. a GitHub
            Actions provider bound to repository_owner, granting the write scope.
            Policy data — consumer-supplied.
          '';
        };
      };

      config = {
        assertions = [
          {
            assertion = cfg.s3.endpoint != null;
            message = "niks3-cache: services.niks3-cache.s3.endpoint must be set to the S3-compatible endpoint host (no protocol).";
          }
          {
            assertion = cfg.cacheUrl != null;
            message = "niks3-cache: services.niks3-cache.cacheUrl must be set to the public read URL of this cache.";
          }
          (secretHelpers.mkRequiredSecretAssertion {
            enable = true;
            file = cfg.secretFiles.host;
            feature = "niks3-cache";
            label = "secretFiles.host";
          })
          (secretHelpers.mkRequiredSecretAssertion {
            enable = true;
            file = cfg.secretFiles.apiToken;
            feature = "niks3-cache";
            label = "secretFiles.apiToken";
          })
        ];

        services.niks3 = {
          enable = true;
          inherit (cfg) httpAddr;

          database.createLocally = true;

          gc = {
            enable = true;
            olderThan = "720h";
            failedUploadsOlderThan = "6h";
            schedule = "daily";
            randomizedDelaySec = 1800;
          };

          s3 = {
            endpoint = cfg.s3.endpoint;
            bucket = cfg.s3.bucket;
            region = cfg.s3.region;
            useSSL = cfg.s3.useSSL;
            accessKeyFile = cfg.s3.accessKeyFile;
            secretKeyFile = cfg.s3.secretKeyFile;
          };

          inherit (cfg) cacheUrl;
          inherit (cfg) signKeyFiles;
          inherit (cfg) apiTokenFile;

          oidc.providers = cfg.oidc.providers;
        };

        # Each secret file is optional on its own: the assertions above are the
        # named failure surface, so registration is skipped rather than tripping
        # a raw type error on an unbound file.
        sops.secrets =
          lib.optionalAttrs (cfg.secretFiles.host != null) (
            secretHelpers.mkSecretsFromMap cfg.secretFiles.host {
              niks3_signing_key = {
                key = cfg.secretKeys.signingKey;
                path = cfg.signingKeyFile;
                owner = "niks3";
                group = "niks3";
              };
              niks3_s3_access_key_id = {
                key = cfg.secretKeys.s3AccessKeyId;
                path = cfg.s3.accessKeyFile;
                owner = "niks3";
                group = "niks3";
              };
              niks3_s3_secret_access_key = {
                key = cfg.secretKeys.s3SecretAccessKey;
                path = cfg.s3.secretKeyFile;
                owner = "niks3";
                group = "niks3";
              };
            }
          )
          // lib.optionalAttrs (cfg.secretFiles.apiToken != null) (
            secretHelpers.mkSecretsFromMap cfg.secretFiles.apiToken {
              niks3_api_token = {
                key = cfg.secretKeys.apiToken;
                path = cfg.apiTokenFile;
                owner = "niks3";
                group = "niks3";
              };
            }
          );

        systemd.services.niks3 = {
          after = lib.mkAfter [ "sops-nix.service" ];
          wants = lib.mkAfter [ "sops-nix.service" ];
        };
      };
    };
}
