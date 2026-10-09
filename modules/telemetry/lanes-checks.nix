# Lane composition checks. `telemetry-lane-realization` owns what a lane
# composition renders for itself; `telemetry-capability-matrix` owns which units
# and pipelines a composition realizes, so no other leaf repeats that claim.
{
  lib,
  config,
  inputs,
  ...
}:
let
  hostFor =
    system: modules: values:
    (lib.nixosSystem {
      inherit system;
      modules = [
        inputs.sops-nix.nixosModules.sops
      ]
      ++ modules
      ++ [
        { services.telemetry = values; }
        { system.stateVersion = "25.11"; }
        # nixpkgs' own boot assertions are not the claim under test.
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "nodev";
            fsType = "tmpfs";
          };
        }
      ];
    }).config;
  accepts =
    host: (builtins.tryEval (lib.asserts.checkAssertWarn host.assertions host.warnings true)).success;
in
{
  perSystem =
    { system, ... }:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      inherit (import ../../lib/contract-leaf.nix { inherit lib pkgs; }) leaf;
      aspects = config.flake.modules.nixos;
      host = hostFor system;
      remoteWrite = {
        protocol = "prometheus-remote-write";
        endpoint = "https://metrics.invalid/api/v1/write";
        signals = [ "metrics" ];
      };
      vmagentHealthJob = {
        job_name = "vmagent-health";
        scrape_interval = "30s";
        metrics_path = "/metrics";
        scheme = "http";
        static_configs = [
          {
            targets = [ "127.0.0.1:8429" ];
            labels = {
              host = "nixos";
              instance = "nixos:vmagent";
            };
          }
        ];
      };
      logsLane = host [ aspects.telemetry-logs ] {
        journald = {
          includeUnits = [ "fixture-monitored" ];
          sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
        };
      };
      # A different loopback address is a different socket: the pair the gateway
      # binds (127.0.0.1 local, 127.0.0.2 ingress) has to stay legal, or
      # normalizing loopback aliases would over-reject a real gateway.
      distinctLoopback = host [ aspects.telemetry-otlp ] {
        otlp.signals = [ "traces" ];
        otlp.ingress.host = "127.0.0.2";
        destinations.traces = {
          protocol = "otlp-http";
          endpoint = "https://backend.invalid";
          signals = [ "traces" ];
        };
      };
      # Raw and already-bracketed IPv6 spellings must produce usable URLs and
      # socket addresses on both receivers, not merely pass admission.
      ipv6Host =
        spelling:
        host [ aspects.telemetry-otlp ] {
          otlp = {
            host = spelling;
            signals = [ "traces" ];
            ingress = {
              host = "fd00::2";
              httpPort = 4318;
              grpcPort = 4317;
            };
          };
          destinations.traces = {
            protocol = "otlp-http";
            endpoint = "https://backend.invalid";
            signals = [ "traces" ];
          };
        };
      contractOnlyDestination = host [ aspects.telemetry ] { destinations.metrics = remoteWrite; };
      producerOnly = host [
        ../../lib/telemetry-contract.nix
        aspects.node-exporter
      ] { };
      otelBoth =
        host
          [
            aspects.telemetry-otel-collector-scrape
            aspects.telemetry-otel-collector-otlp
          ]
          {
            scrape.app = {
              target = "127.0.0.1";
              port = 9187;
            };
            otlp.signals = [ "traces" ];
            destinations.metrics = remoteWrite;
            destinations.traces = {
              protocol = "otlp-http";
              endpoint = "https://traces.invalid";
              signals = [ "traces" ];
            };
          };
      noRegisteredSource = host [ aspects.telemetry-vmagent ] { destinations.metrics = remoteWrite; };
      admittedTraces = host [ aspects.telemetry-vmagent ] {
        otlp.signals = [ "traces" ];
        destinations.gateway = {
          protocol = "otlp-http";
          endpoint = "https://gateway.invalid";
          signals = [ "traces" ];
        };
      };
      journaldWithMetrics =
        host
          [
            aspects.telemetry-vector
            aspects.telemetry-vmagent
          ]
          {
            journald = {
              includeUnits = [ "fixture-monitored" ];
              sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
            };
            destinations.metrics = remoteWrite;
          };
      deliveryHealth = host [ aspects.telemetry-metrics ] {
        scrape.otel-collector-health = {
          target = "127.0.0.1";
          port = 9464;
        };
        destinations.metrics = remoteWrite;
      };
      otlpTraces = host [ aspects.telemetry-otlp ] {
        otlp.signals = [ "traces" ];
        destinations.plain = {
          protocol = "otlp-grpc";
          endpoint = "http://gateway.invalid:4317";
          signals = [ "traces" ];
        };
      };
    in
    {
      checks.telemetry-lane-realization = leaf "telemetry-lane-realization" [
        {
          message = "the logs-lane composition no longer accepts its sink and allowlist";
          ok = accepts logsLane;
        }
        {
          message = "a second, distinct loopback address no longer admits the ingress listener";
          ok = accepts distinctLoopback;
        }
        {
          message = "a gateway ingress added remote scraping or journald shipping to that host";
          ok =
            !(distinctLoopback.systemd.services ? vmagent)
            && !distinctLoopback.services.vector.enable
            && !(distinctLoopback.services.opentelemetry-collector.settings.receivers ? prometheus);
        }
        {
          message = "an IPv6 spelling no longer renders usable producer URLs and receiver sockets";
          ok =
            lib.all
              (
                spelling:
                let
                  config_ = ipv6Host spelling;
                  receivers = config_.services.opentelemetry-collector.settings.receivers;
                in
                accepts config_
                && config_.services.telemetry.otlp.httpUrl == "http://[::1]:4318"
                && config_.services.telemetry.otlp.grpcUrl == "http://[::1]:4317"
                && receivers.otlp.protocols.http.endpoint == "[::1]:4318"
                && receivers.otlp.protocols.grpc.endpoint == "[::1]:4317"
                && receivers."otlp/ingress".protocols.http.endpoint == "[fd00::2]:4318"
                && receivers."otlp/ingress".protocols.grpc.endpoint == "[fd00::2]:4317"
              )
              [
                "::1"
                "[::1]"
              ];
        }
      ];

      checks.telemetry-capability-matrix = leaf "telemetry-capability-matrix" [
        {
          message = "a contract-only destination started a runtime service";
          ok =
            !(contractOnlyDestination.systemd.services ? vmagent)
            && !(contractOnlyDestination.systemd.services ? vector)
            && !(contractOnlyDestination.systemd.services ? opentelemetry-collector);
        }
        {
          message = "a producer-only host is no longer accepted, or started a scrape or collector service";
          ok =
            accepts producerOnly
            && !(producerOnly.systemd.services ? vmagent)
            && !(producerOnly.systemd.services ? opentelemetry-collector);
        }
        {
          message = "the logs realization did not select Vector alone and publish its health scrape";
          ok =
            logsLane.services.vector.enable
            && builtins.hasAttr "vector-health" logsLane.services.telemetry.scrape
            && !logsLane.services.vmagent.enable
            && !logsLane.services.opentelemetry-collector.enable
            && !(logsLane.systemd.services ? vmagent)
            && !(logsLane.systemd.services ? opentelemetry-collector);
        }
        {
          message = "the two collector realizations no longer compose into one instance without a scraper";
          ok =
            otelBoth.services.opentelemetry-collector.enable
            &&
              builtins.attrNames otelBoth.services.opentelemetry-collector.settings.service.pipelines == [
                "metrics/scrape"
                "traces"
              ]
            && !(otelBoth.systemd.services ? vmagent);
        }
        {
          message = "a metrics destination with no registered scrape source no longer starts exactly vmagent and its own health job";
          ok =
            noRegisteredSource.services.vmagent.enable
            && noRegisteredSource.services.vmagent.prometheusConfig.scrape_configs == [ vmagentHealthJob ]
            && !noRegisteredSource.services.opentelemetry-collector.enable
            && !(noRegisteredSource.systemd.services ? opentelemetry-collector)
            && !noRegisteredSource.services.vector.enable;
        }
        {
          message = "an admitted OTLP trace signal no longer leaves the scrape provider alone on the host";
          ok =
            admittedTraces.services.vmagent.enable
            && admittedTraces.services.vmagent.prometheusConfig.scrape_configs == [ vmagentHealthJob ]
            && builtins.attrNames admittedTraces.services.telemetry.scrape == [ "vmagent-health" ]
            && !admittedTraces.services.opentelemetry-collector.enable
            && !(admittedTraces.systemd.services ? opentelemetry-collector)
            && !admittedTraces.services.vector.enable;
        }
        {
          message = "the combined logs and metrics composition no longer realizes both providers and its health path";
          ok =
            journaldWithMetrics.services.vector.settings.sources.internal_metrics.type == "internal_metrics"
            && journaldWithMetrics.services.vector.settings.sinks.vector-health.inputs == [ "internal_metrics" ]
            &&
              builtins.map (
                job: job.job_name
              ) journaldWithMetrics.services.vmagent.prometheusConfig.scrape_configs == [
                "vector-health"
                "vmagent-health"
              ]
            && !(journaldWithMetrics.services.telemetry.scrape ? app);
        }
        {
          message = "a registered delivery-health scrape no longer composes the scrape provider alone";
          ok =
            accepts deliveryHealth
            && deliveryHealth.services.vmagent.enable
            && !deliveryHealth.services.opentelemetry-collector.enable
            && !(deliveryHealth.systemd.services ? opentelemetry-collector)
            && !(deliveryHealth.services.notify.events ? opentelemetry-collector);
        }
        {
          message = "a traces-only composition no longer realizes the collector without the log shipper";
          ok =
            otlpTraces.services.opentelemetry-collector.enable
            && !otlpTraces.services.vmagent.enable
            && !otlpTraces.services.vector.enable
            && !(otlpTraces.systemd.services ? vmagent);
        }
        {
          message = "two scrape realizations were accepted together";
          ok =
            let
              both =
                host
                  [
                    aspects.telemetry-vmagent
                    aspects.telemetry-otel-collector-scrape
                  ]
                  {
                    scrape.app = {
                      target = "127.0.0.1";
                      port = 9187;
                    };
                    destinations.metrics = remoteWrite;
                  };
            in
            !(builtins.tryEval (
              builtins.deepSeq [
                both.services.telemetry.resolvedPipelines
                (lib.asserts.checkAssertWarn both.assertions both.warnings true)
              ] true
            )).success;
        }
      ];
    };
}
