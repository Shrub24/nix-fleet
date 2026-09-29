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

  # A destination/fanout/secret mistake must fail closed by name at the
  # contract level (it must hold for any implementation), so the reject checks
  # force the rendered collector settings.
  telemetryRejects =
    module:
    let
      evaluated = lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          inputs.sops-nix.nixosModules.sops
          aspects.telemetry
          module
        ];
      };
    in
    !(builtins.tryEval (
      builtins.deepSeq evaluated.config.services.opentelemetry-collector.settings true
    )).success;
  telemetryMutationChecks =
    # a destination header referencing an unknown secret
    telemetryRejects {
      services.telemetry.destinations.bad = {
        protocol = "otlp-http";
        endpoint = "https://invalid.example";
        signals = [ "traces" ];
        headers.Authorization.secret = "absent";
      };
    }
    # secretFiles and secretKeys must pair
    && telemetryRejects {
      services.telemetry.secretFiles.token = fixtureSecretFile;
      services.telemetry.secretKeys.other = "otel/token";
    }
    # explicit fanout naming an unknown destination
    && telemetryRejects { services.telemetry.pipelines.traces = [ "absent" ]; }
    # a destination accepting a signal its protocol cannot carry
    && telemetryRejects {
      services.telemetry.destinations.metricsWire = {
        protocol = "prometheus-remote-write";
        endpoint = "http://metrics.invalid/api/v1/write";
        signals = [
          "metrics"
          "logs"
        ];
      };
    }
    # an explicit pipeline naming a destination for a signal it does not accept
    && telemetryRejects {
      services.telemetry.destinations.tracesOnly = {
        protocol = "otlp-http";
        endpoint = "https://langfuse.invalid";
        signals = [ "traces" ];
      };
      services.telemetry.pipelines.logs = [ "tracesOnly" ];
    }
    # an explicit empty fanout is a silent drop
    && telemetryRejects { services.telemetry.pipelines.logs = [ ]; }
    # a scrape source with no metrics destination to carry it
    && telemetryRejects {
      services.telemetry.scrape.app = {
        target = "127.0.0.1";
        port = 9100;
      };
    }
    # a scrape source whose only destination accepts traces, not metrics: the
    # traces-only default fanout must not be what carries scraped metrics
    && telemetryRejects {
      services.telemetry.scrape.app = {
        target = "127.0.0.1";
        port = 9100;
      };
      services.telemetry.destinations.tracesOnly = {
        protocol = "otlp-grpc";
        endpoint = "http://langfuse.invalid:4317";
        signals = [ "traces" ];
      };
    }
    # the resource processor is configured through resourceAttributes, not raw
    && telemetryRejects {
      services.telemetry.destinations.local = {
        protocol = "otlp-grpc";
        endpoint = "http://gateway.invalid:4317";
        signals = [ "traces" ];
      };
      services.otel-collector.resourceAttributes."host.name" = "fixture-host";
      services.otel-collector.processors.resource.attributes = [
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
        aspects.telemetry
        {
          services.telemetry.destinations.local = {
            protocol = "otlp-grpc";
            endpoint = "http://gateway.invalid:4317";
            signals = [ "traces" ];
          };
          services.otel-collector.processors.resource.attributes = [
            {
              key = "k";
              value = "v";
              action = "upsert";
            }
          ];
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
          aspects.telemetry
          {
            services.telemetry.destinations.plain = {
              protocol = "otlp-grpc";
              endpoint = "http://gateway.invalid:4317";
              signals = [ "traces" ];
            };
          }
        ];
      };
      collector = evaluated.config.services.opentelemetry-collector;
    in
    !(builtins.any (name: lib.hasPrefix "otel-collector/" name) (
      builtins.attrNames evaluated.config.sops.secrets
    ))
    && !(evaluated.config.sops.templates ? "otel-collector.env")
    && evaluated.config.systemd.services.opentelemetry-collector.serviceConfig.EnvironmentFile == [ ]
    && collector.settings.exporters ? "otlp/plain";

  # Source admission is unconditional: a registration is realized only on a
  # host that selects the aspect, and an orphan fails closed by name instead of
  # being silently accepted. A minimal host is evaluated through nixpkgs' own
  # assertion check so the named `telemetry:` failure is what a deployment
  # hits.
  admissionEval =
    modules:
    lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        inputs.sops-nix.nixosModules.sops
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "nodev";
            fsType = "tmpfs";
          };
          system.stateVersion = "25.11";
        }
      ]
      ++ modules;
    };
  admissionAccepts =
    modules:
    let
      evaluated = admissionEval modules;
    in
    (builtins.tryEval (
      lib.asserts.checkAssertWarn evaluated.config.assertions evaluated.config.warnings true
    )).success;
  admissionFailures =
    modules:
    map (assertion: assertion.message) (
      builtins.filter (assertion: !assertion.assertion) (admissionEval modules).config.assertions
    );
  # A push-only consumer registers nothing: it imports the fragment and reads
  # the local OTLP endpoint. The orphan guard sees no registration, so the
  # derived URL itself must fail closed — and the same read must succeed once
  # the host selects the aspect, or the check would pass vacuously.
  pushOnlyEndpoint =
    withAspect:
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        inputs.sops-nix.nixosModules.sops
      ]
      ++ lib.optionals withAspect [ aspects.telemetry ]
      ++ lib.optionals (!withAspect) [ ../telemetry/telemetry/_contract.nix ]
      ++ [
        ({ config, ... }: {
          environment.variables.OTEL_EXPORTER_OTLP_ENDPOINT = config.services.telemetry.otlp.httpUrl;
        })
      ];
    }).config.environment.variables.OTEL_EXPORTER_OTLP_ENDPOINT;
  telemetryAdmissionChecks =
    let
      pushOnlyWithAspect = builtins.tryEval (pushOnlyEndpoint true);
      pushOnlyWithoutAspect = builtins.tryEval (pushOnlyEndpoint false);
    in
    # the host aspect realizes a registered source (the destination must accept
    # metrics, or the scrape has nowhere to land)
    admissionAccepts [
      aspects.telemetry
      {
        services.telemetry.scrape.app = {
          target = "127.0.0.1";
          port = 9100;
        };
        services.telemetry.destinations.local = {
          protocol = "otlp-grpc";
          endpoint = "http://gateway.invalid:4317";
          signals = [ "metrics" ];
        };
      }
    ]
    # orphan: the fragment alone accepts no registration
    && !(admissionAccepts [
      ../telemetry/telemetry/_contract.nix
      {
        services.telemetry.scrape.app = {
          target = "127.0.0.1";
          port = 9100;
        };
      }
    ])
    # orphan: a destination written without the host aspect likewise
    && !(admissionAccepts [
      ../telemetry/telemetry/_contract.nix
      {
        services.telemetry.destinations.x = {
          protocol = "otlp-grpc";
          endpoint = "http://x.invalid:4317";
          signals = [ "traces" ];
        };
      }
    ])
    # the fragment alone with no registration is inert, not an error
    && admissionAccepts [ ../telemetry/telemetry/_contract.nix ]
    # a push-only consumer's endpoint read fails closed without the host aspect
    && !pushOnlyWithoutAspect.success
    && pushOnlyWithAspect.success
    && pushOnlyWithAspect.value == "http://127.0.0.1:4318";

  # The journald provider's own fail-closed checks: forcing the rendered Vector
  # settings is what a host build does, so a bad value must fail there by name.
  vectorRejects =
    telemetryConfig:
    let
      evaluated = lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          inputs.sops-nix.nixosModules.sops
          aspects.telemetry
          { services.telemetry = telemetryConfig; }
        ];
      };
    in
    !(builtins.tryEval (builtins.deepSeq evaluated.config.services.vector.settings true)).success;
  telemetryJournaldChecks =
    # shipping enabled with no endpoint: a journal with nowhere to go
    vectorRejects { journald.enable = true; }
    # a disk buffer under Vector's floor would be rejected at startup
    && vectorRejects {
      journald = {
        enable = true;
        sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
        buffer.maxSizeMb = 100;
      };
    }
    # an endpoint with no scheme is not dialable
    && !(admissionAccepts [
      aspects.telemetry
      {
        services.telemetry.journald = {
          enable = true;
          sink.endpoint = "victorialogs.invalid:9428/insert/jsonline";
        };
      }
    ])
    # an endpoint while shipping is off is a registration nothing realizes
    && !(admissionAccepts [
      aspects.telemetry
      { services.telemetry.journald.sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline"; }
    ])
    # the sink written without the host aspect is an orphan
    && !(admissionAccepts [
      ../telemetry/telemetry/_contract.nix
      {
        services.telemetry.journald = {
          enable = true;
          sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
        };
      }
    ]);
  # Selecting telemetry for metrics or traces must not start a log shipper.
  vectorDisabledWithoutJournald =
    (lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        inputs.sops-nix.nixosModules.sops
        aspects.telemetry
        {
          services.telemetry.destinations.plain = {
            protocol = "otlp-grpc";
            endpoint = "http://gateway.invalid:4317";
            signals = [ "traces" ];
          };
        }
      ];
    }).config.services.vector.enable;
  # The node-exporter aspect owns both ends of its scrape: it composes with the
  # host aspect, and alone it is an orphan registration that fails by name.
  nodeExporterAdmissionChecks =
    admissionAccepts [
      aspects.telemetry
      aspects.node-exporter
      {
        services.telemetry.destinations.victoria = {
          protocol = "prometheus-remote-write";
          endpoint = "http://metrics.invalid/api/v1/write";
          signals = [ "metrics" ];
        };
      }
    ]
    && !(admissionAccepts [ aspects.node-exporter ])
    &&
      builtins.any (lib.hasPrefix "telemetry: scrape source(s) node configured without")
        (admissionFailures [ aspects.node-exporter ]);
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
        node-exporter
        podman
        niks3-cache
        niks3-publisher
        notify
        ssh
        tailscale
        mosh
        telemetry
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
              telemetry = config.services.telemetry;
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
            && telemetry.destinations.secure.protocol == "otlp-http"
            && telemetry.destinations.secure.signals == [ "traces" ]
            &&
              telemetry.destinations.plain.signals == [
                "traces"
                "metrics"
                "logs"
              ]
            && telemetry.destinations.victoria.signals == [ "metrics" ]
            &&
              settings.service.pipelines.traces.exporters == [
                "otlp/plain"
                "otlphttp/secure"
              ]
            # A traces-only backend (the initial LLM-observability deployment)
            # receives neither metrics nor logs from the default fanout, and a
            # metrics-only remote-write backend receives nothing else.
            &&
              settings.service.pipelines.metrics.exporters == [
                "otlp/plain"
                "prometheusremotewrite/victoria"
              ]
            && settings.service.pipelines.logs.exporters == [ "otlp/plain" ]
            && !(builtins.elem "otlphttp/secure" settings.service.pipelines.metrics.exporters)
            && !(builtins.elem "otlphttp/secure" settings.service.pipelines.logs.exporters)
            && !(builtins.elem "prometheusremotewrite/victoria" settings.service.pipelines.traces.exporters)
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
              ]
            && telemetryMutationChecks;
          message = "fixture: the telemetry destination/fanout contract, the receiver bind, or the rendered exporter/processor set regressed.";
        }
        {
          # The host-local contract: the OTLP endpoint producers read must be
          # the receiver the collector actually binds, and both registrations
          # must merge into the metrics pipeline.
          assertion =
            let
              inherit (config.services.telemetry) otlp providers;
              settings = config.services.opentelemetry-collector.settings;
            in
            otlp.httpUrl == "http://127.0.0.1:4318"
            && otlp.grpcUrl == "http://127.0.0.1:4317"
            && settings.receivers.otlp.protocols.http.endpoint == "${otlp.host}:${toString otlp.httpPort}"
            && settings.receivers.otlp.protocols.grpc.endpoint == "${otlp.host}:${toString otlp.grpcPort}"
            &&
              settings.receivers.prometheus.config.scrape_configs == [
                {
                  job_name = "fixture-app";
                  metrics_path = "/metrics";
                  scheme = "http";
                  scrape_interval = "30s";
                  static_configs = [
                    {
                      targets = [ "127.0.0.1:9187" ];
                      labels.service = "fixture-app";
                    }
                  ];
                }
                {
                  job_name = "fixture-sidecar";
                  metrics_path = "/metrics";
                  scheme = "http";
                  scrape_interval = "15s";
                  static_configs = [
                    {
                      targets = [ "127.0.0.1:9101" ];
                      labels = { };
                    }
                  ];
                }
                {
                  # Contributed by the node-exporter aspect, which also owns
                  # the listener this target names.
                  job_name = "node";
                  metrics_path = "/metrics";
                  scheme = "http";
                  scrape_interval = "30s";
                  static_configs = [
                    {
                      targets = [ "127.0.0.1:9100" ];
                      labels = { };
                    }
                  ];
                }
              ]
            &&
              settings.service.pipelines.metrics.receivers == [
                "otlp"
                "prometheus"
              ]
            && settings.service.pipelines.traces.receivers == [ "otlp" ]
            && settings.service.pipelines.logs.receivers == [ "otlp" ]
            && providers.otlpIngest == "otel-collector"
            && providers.prometheusScrape == "otel-collector"
            && telemetryAdmissionChecks;
          message = "fixture: the telemetry scrape registration, local OTLP endpoint, provider selection, or orphan/admission contract regressed.";
        }
        {
          # The node-exporter aspect owns the exporter, the loopback bind and
          # its own scrape registration, so the target cannot drift from the
          # listener — and it stays off the firewall.
          assertion =
            let
              node = config.services.prometheus.exporters.node;
              unit = config.systemd.services."prometheus-node-exporter";
            in
            node.enable
            && node.listenAddress == "127.0.0.1"
            && node.port == 9100
            && !node.openFirewall
            && !(builtins.elem 9100 config.networking.firewall.allowedTCPPorts)
            && lib.hasInfix "--web.listen-address 127.0.0.1:9100" unit.serviceConfig.ExecStart
            && config.services.telemetry.scrape.node.target == "127.0.0.1"
            && config.services.telemetry.scrape.node.port == 9100
            && config.services.notify.events.prometheus-node-exporter.failure != null
            && unit.onFailure != [ ]
            && nodeExporterAdmissionChecks;
          message = "fixture: the node-exporter aspect's loopback bind, scrape registration, notify hook, or orphan behavior regressed.";
        }
        {
          # The journald logs path: a Vector journald source writing JSON lines
          # to the consumer's endpoint over a bounded disk buffer, alongside an
          # untouched collector pipeline — the same log record is not shipped
          # twice.
          assertion =
            let
              vector = config.services.vector;
              sink = vector.settings.sinks.logs;
              otel = config.services.opentelemetry-collector.settings;
            in
            config.services.telemetry.providers.journaldIngest == "vector"
            && vector.enable
            && vector.journaldAccess
            && vector.settings.data_dir == "/var/lib/vector"
            && vector.settings.sources.journald.type == "journald"
            && vector.settings.sources.journald.include_units == [ "fixture-monitored" ]
            && !(vector.settings.sources.journald ? exclude_units)
            && sink.type == "http"
            && sink.inputs == [ "journald" ]
            && sink.uri == "http://victorialogs.invalid:9428/insert/jsonline"
            && sink.encoding.codec == "json"
            && sink.framing.method == "newline_delimited"
            && sink.compression == "gzip"
            && sink.healthcheck.enabled == false
            && sink.request.headers."VL-Msg-Field" == "message"
            && sink.request.headers."VL-Time-Field" == "timestamp"
            && sink.request.headers."VL-Stream-Fields" == "_HOSTNAME,_SYSTEMD_UNIT"
            && sink.buffer.type == "disk"
            && sink.buffer.max_size == 512 * 1048576
            && sink.buffer.when_full == "block"
            && config.services.notify.events.vector.failure != null
            && config.systemd.services.vector.onFailure != [ ]
            && !vectorDisabledWithoutJournald
            && otel.service.pipelines.logs.exporters == [ "otlp/plain" ]
            && otel.service.pipelines.traces.receivers == [ "otlp" ]
            && telemetryJournaldChecks;
          message = "fixture: the journald log path (Vector journald source, JSON-line sink, disk buffer, notify) or its isolation from the collector pipelines regressed.";
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

        telemetry = {
          # The log path is opt-in and carries its own endpoint: the consumer
          # names the backend, the aspect names none.
          journald = {
            enable = true;
            includeUnits = [ "fixture-monitored" ];
            sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
          };
          scrape = {
            # A service's own metrics surface. Port 9187, deliberately not the
            # node exporter's 9100: that target belongs to the node-exporter
            # aspect's registration.
            fixture-app = {
              target = "127.0.0.1";
              port = 9187;
              labels.service = "fixture-app";
            };
            fixture-sidecar = {
              target = "127.0.0.1";
              port = 9101;
              interval = "15s";
            };
          };
          destinations = {
            # An LLM-observability sink (Langfuse/Latitude-style): traces only,
            # so the default fanout must never hand it metrics or logs.
            secure = {
              protocol = "otlp-http";
              endpoint = "https://telemetry.invalid";
              signals = [ "traces" ];
              headers.Authorization = {
                secret = "token";
                prefix = "Bearer ";
              };
            };
            plain = {
              protocol = "otlp-grpc";
              endpoint = "http://gateway.invalid:4317";
              signals = [
                "traces"
                "metrics"
                "logs"
              ];
            };
            victoria = {
              protocol = "prometheus-remote-write";
              endpoint = "http://metrics.invalid/api/v1/write";
              signals = [ "metrics" ];
            };
          };
          pipelines.logs = [ "plain" ];
          secretFiles.token = fixtureSecretFile;
          secretKeys.token = "otel/token";
        };

        otel-collector = {
          resourceAttributes."host.name" = "fixture-host";
          processors.attributes.actions = [
            {
              key = "fixture.attribute";
              action = "insert";
              value = "fixture";
            }
          ];
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
