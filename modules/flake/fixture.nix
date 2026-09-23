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

  # The v2 consumer wiring, exercised for real: a flake-level module closes
  # over this evaluation's merged config.fleet, resolves the profile through
  # the public API, and passes the projection into the NixOS module as args.
  # This is exactly the ~15-line pattern docs/contracts/builders.md prescribes.
  resolve = import ../../lib/build-profile.nix lib;
  resolvedProfile = resolve.resolveBuildProfile config.fleet "fixture";

  fixtureModule =
    {
      config,
      resolvedProfile,
      ...
    }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
        inputs.niks3.nixosModules.niks3
      ]
      ++ (with aspects; [
        beszel-agent
        build-account
        nix-baseline
        nix-gc
        niks3-cache
        niks3-publisher
        notify
        podman-prune
        ssh
        tailscale
        mosh
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
          message = "fixture: the fleet feature registered no known host.";
        }
        {
          assertion = config.nix.buildMachines != [ ];
          message = "fixture: the fleet feature scheduled no build machine.";
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
          assertion = config.systemd.services ? "nix-gc" || config.programs.nh.clean.enable;
          message = "fixture: the nix-gc aspect produced no cleanup unit.";
        }
        {
          assertion = config.systemd.services ? "podman-prune" && config.systemd.timers ? "podman-prune";
          message = "fixture: the podman-prune aspect produced no unit/timer.";
        }
        {
          assertion =
            (config.systemd.services."nix-gc".onFailure or [ ]) != [ ]
            || (config.systemd.services."nh-clean".onFailure or [ ]) != [ ];
          message = "fixture: the nix-gc aspect registered no failure event.";
        }
        {
          assertion =
            config.nix.settings.substituters or [ ] != [ ]
            && builtins.elem "https://cache.shrublab.xyz" (config.nix.settings.substituters or [ ]);
          message = "fixture: the nix-baseline aspect did not render the substitution catalog.";
        }
        {
          assertion =
            config.services.openssh.enable && !config.services.openssh.settings.PasswordAuthentication;
          message = "fixture: the ssh aspect did not render the hardened server baseline.";
        }
        {
          assertion = config.environment.etc ? "ssh/ssh_config.d/20-fleet-baseline.conf";
          message = "fixture: the ssh aspect did not render the client tuning fragment.";
        }
        {
          assertion = config.programs.mosh.enable;
          message = "fixture: the mosh aspect did not enable programs.mosh.";
        }
        {
          assertion = config.users.users ? "nixbuild" && config.users.users.nixbuild.isSystemUser;
          message = "fixture: the build-account aspect created no dispatch account.";
        }
        {
          assertion = config.systemd.services."podman-prune".onFailure or [ ] != [ ];
          message = "fixture: the podman-prune aspect registered no failure event.";
        }
      ];

      # A real unit for the notification contract to hook.
      systemd.services.fixture-monitored.script = "true";

      # The v2 consumer wiring, verbatim from docs/contracts/builders.md:
      # trust projection (exactly the profile's hosts) + scheduling from the
      # resolved specs. nixpkgs renders /etc/nix/machines from buildMachines.
      programs.ssh.knownHosts = resolve.knownHosts resolvedProfile;
      programs.ssh.extraConfig = resolve.sshConfig resolvedProfile;
      nix.distributedBuilds = true;
      nix.buildMachines = resolve.buildMachines resolvedProfile;

      services = {
        build-account.enable = true;
        nix-gc.enable = true;
        podman-prune.enable = true;
        nix-baseline.enable = true;
        ssh-baseline.enable = true;
        tailscale.enable = true;
      };

      services = {
        # KEY-only agent (no TOKEN wiring at all; the host file is the gate).
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
  # Fleet inventory additions at flake level: placeholder key material, no
  # real builder endpoint or host key belongs in this repository. The NixOS
  # fixture below consumes the fleet facts through the documented consumer
  # wiring (resolveBuildProfile -> nix.settings), exercising the same path
  # an external consumer runs.
  fleet = {
    hosts.fixture-host = {
      system = "x86_64-linux";
      tailscale.hostname = "fixture-host";
      hostNames = [ "fixture-host" ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIxTuRe0000000000000000000000000000000000 fixture@invalid";

      capabilities.nixBuilder = {
        enable = true;
        maxJobs = 2;
      };
    };

    externalBuilders.fixture-external = {
      uri = "ssh-ng://builder.invalid";
      systems = [ "aarch64-linux" ];
      publicHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureExternal0000000000000000000000 fixture@invalid";
    };

    buildProfiles.fixture = {
      hosts.fixture-host = { };
      external.fixture-external = { };
    };
  };

  configurations.nixos = lib.listToAttrs (
    lib.forEach config.systems (system: {
      name = "fixture-${builtins.replaceStrings [ "_" ] [ "-" ] system}";
      value.module = {
        imports = [
          fixtureModule
          {
            nixpkgs.hostPlatform = lib.mkForce system;
          }
        ];
        # Module arg wiring: the consumer's flake-level closure over its fleet
        # config, handed to the NixOS module (a NixOS module cannot read flake
        # config itself — that constraint shaped the whole v2 API).
        _module.args.resolvedProfile = resolvedProfile;
      };
    })
  );
}
