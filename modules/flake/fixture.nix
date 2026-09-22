# Fixture evaluation class: exercises every aspect on throwaway NixOS targets,
# consumer-shaped — imports the upstream modules aspects expect and binds
# obviously-fake placeholders. Never activated, never decrypts anything. One
# fixture per declared system: the wiring module builds each toplevel as a
# check, so platform-specific packaging (python3, apprise) is exercised for
# every architecture the fleet actually runs.
{
  lib,
  config,
  inputs,
  ...
}:
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

  fixtureModule =
    { config, ... }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
        inputs.niks3.nixosModules.niks3
      ]
      ++ (with aspects; [
        beszel-agent
        fleet-builders
        nh-gc
        niks3-cache
        niks3-publisher
        notify
        podman-prune
        tailscale
      ]);

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
          message = "fixture: the fleet-builders aspect registered no known host.";
        }
        {
          assertion = config.nix.buildMachines != [ ];
          message = "fixture: the fleet-builders aspect scheduled no build machine.";
        }
        {
          assertion = config.systemd.services.notify.serviceConfig.ExecStart != null;
          message = "fixture: the notify aspect deployed no daemon unit.";
        }
        {
          assertion = config.sops.secrets ? "notify/telegram_bot_token";
          message = "fixture: the notify aspect registered no Telegram token secret.";
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
        {
          assertion = config.systemd.services ? "nh-clean";
          message = "fixture: the nh-gc aspect produced no nh-clean unit.";
        }
        {
          assertion = config.systemd.services ? "podman-prune" && config.systemd.timers ? "podman-prune";
          message = "fixture: the podman-prune aspect produced no unit/timer.";
        }
        {
          assertion = config.systemd.services."nh-clean".onFailure or [ ] != [ ];
          message = "fixture: the nh-gc aspect registered no failure event for nh-clean.";
        }
        {
          assertion = config.systemd.services."podman-prune".onFailure or [ ] != [ ];
          message = "fixture: the podman-prune aspect registered no failure event.";
        }
      ];

      # A real unit for the notification contract to hook.
      systemd.services.fixture-monitored.script = "true";

      services.fleet-builders.activeSet = "default";

      services = {
        nh-gc.enable = true;
        podman-prune.enable = true;
      };

      services = {
        beszel-agent.secretFiles = {
          common = fixtureSecretFile;
          host = fixtureSecretFile;
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

        notify = {
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
      services.notify.events.fixture-monitored = {
        failure = { };
        success = { };
      };

      # A unit that exists only as a package-provided file (nixpkgs symlinks it
      # via systemd.packages); option-level config carries no ExecStart.
      services.notify.events.nix-daemon = {
        fromPackage = true;
        failure = { };
      };
    };
in
{
  # Fleet registry inventory at flake level: placeholder key material, no
  # real builder endpoint or host key belongs in this repository. The NixOS
  # fixture below only selects; a NixOS module cannot read flake-level data,
  # which is the whole point of the constructed builders aspect.
  fleet = {
    hosts.fixture-host = {
      tailscale.hostname = "fixture-host";
      hostNames = [ "fixture-host" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIxTuRe0000000000000000000000000000000000 fixture@invalid";
    };
    builders.fixture-builder = {
      host = "fixture-host";
      systems = [ "x86_64-linux" ];
      maxJobs = 2;
    };
    builders.fixture-external = {
      uri = "ssh-ng://builder.invalid";
      systems = [ "aarch64-linux" ];
      publicHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureExternal0000000000000000000000 fixture@invalid";
    };
    builderSets.default = [
      "fixture-builder"
      "fixture-external"
    ];
  };

  configurations.nixos = lib.listToAttrs (
    lib.forEach config.systems (system: {
      name = "fixture-${builtins.replaceStrings [ "_" ] [ "-" ] system}";
      value.module.imports = [
        fixtureModule
        {
          nixpkgs.hostPlatform = lib.mkForce system;
        }
      ];
    })
  );
}
