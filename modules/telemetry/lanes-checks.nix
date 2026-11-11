# Lane composition: which providers a composition realizes, what each renders
# for itself, and the two spellings/aliases admission must still accept.
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
  # The units a composition actually starts: the realization claim, not the
  # option that requested it.
  providers =
    host:
    builtins.filter (unit: host.systemd.services ? ${unit}) [
      "opentelemetry-collector"
      "vector"
      "vmagent"
    ];
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
      tracesDestination = {
        protocol = "otlp-http";
        endpoint = "https://traces.invalid";
        signals = [ "traces" ];
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
      journald = {
        includeUnits = [ "fixture-monitored" ];
        sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
      };
      logsLane = host [ aspects.telemetry-logs ] { inherit journald; };
      # A different loopback address is a different socket: normalizing loopback
      # aliases would over-reject a real gateway.
      distinctLoopback = host [ aspects.telemetry-otlp ] {
        otlp.signals = [ "traces" ];
        otlp.ingress.host = "127.0.0.2";
        destinations.traces = tracesDestination;
      };
      # Raw and already-bracketed IPv6 spellings must produce usable URLs and
      # socket addresses, not merely pass admission.
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
          destinations.traces = tracesDestination;
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
            destinations.traces = tracesDestination;
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
            inherit journald;
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
      # Each composition and the providers it must realize. A composition that
      # selects a contract-only declaration starts nothing.
      matrix = [
        {
          composition = "contract-only destination";
          host = contractOnlyDestination;
          expect = [ ];
        }
        {
          composition = "producer only";
          host = producerOnly;
          expect = [ ];
        }
        {
          # The ingress listener is a collector receiver, so the collector is the
          # only provider a gateway binds.
          composition = "gateway ingress";
          host = distinctLoopback;
          expect = [ "opentelemetry-collector" ];
        }
        {
          composition = "logs lane";
          host = logsLane;
          expect = [ "vector" ];
        }
        {
          composition = "both collector realizations";
          host = otelBoth;
          expect = [ "opentelemetry-collector" ];
        }
        {
          composition = "metrics with no registered source";
          host = noRegisteredSource;
          expect = [ "vmagent" ];
        }
        {
          composition = "admitted traces beside a scrape provider";
          host = admittedTraces;
          expect = [ "vmagent" ];
        }
        {
          composition = "logs and metrics";
          host = journaldWithMetrics;
          expect = [
            "vector"
            "vmagent"
          ];
        }
        {
          composition = "delivery-health scrape";
          host = deliveryHealth;
          expect = [ "vmagent" ];
        }
        {
          composition = "traces only";
          host = otlpTraces;
          expect = [ "opentelemetry-collector" ];
        }
      ];
      mismatches = builtins.filter (entry: providers entry.host != entry.expect) matrix;
    in
    {
      checks.telemetry-lane-realization = leaf "telemetry-lane-realization" [
        {
          message = "the logs lane no longer accepts its sink and allowlist, or a distinct loopback address is refused";
          ok = accepts logsLane && accepts distinctLoopback;
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
          message = "a lane composition no longer realizes exactly its own providers";
          ok =
            builtins.length mismatches == 0
            || throw (
              "telemetry-capability-matrix: "
              + lib.concatStringsSep "; " (
                map (
                  entry:
                  "${entry.composition} realizes ${builtins.toJSON (providers entry.host)} instead of ${builtins.toJSON entry.expect}"
                ) mismatches
              )
            );
        }
        {
          message = "a composition no longer renders its own health path";
          ok =
            noRegisteredSource.services.vmagent.prometheusConfig.scrape_configs == [ vmagentHealthJob ]
            && admittedTraces.services.vmagent.prometheusConfig.scrape_configs == [ vmagentHealthJob ]
            && builtins.attrNames admittedTraces.services.telemetry.scrape == [ "vmagent-health" ]
            && builtins.hasAttr "vector-health" logsLane.services.telemetry.scrape
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
          message = "the two collector realizations no longer compose into one instance";
          ok =
            builtins.attrNames otelBoth.services.opentelemetry-collector.settings.service.pipelines == [
              "metrics/scrape"
              "traces"
            ];
        }
        {
          message = "the delivery-health scrape no longer composes the scrape provider alone";
          ok = accepts deliveryHealth && !(deliveryHealth.services.notify.events ? opentelemetry-collector);
        }
        {
          # Two scrape realizations would both own the health path.
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
