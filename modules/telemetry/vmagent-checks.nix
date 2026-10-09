# Provider-owned vmagent checks: what the scrape provider renders for the jobs a
# host registers, which fanout mistakes it refuses by name, and the arbitration
# error of composing two scrape implementations.
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
      rejectsWith = message: host: builtins.any (lib.hasPrefix message) (assertionFailures host);
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
            labels.instance = "nixos:vmagent";
          }
        ];
      };
      otelCollectorHealthJob = {
        job_name = "otel-collector-health";
        scrape_interval = "30s";
        metrics_path = "/metrics";
        scheme = "http";
        static_configs = [
          {
            targets = [ "127.0.0.1:9464" ];
            labels.instance = "nixos:otel-collector";
          }
        ];
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
      otelScrape =
        (lib.nixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            config.flake.modules.nixos.telemetry-otel-collector-scrape
            {
              services.telemetry = {
                scrape.app = {
                  target = "127.0.0.1";
                  port = 9187;
                };
                destinations.metrics = remoteWrite;
              };
            }
            { system.stateVersion = "25.11"; }
          ];
        }).config;
      # A literal the adapter would render into its own comma-separated argument
      # array, so it has to be refused while it is still visible at build time.
      hostileEndpoint = vmagentHost {
        scrape.app = {
          target = "127.0.0.1";
          port = 9187;
        };
        destinations.metrics = remoteWrite // {
          endpoint = "https://metrics.invalid/api/v1/write?tenant=a,b";
        };
      };
      hostileHeader = vmagentHost {
        scrape.app = {
          target = "127.0.0.1";
          port = 9187;
        };
        destinations.metrics = remoteWrite // {
          headers.Authorization = {
            secret = "token";
            prefix = "Bearer,x ";
          };
        };
        secretFiles.token = fixtureSecretFile;
        secretKeys.token = "fixture/token";
      };
    in
    {
      checks = {
        vmagent-provider-rejections = leaf "vmagent-provider-rejections" [
          {
            message = "a scrape registration with no metrics destination is no longer refused by the provider";
            ok =
              rejectsWith "telemetry: scrape sources are registered but the metrics pipeline has no destination"
                (vmagentHost {
                  scrape.app = {
                    target = "127.0.0.1";
                    port = 9100;
                  };
                });
          }
          {
            # The traces-carrying destination must not become what carries scraped
            # metrics: the refusal is that the metrics fanout has no destination.
            message = "a scrape registration whose only destination carries traces is no longer refused for having no metrics destination";
            ok =
              rejectsWith "telemetry: scrape sources are registered but the metrics pipeline has no destination"
                (vmagentHost {
                  scrape.app = {
                    target = "127.0.0.1";
                    port = 9100;
                  };
                  destinations.tracesOnly = {
                    protocol = "otlp-grpc";
                    endpoint = "http://langfuse.invalid:4317";
                    signals = [ "traces" ];
                  };
                });
          }
        ];

        vmagent-rendered-jobs = leaf "vmagent-rendered-jobs" [
          {
            message = "the registered scrape fields or the provider's own health job no longer render";
            ok =
              rendered.services.vmagent.enable
              &&
                rendered.services.vmagent.prometheusConfig.scrape_configs == [
                  {
                    job_name = "everything";
                    scrape_interval = "45s";
                    metrics_path = "/custom-metrics";
                    scheme = "https";
                    static_configs = [
                      {
                        targets = [ "10.0.0.5:9090" ];
                        labels = {
                          service = "everything";
                          environment = "fixture";
                        };
                      }
                    ];
                  }
                  vmagentHealthJob
                ];
          }
          {
            message = "the persistent queue, loopback management endpoint, build-time validation or firewall posture regressed";
            ok =
              rendered.services.vmagent.extraArgs == [
                "-remoteWrite.url=https://metrics.invalid/api/v1/write"
                "-remoteWrite.tmpDataPath=%S/vmagent/remote_write_tmp"
                "-httpListenAddr=127.0.0.1:8429"
                "-remoteWrite.maxDiskUsagePerURL=1073741824"
              ]
              && rendered.systemd.services.vmagent.serviceConfig.StateDirectory == "vmagent"
              && rendered.services.vmagent.checkConfig
              && !rendered.services.vmagent.openFirewall
              && !(builtins.elem 8429 rendered.networking.firewall.allowedTCPPorts);
          }
          {
            message = "the explicit OTel scrape realization no longer renders only its own job and health mapping";
            ok =
              !(otelScrape.systemd.services ? vmagent)
              && !(otelScrape.services.opentelemetry-collector.settings.receivers ? otlp)
              &&
                builtins.attrNames otelScrape.services.opentelemetry-collector.settings.receivers
                == [ "prometheus" ]
              &&
                builtins.attrNames otelScrape.services.opentelemetry-collector.settings.service.pipelines
                == [ "metrics/scrape" ]
              &&
                otelScrape.services.opentelemetry-collector.settings.service.pipelines."metrics/scrape".receivers
                == [ "prometheus" ]
              &&
                otelScrape.services.opentelemetry-collector.settings.receivers.prometheus.config.scrape_configs == [
                  {
                    job_name = "app";
                    scrape_interval = "30s";
                    metrics_path = "/metrics";
                    scheme = "http";
                    static_configs = [
                      {
                        targets = [ "127.0.0.1:9187" ];
                        labels = { };
                      }
                    ];
                  }
                  otelCollectorHealthJob
                ];
          }
        ];

        vmagent-fanout-guards = leaf "vmagent-fanout-guards" [
          {
            message = "a registered endpoint whose literal the remote-write argument parser reads as structure no longer fails by name";
            ok =
              builtins.any (lib.hasPrefix "telemetry: the metrics pipeline selects values vmagent's argument parser") (
                assertionFailures hostileEndpoint
              )
              && hostileEndpoint.services.vmagent.enable;
          }
          {
            message = "a registered header prefix whose literal the remote-write argument parser reads as structure no longer fails by name";
            ok =
              builtins.any (lib.hasPrefix "telemetry: the metrics pipeline selects values vmagent's argument parser") (
                assertionFailures hostileHeader
              )
              && hostileHeader.services.vmagent.enable;
          }
        ];
      };
    };
}
