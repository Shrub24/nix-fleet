# Checks for host/environment identity across the contract and local
# projections. Bare contract cases stay on the lightweight contract substrate;
# only the NixOS-default case declares the hostname option it needs.
{
  config,
  inputs,
  lib,
  ...
}:
{
  perSystem =
    { system, ... }:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      inherit (import ../../lib/contract-leaf.nix { inherit lib pkgs; })
        assertionFailures
        leaf
        telemetryAccepts
        telemetryContract
        ;
      aspects = config.flake.modules.nixos;
      fixtureHost = {
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "nodev";
          fsType = "tmpfs";
        };
      };
      hostFor =
        modules: values:
        (lib.nixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
          ]
          ++ modules
          ++ [
            { services.telemetry = values; }
            { system.stateVersion = "25.11"; }
            fixtureHost
          ];
        }).config;
      remoteWrite = {
        protocol = "prometheus-remote-write";
        endpoint = "https://metrics.invalid/write";
        signals = [ "metrics" ];
      };
      scrapeValues = {
        identity = {
          environment = "test";
          hostName = "fixture-host";
        };
        scrape.remote = {
          target = "10.0.0.2";
          port = 9100;
          labels = {
            host = "remote-host";
            environment = "remote-env";
          };
        };
        scrape.local = {
          target = "127.0.0.1";
          port = 9200;
        };
        scrape.probe = {
          target = "10.0.0.3";
          port = 9300;
          labels.role = "probe";
        };
        destinations.metrics = remoteWrite;
      };
      vmagent = hostFor [ aspects.telemetry-vmagent ] scrapeValues;
      collectorScrape = hostFor [ aspects.telemetry-otel-collector-scrape ] scrapeValues;
      collectorDefault = hostFor [ aspects.telemetry-otel-collector-scrape ] {
        scrape.local = {
          target = "127.0.0.1";
          port = 9200;
        };
        destinations.metrics = remoteWrite;
      };
      remoteScrape = hostFor [ aspects.telemetry-otel-collector-scrape ] {
        identity = {
          hostName = "gateway-host";
          environment = "gateway-env";
        };
        scrape.remote = {
          target = "10.0.0.2";
          port = 9100;
          labels = {
            host = "remote-host";
            environment = "remote-env";
          };
        };
        destinations.metrics = remoteWrite;
      };
      otlpValues = {
        identity = {
          hostName = "fixture-host";
          environment = "test";
        };
        otlp.signals = [ "traces" ];
        destinations.traces = {
          protocol = "otlp-grpc";
          endpoint = "http://backend.invalid:4317";
          signals = [ "traces" ];
        };
      };
      collector =
        hostFor [ aspects.telemetry-otel-collector-otlp aspects.telemetry-otel-collector-scrape ]
          (
            lib.recursiveUpdate otlpValues {
              otlp.ingress = {
                host = "100.64.0.9";
              };
              pipelines.metrics = [ "scrapeMetrics" ];
              destinations.scrapeMetrics = remoteWrite;
              scrape.identityProbe = {
                target = "127.0.0.1";
                port = 1234;
              };
              routes.ai = {
                signals = [ "traces" ];
                pipelines.traces = [ "traces" ];
                ingress.host = "100.64.0.11";
              };
            }
          );
      conflicting =
        (lib.nixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            aspects.telemetry-otel-collector-otlp
            {
              services.telemetry = lib.recursiveUpdate otlpValues {
                otlp.ingress = {
                  host = "100.64.0.10";
                };
              };
            }
            { services.otel-collector.resourceAttributes."host.name" = "contradiction"; }
            { system.stateVersion = "25.11"; }
            fixtureHost
          ];
        }).config;
      canonical = import ../../lib/telemetry-identity.nix { inherit lib; };
      identityConfig = {
        identity = {
          hostName = "fixture-host";
          environment = "test";
        };
      };
      attrs =
        collector.services.opentelemetry-collector.settings.processors."resource/telemetry-identity".attributes;
      identityHost =
        (lib.evalModules {
          specialArgs = { inherit lib; };
          modules = [
            ../../lib/telemetry-contract.nix
            {
              options.networking.hostName = lib.mkOption { type = lib.types.str; };
              config.networking.hostName = "identity-host";
              options.assertions = lib.mkOption {
                type = lib.types.listOf (
                  lib.types.submodule {
                    options = {
                      assertion = lib.mkOption { type = lib.types.bool; };
                      message = lib.mkOption { type = lib.types.str; };
                    };
                  }
                );
                default = [ ];
              };
            }
          ];
        }).config;
    in
    {
      checks.telemetry-host-identity = leaf "telemetry-host-identity" [
        {
          message = "bare identity vocabulary requires transport activation";
          ok = telemetryAccepts {
            identity.hostName = "name-only";
            identity.environment = "test";
          };
        }
        {
          message = "the default host identity is not networking.hostName";
          ok = identityHost.services.telemetry.identity.hostName == "identity-host";
        }
        {
          message = "empty host identity is not rejected by name";
          ok =
            builtins.any
              (lib.hasPrefix "telemetry: services.telemetry.identity.hostName must be a nonempty string")
              (
                assertionFailures (telemetryContract {
                  identity.hostName = "";
                })
              );
        }
        {
          message = "empty environment identity is not rejected by name";
          ok =
            builtins.any
              (lib.hasPrefix "telemetry: services.telemetry.identity.environment must be a nonempty string")
              (
                assertionFailures (telemetryContract {
                  identity.environment = "";
                })
              );
        }
        {
          message = "native identity projection field names changed";
          ok =
            canonical.localResourceAttributes identityConfig == {
              "host.name" = "fixture-host";
              "deployment.environment.name" = "test";
            }
            &&
              canonical.localScrapeLabels identityConfig == {
                host = "fixture-host";
                environment = "test";
              }
            &&
              canonical.localJournalFields identityConfig == {
                host_name = "fixture-host";
                environment = "test";
              };
        }
        {
          message = "an unset environment is projected as a field instead of being omitted";
          ok =
            let
              unset = {
                identity = {
                  hostName = "fixture-host";
                  environment = null;
                };
              };
            in
            canonical.localResourceAttributes unset == {
              "host.name" = "fixture-host";
            }
            && canonical.localScrapeLabels unset == { host = "fixture-host"; }
            && canonical.localJournalFields unset == { host_name = "fixture-host"; };
        }
      ];

      checks.telemetry-host-identity-rendering = leaf "telemetry-host-identity-rendering" [
        {
          message = "vmagent does not preserve the remote-source override";
          ok =
            let
              jobs = vmagent.services.vmagent.prometheusConfig.scrape_configs;
              remote = builtins.head (builtins.filter (job: job.job_name == "remote") jobs);
            in
            (builtins.head remote.static_configs).labels.host == "remote-host"
            && (builtins.head remote.static_configs).labels.environment == "remote-env";
        }
        {
          message = "vmagent scrape defaults do not match the canonical host identity";
          ok =
            let
              jobs = vmagent.services.vmagent.prometheusConfig.scrape_configs;
              local = builtins.head (builtins.filter (job: job.job_name == "local") jobs);
            in
            (builtins.head local.static_configs).labels.host == "fixture-host"
            && (builtins.head local.static_configs).labels.environment == "test";
        }
        {
          message = "Collector scrape does not preserve remote origin labels through the scrape pipeline";
          ok =
            let
              jobs =
                collectorScrape.services.opentelemetry-collector.settings.receivers.prometheus.config.scrape_configs;
              remote = builtins.head (builtins.filter (job: job.job_name == "remote") jobs);
            in
            (builtins.head remote.static_configs).labels.host == "remote-host"
            && (builtins.head remote.static_configs).labels.environment == "remote-env";
        }
        {
          message = "Collector scrape defaults do not match the canonical host identity";
          ok =
            let
              jobs =
                collectorDefault.services.opentelemetry-collector.settings.receivers.prometheus.config.scrape_configs;
              local = builtins.head (builtins.filter (job: job.job_name == "local") jobs);
            in
            (builtins.head local.static_configs).labels.host == "nixos"
            && !(builtins.head local.static_configs).labels ? environment;
        }
        {
          message = "local OTLP resources do not carry host and environment identity";
          ok =
            builtins.elem {
              key = "host.name";
              value = "fixture-host";
              action = "upsert";
            } attrs
            && builtins.elem {
              key = "deployment.environment.name";
              value = "test";
              action = "upsert";
            } attrs;
        }
        {
          message = "conflicting canonical resource configuration is not rejected by name";
          ok = builtins.any (lib.hasPrefix "telemetry: services.otel-collector.resourceAttributes conflicts with canonical local identity") (
            assertionFailures conflicting
          );
        }
        {
          message = "local OTLP resources stamp a service identity the producer owns";
          ok = !(builtins.any (attribute: attribute.key == "service.name") attrs);
        }
        {
          message = "identity enrichment replaces registered labels or provider instance identity";
          ok =
            let
              labelsOf = job: (builtins.head job.static_configs).labels;
              ownLabelsPreserved =
                jobs:
                let
                  withOwn = builtins.filter (job: labelsOf job ? role) jobs;
                in
                builtins.length withOwn == 1
                &&
                  labelsOf (builtins.head withOwn) == {
                    role = "probe";
                    host = "fixture-host";
                    environment = "test";
                  };
              providerInstance = jobs: builtins.any (job: labelsOf job ? instance) jobs;
              vmagentJobs = vmagent.services.vmagent.prometheusConfig.scrape_configs;
              collectorJobs =
                collectorScrape.services.opentelemetry-collector.settings.receivers.prometheus.config.scrape_configs;
              collectorDefaultJobs =
                collectorDefault.services.opentelemetry-collector.settings.receivers.prometheus.config.scrape_configs;
            in
            ownLabelsPreserved vmagentJobs
            && ownLabelsPreserved collectorJobs
            && providerInstance vmagentJobs
            && providerInstance collectorJobs
            && providerInstance collectorDefaultJobs;
        }
        {
          message = "explicit remote source labels are overridden by the local gateway identity";
          ok =
            let
              settings = remoteScrape.services.opentelemetry-collector.settings;
              jobs = settings.receivers.prometheus.config.scrape_configs;
              remote = builtins.head (builtins.filter (job: job.job_name == "remote") jobs);
              processors = settings.service.pipelines."metrics/scrape".processors;
            in
            (builtins.head remote.static_configs).labels.host == "remote-host"
            && (builtins.head remote.static_configs).labels.environment == "remote-env"
            && !(builtins.elem "resource/telemetry-identity" processors);
        }
        {
          message = "general ingress unexpectedly applies local identity enrichment";
          ok =
            let
              p = collector.services.opentelemetry-collector.settings.service.pipelines;
            in
            builtins.elem "resource/telemetry-identity" p.traces.processors
            && !(builtins.elem "resource/telemetry-identity" p."traces/ingress".processors);
        }
        {
          message = "a named-route pipeline unexpectedly applies local identity enrichment";
          ok =
            let
              p = collector.services.opentelemetry-collector.settings.service.pipelines;
            in
            builtins.elem "resource/telemetry-identity" p.traces.processors
            && !(builtins.elem "resource/telemetry-identity" p."traces/route-ai".processors);
        }
      ];
    };
}
