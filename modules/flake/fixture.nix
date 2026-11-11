# Fixture evaluation class: every aspect on throwaway NixOS targets with fake
# placeholders. Never activated, never decrypts anything. One fixture per
# declared system, each toplevel built as a check.
{
  lib,
  config,
  inputs,
  ...
}:
let
  fixtureSecretFile = ./. + "/fixture-secrets.yaml";
  # sops-nix rejects store paths as a key source and nothing here is activated.
  fixtureAgeKeyFile = "/run/secrets/fixture-age-key";
  fixtureNixosSystem =
    args:
    lib.nixosSystem (
      args
      // {
        modules = [ { system.stateVersion = "25.11"; } ] ++ args.modules;
      }
    );

  aspects = config.flake.modules.nixos;

  # The consumer wiring docs/contracts/builders.md prescribes, exercised for real.
  resolve = import ../../lib/build-profile.nix lib;
  resolvedProfile = resolve.resolveBuildProfile config.fleet "fixture";

  # Hosts for the throwaway evaluations, parameterized by the checking system.
  telemetryHostFor =
    system: imports: telemetryConfig:
    (fixtureNixosSystem {
      inherit system;
      modules = [
        inputs.sops-nix.nixosModules.sops
      ]
      ++ imports
      ++ [ { services.telemetry = telemetryConfig; } ];
    }).config;
  vmagentHostFor =
    system: telemetryConfig: telemetryHostFor system [ aspects.telemetry-vmagent ] telemetryConfig;

  # From the unit's own rendered ExecStartPre, so the check runs the artifact
  # that ships.
  guardScriptFor =
    system:
    let
      pre =
        (vmagentHostFor system {
          scrape.app = {
            target = "127.0.0.1";
            port = 9187;
          };
          destinations.metrics = {
            protocol = "prometheus-remote-write";
            endpoint = "https://metrics.invalid/api/v1/write";
            signals = [ "metrics" ];
            headers.Authorization = {
              secret = "token";
              prefix = "Bearer ";
            };
          };
          secretFiles.token = fixtureSecretFile;
          secretKeys.token = "fixture/token";
        }).systemd.services.vmagent.serviceConfig.ExecStartPre;
    in
    lib.head (lib.splitString " " (lib.head pre));

  fixtureModule =
    {
      config,
      resolvedProfile,
      ...
    }:
    {
      imports = [
        inputs.sops-nix.nixosModules.sops
      ]
      ++ (with aspects; [
        alertmanager
        bifrost
        build-account
        nix-baseline
        sops-systemd-activation
        nix-gc
        node-exporter
        podman
        notify
        ssh
        mosh
        telemetry
        telemetry-metrics
        telemetry-logs
        telemetry-otlp
        telemetry-vector
        telemetry-vmagent
        telemetry-otel-collector-otlp
        vmalert
      ]);

      boot.loader.grub.enable = false;
      fileSystems."/" = {
        device = "nodev";
        fsType = "tmpfs";
      };
      system.stateVersion = "25.11";

      # The host's own name, which the canonical telemetry identity defaults
      # to. The fixture's fleet record names this host the same way, so the
      # rendered identity label, the instance labels and the explicit
      # collector resource attribute all agree rather than contradicting each
      # other.
      networking.hostName = "fixture-host";

      sops.age.keyFile = fixtureAgeKeyFile;

      # Cross-aspect joins only: what no single aspect owns and plain option
      # evaluation cannot falsify.
      assertions = [
        {
          assertion =
            config.systemd.services.fixture-monitored.onFailure == [ "notify-event@fixture-monitored.service" ];
          message = "fixture: a registered unit got no native failure hook.";
        }
        {
          # The guard must cover the units nixpkgs actually creates, renamed ones
          # included.
          assertion =
            config.systemd.services."podman-fixture-container".startLimitIntervalSec == 3600
            && config.systemd.services."podman-fixture-container".startLimitBurst == 5
            && config.systemd.services."fixture-custom-name".startLimitIntervalSec == 3600;
          message = "fixture: the podman-baseline guard did not cover the container units.";
        }
        {
          assertion =
            let
              node = config.services.prometheus.exporters.node;
            in
            config.services.telemetry.scrape.node.target == node.listenAddress
            && config.services.telemetry.scrape.node.port == node.port
            && !(builtins.elem node.port config.networking.firewall.allowedTCPPorts);
          message = "fixture: the scrape registration no longer tracks the exporter bind.";
        }
        {
          # The log sink carries journal records, the health exporter Vector's own.
          assertion =
            let
              sinks = config.services.vector.settings.sinks;
              transforms = config.services.vector.settings.transforms;
            in
            sinks.logs.inputs == [ "journald-correlation" ]
            && transforms."journald-correlation".inputs == [ "journald-identity" ]
            && transforms."journald-identity".inputs == [ "journald" ]
            && sinks.vector-health.inputs == [ "internal_metrics" ];
          message = "fixture: a Vector sink took the other lane's inputs.";
        }
        {
          # Producers stay loopback while the declared ingress binds its own.
          assertion =
            let
              otlp = config.services.telemetry.otlp;
              settings = config.services.opentelemetry-collector.settings;
            in
            lib.hasPrefix "http://127.0.0.1:" otlp.httpUrl
            && lib.hasPrefix "${otlp.ingress.host}:" settings.receivers."otlp/ingress".protocols.http.endpoint
            && settings.receivers.otlp.protocols.http.endpoint == "${otlp.host}:${toString otlp.httpPort}";
          message = "fixture: the loopback/ingress endpoint split regressed.";
        }
      ];

      systemd.services.fixture-monitored.script = "true";

      # The consumer wiring docs/contracts/builders.md prescribes, verbatim.
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
        notify = {
          secretFiles = {
            host = fixtureSecretFile;
            hostSystem = fixtureSecretFile;
          };
          telegram = {
            chatId = "-1000000000000";
            topics.infra = "2";
            defaultTopic = "infra";
          };
          ntfy = {
            enable = true;
            serverUrl = "http://127.0.0.1:8082";
            topics.infra = "infra";
            defaultTopic = "infra";
          };
        };

        telemetry = {
          otlp = {
            signals = [
              "traces"
              "metrics"
              "logs"
            ];
            ingress.host = "100.64.0.9";
          };
          journald = {
            enable = true;
            includeUnits = [ "fixture-monitored" ];
            sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
          };
          destinations = {
            secure = {
              protocol = "otlp-http";
              endpoint = "https://telemetry.invalid";
              signals = [
                "traces"
                "logs"
              ];
              headers.Authorization = {
                secret = "token";
                prefix = "Bearer ";
              };
            };
            archive = {
              protocol = "prometheus-remote-write";
              endpoint = "https://archive.invalid/api/v1/write";
              signals = [ "metrics" ];
              headers.Authorization = {
                secret = "metricsToken";
                prefix = "Bearer ";
              };
            };
          };
          pipelines.metrics = [ "archive" ];
          secretFiles.token = fixtureSecretFile;
          secretKeys.token = "otel/token";
          secretFiles.metricsToken = fixtureSecretFile;
          secretKeys.metricsToken = "metrics/token";
        };
      };

      # Registered on the notification contract: failure defaulted, success pruned.
      services.notify.events.fixture-monitored = {
        failure = { };
      };

    };
in
{
  # Placeholder inventory: no real endpoint or host key belongs in this repo.
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
        # A NixOS module cannot read flake config, so the closure is passed in.
        _module.args.resolvedProfile = resolvedProfile;
      };
    })
  );

  # The only thing between a secret's contents and vmagent's argument parsing.
  perSystem =
    { system, ... }:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system};

    in
    {
      checks = {
        vmagent-secret-guard =
          pkgs.runCommand "vmagent-secret-guard-check"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.gnugrep
              ];
            }
            ''
              set -euo pipefail
              guard=${guardScriptFor system}

              refuse() {
                if VMAGENT_probe="$1" "$guard" VMAGENT_probe 2>refusal.txt; then
                  echo "vmagent-secret-guard: accepted a value that changes argument parsing ($2)" >&2
                  exit 1
                fi
                grep -q "refusing to start" refusal.txt || {
                  echo "vmagent-secret-guard: refusal for $2 was not the named error" >&2
                  cat refusal.txt >&2
                  exit 1
                }
              }
              accept() {
                VMAGENT_probe="$1" "$guard" VMAGENT_probe || {
                  echo "vmagent-secret-guard: rejected a representable value ($2)" >&2
                  exit 1
                }
              }

              # A comma is the leak this guard exists for: it adds an array
              # element, so the next destination receives this one's arguments.
              refuse 'PRIMARY,X-Probe: LEAKED' 'comma'
              refuse 'a]b' 'closing bracket'
              refuse "q'w" 'single quote'
              refuse $'e\nf' 'embedded newline'

              accept 'sk-abc123DEF' 'opaque token'
              accept 'AbC0._~-+/=' 'base64url and padding'
              accept "" 'empty'

              touch $out
            '';
      };
    };
}
