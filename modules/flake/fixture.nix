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
  resolvedDocsMcp = config.flake.lib.serviceEndpoints.resolveEndpoint config.fleet {
    service = "docs-mcp";
    endpoint = "mcp";
    via = "tailnet";
  };

  collectorRejects =
    bindings:
    let
      evaluated = lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          inputs.sops-nix.nixosModules.sops
          aspects.otel-collector
          { services.otel-collector = bindings; }
        ];
      };
    in
    !(builtins.tryEval (
      builtins.deepSeq evaluated.config.services.opentelemetry-collector.settings true
    )).success;
  collectorMutationChecks =
    collectorRejects { exporters.missing.type = "otlp"; }
    && collectorRejects {
      exporters.invalid = {
        type = "otlphttp";
        endpoint = "https://invalid.example";
        headers.Authorization.secret = "absent";
      };
    }
    && collectorRejects {
      secretFiles.token = fixtureSecretFile;
      secretKeys.other = "otel/token";
    }
    && collectorRejects { pipelines.traces = [ "absent" ]; }
    && collectorRejects {
      exporters.metricsOnly = {
        type = "prometheusremotewrite";
        endpoint = "http://invalid.example";
      };
      pipelines.traces = [ "metricsOnly" ];
    }
    && collectorRejects { pipelines.logs = [ ]; }
    && collectorRejects {
      resourceAttributes."host.name" = "fixture-host";
      processors.resource.attributes = [
        {
          key = "k";
          value = "v";
          action = "upsert";
        }
      ];
    };
  # A resource processor declared directly (not via resourceAttributes) must
  # still reach the pipeline order, or the config would define a processor no
  # pipeline runs.
  collectorManualResourceOrder =
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        inputs.sops-nix.nixosModules.sops
        aspects.otel-collector
        {
          services.otel-collector = {
            exporters.debugOnly.type = "debug";
            processors.resource.attributes = [
              {
                key = "k";
                value = "v";
                action = "upsert";
              }
            ];
          };
        }
      ];
    }).config.services.opentelemetry-collector.settings.service.pipelines.traces.processors;
  # With no bound secret the aspect must register nothing: an unbound (or not
  # yet bootstrapped) file is the two-step SOPS path, not a broken config.
  collectorUnboundSecrets =
    let
      evaluated = lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          inputs.sops-nix.nixosModules.sops
          aspects.otel-collector
          { services.otel-collector.exporters.debugOnly.type = "debug"; }
        ];
      };
      collector = evaluated.config.services.opentelemetry-collector;
    in
    !(builtins.any (name: lib.hasPrefix "otel-collector/" name) (
      builtins.attrNames evaluated.config.sops.secrets
    ))
    && !(evaluated.config.sops.templates ? "otel-collector.env")
    && evaluated.config.systemd.services.opentelemetry-collector.serviceConfig.EnvironmentFile == [ ]
    && collector.settings.exporters ? "debug/debugOnly";

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
        podman
        niks3-cache
        niks3-publisher
        notify
        ssh
        tailscale
        mosh
        otel-collector
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
          assertion =
            config.services.beszel.agent.enable && config.services.beszel.agent.environment.KEY or "" != "";
          message = "fixture: the beszel-agent aspect registered no agent or no public KEY.";
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
          assertion =
            resolvedDocsMcp.url == "http://home-forge:6280/mcp"
            && resolvedDocsMcp.host == "home-forge"
            && resolvedDocsMcp.port == 6280;
          message = "fixture: the fleet service resolver lost the canonical docs-mcp route.";
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
          assertion =
            (config.systemd.services."nix-gc".onFailure or [ ]) != [ ]
            || (config.systemd.services."nh-clean".onFailure or [ ]) != [ ];
        }
        {
          # Ownership policy: an aspect that owns a unit registers its
          # failure. nix-baseline owns the daemon baseline (nix-daemon),
          # ssh owns the hardening (sshd) — both wired as drop-ins.
          assertion =
            (config.systemd.services."nix-daemon".onFailure or [ ]) != [ ]
            && (config.systemd.services.sshd.onFailure or [ ]) != [ ];
          message = "fixture: the nix-baseline/ssh aspects registered no failure hooks on their units.";
        }
        {
          assertion = config.services.tailscale.extraSetFlags == [ "--ssh" ];
          message = "fixture: tailscale --ssh default regressed.";
        }
        {
          # The guard must cover the unit nixpkgs actually creates — including
          # a container that renamed it.
          assertion =
            config.systemd.services."podman-fixture-container".startLimitIntervalSec == 3600
            && config.systemd.services."podman-fixture-container".startLimitBurst == 5
            && config.systemd.services."fixture-custom-name".startLimitIntervalSec == 3600;
          message = "fixture: the podman-baseline guard did not cover the container units.";
        }
        {
          # Prune defaults: weekly (nixpkgs' own), --volumes deliberately not
          # defaulted, and a consumer's scalar override wins over mkDefault.
          assertion =
            config.virtualisation.podman.autoPrune.enable
            && !(builtins.elem "--volumes" config.virtualisation.podman.autoPrune.flags)
            && config.virtualisation.podman.autoPrune.dates == "daily";
          message = "fixture: the podman prune defaults regressed.";
        }
        {
          assertion = config.services.notify.events ? "podman-prune";
          message = "fixture: the podman aspect registered no prune failure event.";
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
          assertion =
            let
              collector = config.services.opentelemetry-collector;
              inherit (collector) settings;
            in
            collector.enable
            && settings.receivers.otlp.protocols.grpc.endpoint == "127.0.0.1:4317"
            && settings.receivers.otlp.protocols.http.endpoint == "127.0.0.1:4318"
            && settings.exporters."otlphttp/secure".headers.Authorization == "Bearer \${env:OTELCOL_token}"
            && settings.exporters."otlp/plain".tls.insecure
            &&
              settings.exporters."prometheusremotewrite/victoria".endpoint
              == "http://metrics.invalid/api/v1/write"
            &&
              settings.service.pipelines.traces.exporters == [
                "otlp/plain"
                "otlphttp/secure"
              ]
            &&
              settings.service.pipelines.metrics.exporters == [
                "otlp/plain"
                "otlphttp/secure"
                "prometheusremotewrite/victoria"
              ]
            && settings.service.pipelines.logs.exporters == [ "otlphttp/secure" ]
            &&
              settings.service.pipelines.traces.processors == [
                "memory_limiter"
                "resource"
                "batch"
                "attributes"
              ]
            &&
              settings.processors.resource.attributes == [
                {
                  key = "host.name";
                  value = "fixture-host";
                  action = "upsert";
                }
              ];
          message = "fixture: the otel-collector receiver, exporter, or pipeline contract regressed.";
        }
        {
          assertion =
            config.services.notify.events.opentelemetry-collector.failure != null
            && config.systemd.services.opentelemetry-collector.onFailure != [ ]
            && config.sops.secrets."otel-collector/token".sopsFile == fixtureSecretFile
            && config.sops.secrets."otel-collector/token".key == "otel/token"
            &&
              builtins.elem "opentelemetry-collector.service"
                config.sops.templates."otel-collector.env".restartUnits
            &&
              builtins.elem "opentelemetry-collector.service"
                config.sops.secrets."otel-collector/token".restartUnits
            &&
              config.sops.templates."otel-collector.env".content
              == "OTELCOL_token=${config.sops.placeholder."otel-collector/token"}\n"
            &&
              config.systemd.services.opentelemetry-collector.serviceConfig.EnvironmentFile == [
                config.sops.templates."otel-collector.env".path
              ]
            && collectorMutationChecks
            &&
              collectorManualResourceOrder == [
                "memory_limiter"
                "resource"
                "batch"
              ]
            && collectorUnboundSecrets;
          message = "fixture: the otel-collector SOPS, notify, or fail-closed contract regressed.";
        }
        {
          assertion = config.users.users ? "nixbuild" && config.users.users.nixbuild.isSystemUser;
          message = "fixture: the build-account aspect created no dispatch account.";
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

      # Consumer-side override wins over the aspect's mkDefault.
      virtualisation.podman.autoPrune.dates = "daily";

      # Two containers exercise the guard: the default unit name and a renamed
      # one (nixpkgs names units from `serviceName`).
      virtualisation.oci-containers.containers = {
        fixture-container.image = "docker.io/library/hello-world:latest";
        fixture-renamed = {
          image = "docker.io/library/hello-world:latest";
          serviceName = "fixture-custom-name";
        };
      };

      services = {
        # The KEY is the hub's public half — policy, not a secret.
        beszel-agent = {
          key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE1AAAAIfixtureplaceholderpublickeybody0000 fixture";
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

        otel-collector = {
          resourceAttributes."host.name" = "fixture-host";
          processors.attributes.actions = [
            {
              key = "fixture.attribute";
              action = "insert";
              value = "fixture";
            }
          ];
          secretFiles.token = fixtureSecretFile;
          secretKeys.token = "otel/token";
          exporters = {
            secure = {
              type = "otlphttp";
              endpoint = "https://telemetry.invalid";
              headers.Authorization = {
                secret = "token";
                prefix = "Bearer ";
              };
            };
            plain = {
              type = "otlp";
              endpoint = "http://gateway.invalid:4317";
            };
            victoria = {
              type = "prometheusremotewrite";
              endpoint = "http://metrics.invalid/api/v1/write";
            };
          };
          pipelines.logs = [ "secure" ];
        };
      };

      # A unit owned by this module, registered on the notification contract:
      # failure severity defaulted, success pruned (a stop of a oneshot job is
      # not news). Severity defaults to "failure".
      services.notify.events.fixture-monitored = {
        failure = { };
        success = { };
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
