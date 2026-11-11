# Provider-owned vmagent checks: the fanout mistakes the provider refuses, the
# job it renders for a registration, and the arbitration error of composing two
# scrape implementations.
{
  lib,
  config,
  inputs,
  ...
}:
let
  vmagentHostFor =
    system: values:
    (lib.nixosSystem {
      inherit system;
      modules = [
        inputs.sops-nix.nixosModules.sops
        config.flake.modules.nixos.telemetry-vmagent
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
  fixtureSecretFile = ../flake/fixture-secrets.yaml;
in
{
  perSystem =
    { system, ... }:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      inherit (import ../../lib/contract-leaf.nix { inherit lib pkgs; }) assertionFailures leaf;
      vmagentHost = vmagentHostFor system;
      # A named telemetry refusal, whatever its wording.
      refused = host: builtins.any (lib.hasPrefix "telemetry: ") (assertionFailures host);
      remoteWrite = {
        protocol = "prometheus-remote-write";
        endpoint = "https://metrics.invalid/api/v1/write";
        signals = [ "metrics" ];
      };
      registeredApp = {
        scrape.app = {
          target = "127.0.0.1";
          port = 9187;
        };
      };
      rendered = vmagentHost {
        scrape.everything = {
          target = "10.0.0.5";
          port = 9090;
          metricsPath = "/custom-metrics";
          scheme = "https";
          interval = "45s";
          labels = {
            service = "everything";
            environment = "fixture";
          };
        };
        destinations.metrics = remoteWrite;
      };
      jobsOf = cfg: cfg.services.vmagent.prometheusConfig.scrape_configs;
      jobNamed =
        cfg: name: builtins.head (builtins.filter (candidate: candidate.job_name == name) (jobsOf cfg));
      otelScrape =
        (lib.nixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            config.flake.modules.nixos.telemetry-otel-collector-scrape
            {
              services.telemetry = registeredApp // {
                destinations.metrics = remoteWrite;
              };
            }
            { system.stateVersion = "25.11"; }
          ];
        }).config;
      # Literals the adapter would render into its own comma-separated argument
      # array, so they must be refused while still visible at build time.
      hostileWith =
        extra:
        vmagentHost (
          registeredApp
          // {
            destinations.metrics = remoteWrite // extra;
          }
        );
      hostileEndpoint = hostileWith {
        endpoint = "https://metrics.invalid/api/v1/write?tenant=a,b";
      };
      hostileHeader = vmagentHost (
        registeredApp
        // {
          destinations.metrics = remoteWrite // {
            headers.Authorization = {
              secret = "token";
              prefix = "Bearer,x ";
            };
          };
          secretFiles.token = fixtureSecretFile;
          secretKeys.token = "fixture/token";
        }
      );
    in
    {
      checks = {
        # A registered source with no metrics fanout, and one whose only
        # destination carries traces, are the same refusal.
        vmagent-provider-rejections = leaf "vmagent-provider-rejections" [
          {
            message = "a scrape registration with no metrics destination is no longer refused";
            ok = refused (vmagentHost registeredApp);
          }
          {
            message = "a scrape registration whose only destination carries traces is no longer refused";
            ok = refused (
              vmagentHost (
                registeredApp
                // {
                  destinations.tracesOnly = {
                    protocol = "otlp-grpc";
                    endpoint = "http://langfuse.invalid:4317";
                    signals = [ "traces" ];
                  };
                }
              )
            );
          }
        ];

        vmagent-rendered-jobs = leaf "vmagent-rendered-jobs" [
          {
            # A registration becomes one job named for its key, targeting its
            # address, carrying the host identity plus its own labels, with its
            # overrides honoured.
            message = "a registered scrape no longer renders as its own job";
            ok =
              let
                job = jobNamed rendered "everything";
                target = builtins.head job.static_configs;
              in
              rendered.services.vmagent.enable
              &&
                builtins.map (candidate: candidate.job_name) (jobsOf rendered) == [
                  "everything"
                  "vmagent-health"
                ]
              && target.targets == [ "10.0.0.5:9090" ]
              && job.metrics_path == "/custom-metrics"
              && job.scheme == "https"
              && job.scrape_interval == "45s"
              &&
                target.labels == {
                  host = "nixos";
                  service = "everything";
                  environment = "fixture";
                };
          }
          {
            message = "the persistent queue, build-time validation or loopback management posture regressed";
            ok =
              rendered.systemd.services.vmagent.serviceConfig.StateDirectory == "vmagent"
              && rendered.services.vmagent.checkConfig
              && !rendered.services.vmagent.openFirewall
              && !(builtins.elem 8429 rendered.networking.firewall.allowedTCPPorts);
          }
          {
            # The OTel realization is the collector's own prometheus receiver, not
            # a second scrape provider beside it.
            message = "the OTel scrape realization no longer renders only its own receiver and jobs";
            ok =
              !(otelScrape.systemd.services ? vmagent)
              && !(otelScrape.services.opentelemetry-collector.settings.receivers ? otlp)
              &&
                builtins.attrNames otelScrape.services.opentelemetry-collector.settings.receivers == [
                  "prometheus"
                ]
              &&
                builtins.attrNames otelScrape.services.opentelemetry-collector.settings.service.pipelines == [
                  "metrics/scrape"
                ]
              &&
                builtins.map (
                  job: job.job_name
                ) otelScrape.services.opentelemetry-collector.settings.receivers.prometheus.config.scrape_configs
                == [
                  "app"
                  "otel-collector-health"
                ];
          }
        ];

        # The adapter renders remote-write arguments as one comma-separated
        # array, so a literal carrying that structure must not reach it.
        vmagent-fanout-guards = leaf "vmagent-fanout-guards" [
          {
            message = "an endpoint literal the argument parser reads as structure is no longer refused";
            ok = refused hostileEndpoint;
          }
          {
            message = "a header-prefix literal the argument parser reads as structure is no longer refused";
            ok = refused hostileHeader;
          }
        ];
      };
    };
}
