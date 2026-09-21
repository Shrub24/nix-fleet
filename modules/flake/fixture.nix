# Fixture evaluation class: exercises every aspect on a throwaway NixOS target,
# consumer-shaped — imports the upstream modules aspects expect and binds
# obviously-fake placeholders. Never activated, never decrypts anything.
{ config, inputs, ... }:
let
  # Stand-in for a consumer's SOPS files: an existing YAML placeholder in the
  # flake source, so the existence gates and sops-nix's manifest validation
  # pass without committing any real secret material.
  fixtureSecretFile = ./. + "/fixture-secrets.yaml";

  # Placeholder age key path. sops-nix requires a configured key source and
  # rejects store paths for it; nothing here is ever activated, so this file
  # never has to exist.
  fixtureAgeKeyFile = "/run/secrets/fixture-age-key";

  aspects = config.flake.modules.nixos;
in
{
  configurations.nixos.fixture.module =
    { config, ... }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
        inputs.niks3.nixosModules.niks3
      ]
      ++ (with aspects; [
        beszel-agent
        builder-access
        niks3-cache
        niks3-publisher
        notification-daemon
        tailscale
      ]);

      nixpkgs.hostPlatform = "x86_64-linux";
      boot.loader.grub.enable = false;
      fileSystems."/" = {
        device = "nodev";
        fsType = "tmpfs";
      };
      system.stateVersion = "25.11";

      sops.age.keyFile = fixtureAgeKeyFile;

      # Non-vacuity guard: every aspect must show its contribution.
      assertions = [
        {
          assertion = config.services.beszel.agent.enable;
          message = "fixture: the beszel-agent aspect registered no agent; its secret-file gate did not fire.";
        }
        {
          assertion = config.services.tailscale.authKeyFile != null;
          message = "fixture: the tailscale aspect wired no auth key file.";
        }
        {
          assertion = config.services.niks3.enable && config.services.niks3.apiTokenFile != null;
          message = "fixture: the niks3-cache aspect did not configure the cache server.";
        }
        {
          assertion = config.programs.ssh.knownHosts != { };
          message = "fixture: the builder-access aspect registered no known host.";
        }
        {
          assertion = config.systemd.services.notification-daemon.serviceConfig.ExecStart != null;
          message = "fixture: the notification-daemon aspect deployed no daemon unit.";
        }
        {
          assertion = config.sops.secrets ? "notification-daemon/telegram_bot_token";
          message = "fixture: the notification-daemon aspect registered no Telegram token secret.";
        }
        {
          assertion =
            config.systemd.services.fixture-monitored.onFailure == [ "notify-event@fixture-monitored.service" ];
          message = "fixture: the notification aspect attached no native failure hook for a registered unit.";
        }
        {
          assertion = config.services.niks3-auto-upload.enable && config.nix.settings.post-build-hook != "";
          message = "fixture: the niks3-publisher aspect did not wire the upload client.";
        }
      ];

      # A real unit for the monitor namespace to hook.
      systemd.services.fixture-monitored.script = "true";

      services = {
        beszel-agent.secretFiles = {
          common = fixtureSecretFile;
          host = fixtureSecretFile;
        };

        builder-access.hosts.fixture-builder = {
          hostNames = [ "builder.invalid" ];
          # Placeholder key material: no real builder endpoint or host key
          # belongs in this repository.
          publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIxTuRe0000000000000000000000000000000000 fixture@invalid";
        };

        niks3-cache = {
          s3.endpoint = "s3.invalid";
          cacheUrl = "https://cache.invalid";
          secretFiles = {
            host = fixtureSecretFile;
            apiToken = fixtureSecretFile;
          };
        };

        niks3-publisher = {
          serverUrl = "http://cache.invalid:5751";
          secretFiles.apiToken = fixtureSecretFile;
        };

        notification-daemon = {
          secretFiles = {
            host = fixtureSecretFile;
            hostSystem = fixtureSecretFile;
          };

          telegram = {
            chatId = "-1000000000000";
            topics = {
              critical = "2";
              warning = "3";
              info = "4";
            };
          };

        };

        tailscale.secretFiles.auth = fixtureSecretFile;
      };

      # A unit owned by this module, registered on the notification contract:
      # failure severity defaulted, success pruned (a stop of a oneshot job is
      # not news). Severity defaults to "failure".
      services.notify-events.events.fixture-monitored.failure = { };
    };
}
