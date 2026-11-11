# Host/environment identity: the projection vocabulary external consumers read,
# the refusal of empty values, and where identity enrichment does and does not
# apply. Bare contract cases stay on the lightweight contract substrate.
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
      remoteScrapeRegistration = {
        target = "10.0.0.2";
        port = 9100;
        labels = {
          host = "remote-host";
          environment = "remote-env";
        };
      };
      localScrapeRegistration = {
        target = "127.0.0.1";
        port = 9200;
      };
      scrapeValues = {
        identity = {
          environment = "test";
          hostName = "fixture-host";
        };
        scrape.remote = remoteScrapeRegistration;
        scrape.local = localScrapeRegistration;
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
        scrape.local = localScrapeRegistration;
        destinations.metrics = remoteWrite;
      };
      remoteScrape = hostFor [ aspects.telemetry-otel-collector-scrape ] {
        identity = {
          hostName = "gateway-host";
          environment = "gateway-env";
        };
        scrape.remote = remoteScrapeRegistration;
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
              otlp.ingress.host = "100.64.0.9";
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
      # The identity processor and a hand-declared resource attribute disagree.
      conflicting =
        (lib.nixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            aspects.telemetry-otel-collector-otlp
            {
              services.telemetry = lib.recursiveUpdate otlpValues {
                otlp.ingress.host = "100.64.0.10";
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
      # The identity processor's attributes, and the labels of one rendered job.
      identityAttrs =
        collector.services.opentelemetry-collector.settings.processors."resource/telemetry-identity".attributes;
      pipelinesOf = cfg: cfg.services.opentelemetry-collector.settings.service.pipelines;
      labelsOfJob =
        jobs: name:
        let
          job = builtins.head (builtins.filter (candidate: candidate.job_name == name) jobs);
        in
        (builtins.head job.static_configs).labels;
      vmagentJobs = cfg: cfg.services.vmagent.prometheusConfig.scrape_configs;
      collectorJobs =
        cfg: cfg.services.opentelemetry-collector.settings.receivers.prometheus.config.scrape_configs;
      # `networking.hostName` is the NixOS default the contract reads, so the
      # substrate declares it alongside the module under test.
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
      # A named telemetry refusal, whatever its wording.
      refusedNamed = cfg: builtins.any (lib.hasPrefix "telemetry: ") (assertionFailures cfg);
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
          message = "empty identity is not refused by name";
          ok =
            refusedNamed (telemetryContract {
              identity.hostName = "";
            })
            && refusedNamed (telemetryContract {
              identity.environment = "";
            });
        }
        {
          message = "the default host identity is not networking.hostName";
          ok = identityHost.services.telemetry.identity.hostName == "identity-host";
        }
        {
          # Renaming a projection field breaks dashboards and journal queries, and
          # an unset environment must be omitted rather than projected as empty.
          message = "the identity projection vocabulary changed, or an unset environment is projected";
          ok =
            let
              unset = {
                identity = {
                  hostName = "fixture-host";
                  environment = null;
                };
              };
            in
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
              }
            && canonical.localResourceAttributes unset == { "host.name" = "fixture-host"; }
            && canonical.localScrapeLabels unset == { host = "fixture-host"; }
            && canonical.localJournalFields unset == { host_name = "fixture-host"; };
        }
      ];

      checks.telemetry-host-identity-rendering = leaf "telemetry-host-identity-rendering" [
        {
          # An explicitly labelled source keeps its own labels; an unlabelled one
          # receives the host's identity.
          message = "a scrape registration lost its own labels to the host identity, or the default is not the identity";
          ok =
            labelsOfJob (vmagentJobs vmagent) "remote" == {
              host = "remote-host";
              environment = "remote-env";
            }
            &&
              labelsOfJob (vmagentJobs vmagent) "local" == {
                host = "fixture-host";
                environment = "test";
              }
            &&
              labelsOfJob (collectorJobs collectorScrape) "remote" == {
                host = "remote-host";
                environment = "remote-env";
              }
            && !((labelsOfJob (collectorJobs collectorDefault) "local") ? environment);
        }
        {
          message = "registered labels or the provider's own instance identity were replaced by enrichment";
          ok =
            let
              ownLabels =
                jest:
                labelsOfJob jest "probe" == {
                  role = "probe";
                  host = "fixture-host";
                  environment = "test";
                };
              keepsInstance = jobs: builtins.any (job: (builtins.head job.static_configs).labels ? instance) jobs;
            in
            ownLabels (vmagentJobs vmagent)
            && ownLabels (collectorJobs collectorScrape)
            && keepsInstance (vmagentJobs vmagent)
            && keepsInstance (collectorJobs collectorScrape)
            && keepsInstance (collectorJobs collectorDefault);
        }
        {
          message = "local OTLP resources do not carry the host identity, or stamp a producer-owned service identity";
          ok =
            builtins.elem {
              key = "host.name";
              value = "fixture-host";
              action = "upsert";
            } identityAttrs
            && builtins.elem {
              key = "deployment.environment.name";
              value = "test";
              action = "upsert";
            } identityAttrs
            && !(builtins.any (attribute: attribute.key == "service.name") identityAttrs);
        }
        {
          message = "a canonical identity contradicted by resourceAttributes is not refused by name";
          ok = refusedNamed conflicting;
        }
        {
          # Identity describes the local producer. Forwarded telemetry keeps the
          # labels it arrived with.
          message = "identity enrichment applies to forwarded telemetry, or stopped applying to local pipelines";
          ok =
            let
              pipelines = pipelinesOf collector;
            in
            builtins.elem "resource/telemetry-identity" pipelines.traces.processors
            && !(builtins.elem "resource/telemetry-identity" pipelines."traces/ingress".processors)
            && !(builtins.elem "resource/telemetry-identity" pipelines."traces/route-ai".processors)
            &&
              labelsOfJob (collectorJobs remoteScrape) "remote" == {
                host = "remote-host";
                environment = "remote-env";
              }
            && !(builtins.elem "resource/telemetry-identity"
              remoteScrape.services.opentelemetry-collector.settings.service.pipelines."metrics/scrape".processors
            );
        }
      ];
    };
}
