# Fixture evaluation class: exercises every aspect on throwaway NixOS targets,
# consumer-shaped — imports the upstream modules aspects expect and binds
# obviously-fake placeholders. Never activated, never decrypts anything. One
# fixture per declared system: the wiring module builds each toplevel as a
# check, so platform-specific packaging (python3, apprise) is exercised for
# every architecture the fleet actually runs. The host asserts only what it can
# read from its own configuration; every throwaway contract evaluation lives in
# its own leaf check (`contractLeaves` below), so forcing the host stays cheap.
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

  # Every throwaway NixOS evaluation has an explicit state version so tests
  # stay warning-free and do not inherit a changing nixpkgs default.
  fixtureNixosSystem =
    args:
    lib.nixosSystem (
      args
      // {
        modules = [ { system.stateVersion = "25.11"; } ] ++ args.modules;
      }
    );

  aspects = config.flake.modules.nixos;

  # The v2 consumer wiring, exercised for real: a flake-level module closes
  # over this evaluation's merged config.fleet, resolves the profile through
  # the public API, and passes the projection into the NixOS module as args.
  # This is exactly the ~15-line pattern docs/contracts/builders.md prescribes.
  resolve = import ../../lib/build-profile.nix lib;
  resolvedProfile = resolve.resolveBuildProfile config.fleet "fixture";

  # The CI cache coordinate the build-push-cache workflow defaults to must be
  # derived from the contract, not a literal that happens to match it: the
  # mutation moves the record and the resolved URL has to move with it.
  cacheApiUrl = config.flake.lib.serviceEndpoints.cacheApiUrl config.fleet;
  cacheApiUrlMutated = config.flake.lib.serviceEndpoints.cacheApiUrl (
    lib.recursiveUpdate config.fleet {
      services."niks3-write".endpoints.api.tailnet.port = 5752;
    }
  );

  # A throwaway telemetry host for the caller's system. The contract
  # evaluations below assert on its rendered config, so they are evaluated for
  # the system of the check that carries them.
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
  contractHostFor =
    system: telemetryConfig: telemetryHostFor system [ aspects.telemetry ] telemetryConfig;

  # The credential guard the vmagent unit runs, taken from the unit's own
  # rendered ExecStartPre rather than re-derived here, so the check that builds
  # it runs the artifact that ships. Evaluated for the checking system because
  # the script embeds the coreutils path it calls.
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

  # The contract evaluations behind the fixture's leaf checks: throwaway
  # evaluations, independent of the fixture host, parameterized by the system of
  # the check that carries them. Splitting them out of the host's assertions is
  # what keeps the host's own evaluation cheap.
  contractLeaves =
    system:
    let
      # A destination/fanout/secret mistake must fail closed by name at the
      # contract level (it must hold for any implementation), so the reject
      # checks force the rendered collector settings, the contract's resolved
      # fanout, and the contract's own assertions.
      telemetryRejects =
        imports: module:
        let
          evaluated = fixtureNixosSystem {
            inherit system;
            modules = [ inputs.sops-nix.nixosModules.sops ] ++ imports ++ [ module ];
          };
        in
        !(builtins.tryEval (
          builtins.deepSeq [
            evaluated.config.services.telemetry.resolvedPipelines
            (lib.asserts.checkAssertWarn evaluated.config.assertions evaluated.config.warnings true)
          ] true
        )).success;
      providerRejects =
        imports: module:
        let
          evaluated = fixtureNixosSystem {
            inherit system;
            modules = [ inputs.sops-nix.nixosModules.sops ] ++ imports ++ [ module ];
          };
        in
        !(builtins.tryEval (
          builtins.deepSeq [
            evaluated.config.services.vmagent.prometheusConfig
            evaluated.config.services.opentelemetry-collector.settings
            (lib.asserts.checkAssertWarn evaluated.config.assertions evaluated.config.warnings true)
          ] true
        )).success;
      # Contract-level destination, fanout and credential mistakes fail closed.
      telemetryMutationRejectionChecks =
        # a destination header referencing an unknown secret
        telemetryRejects [ aspects.telemetry ] {
          services.telemetry.destinations.bad = {
            protocol = "otlp-http";
            endpoint = "https://invalid.example";
            signals = [ "traces" ];
            headers.Authorization.secret = "absent";
          };
        }
        # secretFiles and secretKeys must pair
        && telemetryRejects [ aspects.telemetry ] {
          services.telemetry.secretFiles.token = fixtureSecretFile;
          services.telemetry.secretKeys.other = "otel/token";
        }
        # explicit fanout naming an unknown destination
        && telemetryRejects [ aspects.telemetry ] { services.telemetry.pipelines.traces = [ "absent" ]; }
        # a destination accepting a signal its protocol cannot carry
        && telemetryRejects [ aspects.telemetry ] {
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
        && telemetryRejects [ aspects.telemetry ] {
          services.telemetry.destinations.tracesOnly = {
            protocol = "otlp-http";
            endpoint = "https://langfuse.invalid";
            signals = [ "traces" ];
          };
          services.telemetry.pipelines.logs = [ "tracesOnly" ];
        }
        # an explicit empty fanout is a silent drop
        && telemetryRejects [ aspects.telemetry ] { services.telemetry.pipelines.logs = [ ]; };
      # Provider-level failures use their explicitly composed realization.
      telemetryProviderRejectionChecks =
        # a scrape source with no metrics destination to carry it
        providerRejects [ aspects.telemetry-vmagent ] {
          services.telemetry.scrape.app = {
            target = "127.0.0.1";
            port = 9100;
          };
        }
        # a scrape source whose only destination accepts traces, not metrics: the
        # traces-only default fanout must not be what carries scraped metrics
        && providerRejects [ aspects.telemetry-vmagent ] {
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
        # (the collector must be active for the provider's own check to run)
        && telemetryRejects [ aspects.telemetry-otel-collector-otlp ] {
          services.telemetry.otlp.signals = [ "traces" ];
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
      # Every named-rejection probe reads a named contract error off the host's
      # own assertions, not an incidental evaluation error: the message is
      # asserted, so renaming or dropping the rejection fails its leaf.
      admissionFailuresOf =
        modules:
        let
          evaluated = admissionEval modules;
        in
        map (assertion: assertion.message) (
          builtins.filter (assertion: !assertion.assertion) evaluated.config.assertions
        );
      admissionRejects =
        message: modules: builtins.any (lib.hasPrefix message) (admissionFailuresOf modules);
      # The composed producer host the OTLP and ingress rejections mutate.
      admissionRejectHost = extra: [
        aspects.telemetry
        aspects.telemetry-otlp
        {
          services.telemetry.destinations.traces = {
            protocol = "otlp-http";
            endpoint = "https://backend.invalid";
            signals = [ "traces" ];
          };
        }
        extra
      ];

      # duplicate admission is not a set
      telemetryOtlpRejectionChecks =
        admissionRejects "telemetry: services.telemetry.otlp.signals names traces more than once"
          (admissionRejectHost {
            services.telemetry.otlp.signals = [
              "traces"
              "traces"
            ];
          })
        # an admitted signal with no destination to carry it
        &&
          admissionRejects "telemetry: OTLP admits logs with no destination pipeline"
            (admissionRejectHost {
              services.telemetry.otlp.signals = [
                "traces"
                "logs"
              ];
            })
        # the producer listener is loopback-only: network ingress is a separate,
        # explicitly bound listener
        &&
          admissionRejects
            "telemetry: services.telemetry.otlp.host is '0.0.0.0', but the producer listener is loopback-only"
            (admissionRejectHost {
              services.telemetry.otlp.signals = [ "traces" ];
              services.telemetry.otlp.host = "0.0.0.0";
            })
        # A DNS name beginning with 127. is not a loopback address, and malformed
        # octets must fail at evaluation rather than at collector startup.
        &&
          builtins.all
            (
              badHost:
              admissionRejects
                "telemetry: services.telemetry.otlp.host is '${badHost}', but the producer listener is loopback-only"
                (admissionRejectHost {
                  services.telemetry.otlp.signals = [ "traces" ];
                  services.telemetry.otlp.host = badHost;
                })
            )
            [
              "127.example.invalid"
              "127.999.0.1"
            ];

      # HTTP and gRPC each own a TCP listener, even within one receiver.
      telemetryIngressRejectionChecks =
        admissionRejects "telemetry: services.telemetry.otlp.httpPort and grpcPort must differ"
          (admissionRejectHost {
            services.telemetry.otlp.signals = [ "traces" ];
            services.telemetry.otlp.httpPort = 4317;
          })
        &&
          admissionRejects "telemetry: services.telemetry.otlp.ingress.httpPort and grpcPort must differ"
            (admissionRejectHost {
              services.telemetry.otlp.signals = [ "traces" ];
              services.telemetry.otlp.ingress = {
                host = "100.64.0.2";
                httpPort = 4318;
                grpcPort = 4318;
              };
            })
        # a wildcard ingress would expose the collector on every interface
        &&
          admissionRejects "telemetry: services.telemetry.otlp.ingress.host must be an explicit bind address"
            (admissionRejectHost {
              services.telemetry.otlp.signals = [ "traces" ];
              services.telemetry.otlp.ingress = {
                host = "0.0.0.0";
              };
            })
        &&
          admissionRejects "telemetry: services.telemetry.otlp.ingress.host must be an explicit bind address"
            (admissionRejectHost {
              services.telemetry.otlp.signals = [ "traces" ];
              services.telemetry.otlp.ingress = {
                host = "";
              };
            })
        # an ingress with no transport binds nothing
        &&
          admissionRejects "telemetry: services.telemetry.otlp.ingress sets no HTTP or gRPC port"
            (admissionRejectHost {
              services.telemetry.otlp.signals = [ "traces" ];
              services.telemetry.otlp.ingress = {
                host = "100.64.0.2";
                httpPort = null;
              };
            })
        # an ingress with nothing admitted is a dead listener
        &&
          admissionRejects
            "telemetry: services.telemetry.otlp.ingress is configured while services.telemetry.otlp.signals is empty"
            (admissionRejectHost {
              services.telemetry.otlp.ingress = {
                host = "100.64.0.2";
              };
            });

      # local and network listeners must not collide
      telemetryListenerCollisionChecks =
        admissionRejects "telemetry: services.telemetry.otlp.ingress binds 127.0.0.1:4318, the same address"
          (admissionRejectHost {
            services.telemetry.otlp.signals = [ "traces" ];
            services.telemetry.otlp.ingress = {
              host = "127.0.0.1";
            };
          })
        # the same socket spelled differently: `localhost` can resolve to the local
        # listener's own address (or its IPv6 twin), and a bracketed IPv6 literal is
        # the same bind address as the unbracketed form
        &&
          admissionRejects "telemetry: services.telemetry.otlp.ingress binds localhost:4318, the same address"
            (admissionRejectHost {
              services.telemetry.otlp.signals = [ "traces" ];
              services.telemetry.otlp.ingress = {
                host = "localhost";
              };
            })
        &&
          admissionRejects "telemetry: services.telemetry.otlp.ingress binds ::1:4318, the same address"
            (admissionRejectHost {
              services.telemetry.otlp.host = "[::1]";
              services.telemetry.otlp.signals = [ "traces" ];
              services.telemetry.otlp.ingress = {
                host = "::1";
              };
            });

      # credential vocabulary is shared, so it is enforced without OTel: a
      # vmagent host must not silently accept a bad secret id or an unpaired file
      telemetryCredentialRejectionChecks =
        # The ID-pairing and unknown-header-secret refusals are the mutation
        # leaf's cases — same contract assertion, cheaper hosts — so what is
        # credential-specific here is an unused binding, and a dormant header
        # that must stay accepted.
        admissionRejects
          "telemetry: bound credentials have no declared destination header reference: unused"
          [
            aspects.telemetry
            {
              services.telemetry.secretFiles.unused = fixtureSecretFile;
              services.telemetry.secretKeys.unused = "unused/key";
            }
          ]
        && admissionAccepts [
          aspects.telemetry
          {
            services.telemetry.destinations.dormant = {
              protocol = "otlp-http";
              endpoint = "https://dormant.invalid";
              signals = [ "logs" ];
              headers.Authorization.secret = "unused";
            };
            services.telemetry.secretFiles.unused = fixtureSecretFile;
            services.telemetry.secretKeys.unused = "unused/key";
          }
        ];
      # A resource processor declared directly (not via resourceAttributes) must
      # still reach the pipeline order, or the config would define a processor no
      # pipeline runs.
      collectorManualResourceOrder =
        (fixtureNixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            aspects.telemetry-otel-collector-otlp
            {
              services.telemetry.otlp.signals = [ "traces" ];
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
          evaluated = fixtureNixosSystem {
            inherit system;
            modules = [
              inputs.sops-nix.nixosModules.sops
              aspects.telemetry-otel-collector-otlp
              {
                services.telemetry.otlp.signals = [ "traces" ];
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
        && !(evaluated.config.systemd.services.opentelemetry-collector.serviceConfig ? EnvironmentFile)
        && collector.settings.exporters ? "otlp/plain";
      # Bound credentials remain valid when their declared destination header is
      # dormant; the realization registers only secrets for active exporters.
      collectorInactiveCredentials =
        let
          evaluated = fixtureNixosSystem {
            inherit system;
            modules = [
              inputs.sops-nix.nixosModules.sops
              aspects.telemetry-otel-collector-otlp
              {
                services.telemetry.otlp.signals = [ "traces" ];
                services.telemetry.destinations.traces = {
                  protocol = "otlp-http";
                  endpoint = "https://backend.invalid";
                  signals = [ "traces" ];
                  headers.Authorization.secret = "activeToken";
                };
                services.telemetry.destinations.logsOnly = {
                  protocol = "otlp-http";
                  endpoint = "https://logs.invalid";
                  signals = [ "logs" ];
                  headers.Authorization.secret = "idleToken";
                };
                services.telemetry.secretFiles = {
                  activeToken = fixtureSecretFile;
                  idleToken = fixtureSecretFile;
                };
                services.telemetry.secretKeys = {
                  activeToken = "otel/active";
                  idleToken = "otel/idle";
                };
              }
            ];
          };
          collector = evaluated.config.services.opentelemetry-collector;
        in
        builtins.attrNames collector.settings.exporters == [ "otlphttp/traces" ]
        && builtins.attrNames evaluated.config.sops.secrets == [ "otel-collector/activeToken" ]
        &&
          evaluated.config.sops.templates."otel-collector.env".content
          == "OTELCOL_activeToken=${evaluated.config.sops.placeholder."otel-collector/activeToken"}\n"
        &&
          collector.validateConfigOverrides == [
            "exporters::otlphttp/traces::headers::Authorization=stub"
          ];

      # These minimal hosts exercise dormant contract data and explicit capability
      # selection. A minimal host is evaluated through nixpkgs' own assertion check.
      admissionEval =
        modules:
        fixtureNixosSystem {
          inherit system;
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
      # A push-only consumer imports the contract fragment and reads its local
      # endpoint. Reading that endpoint is valid only with a composed OTLP input
      # and a destination that carries the admitted signal.
      pushOnlyEndpoint =
        {
          withSignals ? false,
          withDestination ? false,
        }:
        (fixtureNixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            aspects.telemetry-otlp
          ]
          ++ lib.optionals withDestination [
            {
              services.telemetry.destinations.local = {
                protocol = "otlp-grpc";
                endpoint = "http://gateway.invalid:4317";
                signals = [ "traces" ];
              };
            }
          ]
          ++ lib.optionals withSignals [ { services.telemetry.otlp.signals = [ "traces" ]; } ]
          ++ [
            ({ config, ... }: {
              environment.variables.OTEL_EXPORTER_OTLP_ENDPOINT = config.services.telemetry.otlp.httpUrl;
            })
          ];
        }).config.environment.variables.OTEL_EXPORTER_OTLP_ENDPOINT;
      telemetryCapabilityMatrixChecks =
        let
          contractOnly = contractHostFor system {
            destinations.metrics = {
              protocol = "prometheus-remote-write";
              endpoint = "http://metrics.invalid/api/v1/write";
              signals = [ "metrics" ];
            };
          };
          producerOnly = telemetryHostFor system [
            ../../lib/telemetry-contract.nix
            aspects.node-exporter
          ] { };
          logsOnly = admissionEval [
            aspects.telemetry-logs
            {
              services.telemetry.journald = {
                includeUnits = [ "fixture-monitored" ];
                sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
              };
            }
          ];
          otelBoth =
            telemetryHostFor system
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
                destinations.metrics = {
                  protocol = "prometheus-remote-write";
                  endpoint = "http://metrics.invalid/api/v1/write";
                  signals = [ "metrics" ];
                };
                destinations.traces = {
                  protocol = "otlp-http";
                  endpoint = "https://traces.invalid";
                  signals = [ "traces" ];
                };
              };
        in
        !(contractOnly ? systemd.services.vmagent)
        && !(contractOnly ? systemd.services.vector)
        && !(contractOnly ? systemd.services.opentelemetry-collector)
        && admissionAccepts [
          ../../lib/telemetry-contract.nix
          aspects.node-exporter
        ]
        && !(producerOnly.systemd.services ? vmagent)
        && !(producerOnly.systemd.services ? opentelemetry-collector)
        && logsOnly.config.services.vector.enable
        && !(logsOnly.config.systemd.services ? vmagent)
        && !(logsOnly.config.systemd.services ? opentelemetry-collector)
        && builtins.hasAttr "vector-health" logsOnly.config.services.telemetry.scrape
        &&
          (builtins.attrNames otelBoth.services.opentelemetry-collector.settings.service.pipelines) == [
            "metrics/scrape"
            "traces"
          ]
        && otelBoth.services.opentelemetry-collector.enable
        && !(otelBoth.systemd.services ? vmagent)
        && telemetryRejects [ aspects.telemetry-vmagent aspects.telemetry-otel-collector-scrape ] {
          services.telemetry.destinations.metrics = {
            protocol = "prometheus-remote-write";
            endpoint = "http://metrics.invalid/api/v1/write";
            signals = [ "metrics" ];
          };
          services.telemetry.scrape.app = {
            target = "127.0.0.1";
            port = 9187;
          };
        };
      telemetryRouteChecks =
        let
          modules = [
            aspects.telemetry-otel-collector-otlp
            {
              services.telemetry = {
                otlp.signals = [ "traces" ];
                destinations.general = {
                  protocol = "otlp-http";
                  endpoint = "https://victoria.invalid/v1/traces";
                  signals = [ "traces" ];
                };
                destinations.langfuse = {
                  protocol = "otlp-http";
                  endpoint = "https://langfuse.invalid/api/public/otel/v1/traces";
                  signals = [ "traces" ];
                };
                pipelines.traces = [ "general" ];
                routes.ai = {
                  signals = [ "traces" ];
                  pipelines.traces = [ "langfuse" ];
                  ingress = {
                    host = "127.0.0.2";
                    httpPort = 14320;
                    grpcPort = null;
                  };
                };
              };
            }
          ];
          host = admissionEval modules;
          settings = host.config.services.opentelemetry-collector.settings;
          routeRejects =
            message: extra: builtins.any (lib.hasPrefix message) (admissionFailures (modules ++ [ extra ]));
        in
        admissionAccepts modules
        && settings.service.pipelines.traces.exporters == [ "otlphttp/general" ]
        && settings.service.pipelines."traces/route-ai".exporters == [ "otlphttp/route-ai-langfuse" ]
        && settings.service.pipelines."traces/route-ai".receivers == [ "otlp/route-ai" ]
        && settings.receivers."otlp/route-ai".protocols.http.endpoint == "127.0.0.2:14320"
        && settings.exporters ? "otlphttp/general"
        && settings.exporters ? "otlphttp/route-ai-langfuse"
        && settings.exporters."otlphttp/route-ai-langfuse".sending_queue.storage == "file_storage"
        && settings.service.pipelines."traces/route-ai".exporters != [ "otlphttp/route-ai-general" ]
        && telemetryRejects [ aspects.telemetry-otel-collector-otlp ] {
          services.telemetry = {
            otlp.signals = [ "traces" ];
            destinations.general = {
              protocol = "otlp-http";
              endpoint = "https://victoria.invalid/v1/traces";
              signals = [ "traces" ];
            };
            routes.ai = {
              signals = [ "traces" ];
              pipelines.traces = [ "missing" ];
              ingress.host = "127.0.0.2";
              ingress.httpPort = 14320;
            };
          };
        }
        && routeRejects "telemetry: route(s) empty declare no signals" {
          services.telemetry.routes.empty = lib.mkForce {
            signals = [ ];
            ingress.host = "127.0.0.2";
            ingress.httpPort = 14321;
          };
        }
        && routeRejects "telemetry: route(s) ai ingress.host must be an explicit bind address" {
          services.telemetry.routes.ai.ingress.host = lib.mkForce "0.0.0.0";
        }
        && routeRejects "telemetry: route 'ai' binds 127.0.0.2:14320" {
          services.telemetry.routes.second = {
            signals = [ "traces" ];
            pipelines.traces = [ "langfuse" ];
            ingress.host = "127.0.0.2";
            ingress.httpPort = 14320;
          };
        }
        # Fan-out to the general store is a route's own selection, never a
        # default: naming it gives the route both destinations as separate
        # instances while the general route keeps exporting through its own.
        && (
          let
            dual =
              (admissionEval (
                modules
                ++ [
                  {
                    services.telemetry.routes.ai.pipelines.traces = lib.mkForce [
                      "langfuse"
                      "general"
                    ];
                  }
                ]
              )).config.services.opentelemetry-collector.settings;
          in
          builtins.sort builtins.lessThan dual.service.pipelines."traces/route-ai".exporters == [
            "otlphttp/route-ai-general"
            "otlphttp/route-ai-langfuse"
          ]
          && dual.service.pipelines.traces.exporters == [ "otlphttp/general" ]
          && dual.exporters ? "otlphttp/route-ai-general"
          && dual.exporters ? "otlphttp/general"
        );
      # The local producer endpoint is readable only with a composed OTLP
      # capability, an admitted signal and a destination to carry it. The guard
      # is a read-time throw.
      telemetryEndpointGuardChecks =
        let
          # A composed realization that admits no signal: the guard is the same
          # option default either way, so one throw case stands for the family.
          # The admitted-signal-without-a-carrier branch is asserted, with its
          # named error, by the OTLP rejection leaf.
          unadmittedEndpoint = builtins.tryEval (pushOnlyEndpoint {
            withDestination = true;
          });
          # A scrape realization is not an OTLP push realization: it binds a
          # Prometheus receiver, never this endpoint. Reading the endpoint with
          # no OTLP push realization is what the option's own default refuses,
          # so this case carries the uncomposed read as well.
          scrapeOnlyEndpoint =
            builtins.tryEval
              (fixtureNixosSystem {
                inherit system;
                modules = [
                  inputs.sops-nix.nixosModules.sops
                  aspects.telemetry-otel-collector-scrape
                  ({ config, ... }: {
                    environment.variables.OTEL_EXPORTER_OTLP_ENDPOINT = config.services.telemetry.otlp.httpUrl;
                  })
                ];
              }).config.environment.variables.OTEL_EXPORTER_OTLP_ENDPOINT;
          pushEndpoint = builtins.tryEval (pushOnlyEndpoint {
            withSignals = true;
            withDestination = true;
          });
        in
        !unadmittedEndpoint.success
        && !scrapeOnlyEndpoint.success
        && pushEndpoint.success
        && pushEndpoint.value == "http://127.0.0.1:4318";

      # Contract and producer data stay inert without a realization.
      telemetryDormantDeclarationChecks =
        # A metrics realization consumes the unchanged registration shape only
        # when the realization aspect is composed.
        admissionAccepts [
          aspects.telemetry-vmagent
          {
            services.telemetry.scrape.app = {
              target = "127.0.0.1";
              port = 9100;
            };
            services.telemetry.destinations.local = {
              protocol = "prometheus-remote-write";
              endpoint = "http://metrics.invalid/api/v1/write";
              signals = [ "metrics" ];
            };
          }
        ]
        && admissionAccepts [
          aspects.telemetry
          {
            services.telemetry.scrape.app = {
              target = "127.0.0.1";
              port = 9100;
            };
            services.telemetry.destinations.local = {
              protocol = "prometheus-remote-write";
              endpoint = "http://metrics.invalid/api/v1/write";
              signals = [ "metrics" ];
            };
          }
        ]
        && admissionAccepts [
          ../../lib/telemetry-contract.nix
          {
            services.telemetry.scrape.app = {
              target = "127.0.0.1";
              port = 9100;
            };
          }
        ]
        && admissionAccepts [
          ../../lib/telemetry-contract.nix
          {
            services.telemetry.destinations.x = {
              protocol = "otlp-grpc";
              endpoint = "http://x.invalid:4317";
              signals = [ "traces" ];
            };
          }
        ]
        # vocabulary with an unused destination remains inert and valid.
        && admissionAccepts [
          aspects.telemetry
          { services.telemetry.destinations.x.endpoint = "http://x.invalid:4317"; }
        ]
        && admissionAccepts [ aspects.telemetry ];

      # Selecting a lane runs its realization, and a second loopback address or
      # an IPv6 spelling stays legal.
      telemetryLaneRealizationChecks =
        let
          # Read the admission result off a host that something else already
          # evaluated. `admissionAccepts` evaluates its own copy of the module
          # list, so using it for a case whose configuration is inspected anyway
          # pays for the same system twice.
          hostAccepts =
            host: (builtins.tryEval (lib.asserts.checkAssertWarn host.assertions host.warnings true)).success;
          vectorOnly = admissionEval [
            aspects.telemetry-logs
            {
              services.telemetry.journald = {
                includeUnits = [ "fixture-monitored" ];
                sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
              };
            }
          ];
          # The delivery-health registration the contract documents, evaluated as a
          # host: an ordinary scrape source like any other.
          deliveryHealthModules = [
            aspects.telemetry-metrics
            {
              services.telemetry.scrape.otel-collector-health = {
                target = "127.0.0.1";
                port = 9464;
              };
              services.telemetry.destinations.metrics = {
                protocol = "prometheus-remote-write";
                endpoint = "http://metrics.invalid/api/v1/write";
                signals = [ "metrics" ];
              };
            }
          ];
          deliveryHealthHost = admissionEval deliveryHealthModules;
          # A different loopback address is a different socket: the pair the gateway
          # runtime check binds (127.0.0.1 local, 127.0.0.2 ingress) has to stay
          # legal, or normalizing loopback aliases would over-reject a real gateway.
          distinctLoopbackModules = [
            aspects.telemetry-otlp
            {
              services.telemetry.otlp.signals = [ "traces" ];
              services.telemetry.otlp.ingress = {
                host = "127.0.0.2";
              };
              services.telemetry.destinations.traces = {
                protocol = "otlp-http";
                endpoint = "https://backend.invalid";
                signals = [ "traces" ];
              };
            }
          ];
          distinctLoopbackHost = admissionEval distinctLoopbackModules;
          # Raw and already-bracketed IPv6 spellings must produce usable URLs and
          # socket addresses on both receivers, not merely pass admission. Each
          # spelling is one system evaluation, admitted and inspected together.
          ipv6Bindings =
            lib.all
              (
                host:
                let
                  modules = [
                    aspects.telemetry-otlp
                    {
                      services.telemetry.otlp = {
                        inherit host;
                        signals = [ "traces" ];
                        ingress = {
                          host = "fd00::2";
                          httpPort = 4318;
                          grpcPort = 4317;
                        };
                      };
                      services.telemetry.destinations.traces = {
                        protocol = "otlp-http";
                        endpoint = "https://backend.invalid";
                        signals = [ "traces" ];
                      };
                    }
                  ];
                  c = (admissionEval modules).config;
                  receivers = c.services.opentelemetry-collector.settings.receivers;
                in
                hostAccepts c
                && c.services.telemetry.otlp.httpUrl == "http://[::1]:4318"
                && c.services.telemetry.otlp.grpcUrl == "http://[::1]:4317"
                && receivers.otlp.protocols.http.endpoint == "[::1]:4318"
                && receivers.otlp.protocols.grpc.endpoint == "[::1]:4317"
                && receivers."otlp/ingress".protocols.http.endpoint == "[fd00::2]:4318"
                && receivers."otlp/ingress".protocols.grpc.endpoint == "[fd00::2]:4317"
              )
              [
                "::1"
                "[::1]"
              ];
        in
        # Selecting the logs lane runs Vector without an explicit enable flag;
        # a valid sink and non-empty allowlist are still required. Which other
        # units that same composition leaves out is the capability matrix's
        # claim, so it is not repeated here.
        hostAccepts vectorOnly.config
        && vectorOnly.config.services.vector.enable
        # A composed metrics realization consumes the published health source; the
        # publishing registration does not compose another realization.
        && hostAccepts deliveryHealthHost.config
        && deliveryHealthHost.config.services.vmagent.enable
        && !deliveryHealthHost.config.services.opentelemetry-collector.enable
        && !(deliveryHealthHost.config.systemd.services ? opentelemetry-collector)
        && !(deliveryHealthHost.config.services.notify.events ? opentelemetry-collector)
        # a second, distinct loopback address is a distinct socket, not a collision,
        # and adding the gateway ingress adds neither remote scraping nor journald
        # shipping to that host
        && hostAccepts distinctLoopbackHost.config
        && !(distinctLoopbackHost.config.systemd.services ? vmagent)
        && !distinctLoopbackHost.config.services.vector.enable
        && !(distinctLoopbackHost.config.services.opentelemetry-collector.settings.receivers ? prometheus)
        && ipv6Bindings;

      # The journald provider's own fail-closed checks: forcing the rendered Vector
      # settings is what a host build does, so a bad value must fail there by name.
      vectorSettingsOf =
        telemetryConfig:
        (fixtureNixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            aspects.telemetry-vector
            { services.telemetry = telemetryConfig; }
          ];
        }).config.services.vector.settings;
      vectorRejects =
        telemetryConfig:
        !(builtins.tryEval (builtins.deepSeq (vectorSettingsOf telemetryConfig) true)).success;
      telemetryJournaldValidationChecks =
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
        # a selected logs lane still rejects an endpoint with no scheme by name
        && !(admissionAccepts [
          aspects.telemetry-logs
          {
            services.telemetry.journald = {
              includeAll = true;
              sink.endpoint = "victorialogs.invalid:9428/insert/jsonline";
            };
          }
        ])
        # the logs realization selects shipping, so an allowlist is what the host
        # still has to state: an empty one is the whole-journal footgun, refused
        # by its own name rather than resolved to "every unit".
        &&
          builtins.any (lib.hasPrefix "telemetry: journald shipping is enabled with an empty includeUnits")
            (admissionFailures [
              aspects.telemetry-logs
              {
                services.telemetry.journald = {
                  sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
                };
              }
            ])
        # includeAll with a list is contradictory, not a preference to resolve
        # silently in either direction
        &&
          builtins.any (lib.hasPrefix "telemetry: services.telemetry.journald.includeAll is true")
            (admissionFailures [
              aspects.telemetry-logs
              {
                services.telemetry.journald = {
                  includeAll = true;
                  includeUnits = [ "sshd.service" ];
                  sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
                };
              }
            ]);

      # The deliberate opt-in exports the whole journal, and renders no
      # include_units filter at all: an empty list would mean "no unit", so
      # "everything" has to be its own decision and its own rendering.
      telemetryJournaldRenderingChecks =
        admissionAccepts [
          aspects.telemetry-logs
          {
            services.telemetry.journald = {
              includeAll = true;
              sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
            };
          }
        ]
        && !(vectorSettingsOf {
          journald = {
            enable = true;
            includeAll = true;
            sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
          };
        }).sources.journald
          ? include_units
        # the journal read scope is Vector-equivalent and stated, not inherited
        # from a provider default that could move: the current boot only, so a
        # reboot does not replay older boots' unread records
        && (vectorSettingsOf {
          journald = {
            enable = true;
            includeUnits = [ "fixture-monitored" ];
            sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
          };
        }).sources.journald.current_boot_only;

      # Contract-only journald data is dormant, and metrics/traces composition
      # does not start the log shipper or publish its delivery health.
      telemetryJournaldIsolationChecks =
        # Contract-only journald values remain dormant without a logs realization.
        admissionAccepts [
          aspects.telemetry
          {
            services.telemetry.journald = {
              sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
            };
          }
        ]
        && admissionAccepts [
          aspects.telemetry
          {
            services.telemetry.destinations.dormant = {
              protocol = "otlp-http";
              endpoint = "https://dormant.invalid";
              signals = [ "logs" ];
              headers.Authorization.secret = "idleToken";
            };
            services.telemetry.secretFiles.idleToken = fixtureSecretFile;
            services.telemetry.secretKeys.idleToken = "unused/token";
          }
        ]
        && admissionAccepts [
          ../../lib/telemetry-contract.nix
          {
            services.telemetry.journald = {
              includeUnits = [ "fixture-monitored" ];
              sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
            };
          }
        ]
        # Selecting telemetry for metrics or traces must not start the log shipper
        # or publish its delivery health: both belong to the logs realization.
        && !vectorDisabledWithoutJournald.services.vector.enable
        && !(vectorDisabledWithoutJournald.services.telemetry.scrape ? vector-health)
        && !vectorDisabledWithoutJournald.services.vmagent.enable
        && vectorDisabledWithoutJournald.services.opentelemetry-collector.enable;
      # The scrape provider: the default vmagent translating every registered
      # job. Its contract is carried by three leaves so no single check forces
      # every throwaway host the provider touches.
      vmagentHost = vmagentHostFor system;

      # What each scrape realization renders: the default agent's jobs and
      # arguments, the explicit OTel scrape realization's receivers and
      # pipelines, and the health job a lane publishes for itself. A destination
      # with no registered scrape source is `vmagent-realization`'s `noOtel`
      # case, so that composition is asserted there and not evaluated here too.
      vmagentRenderedJobChecks =
        let
          remoteWrite = {
            protocol = "prometheus-remote-write";
            endpoint = "https://metrics.invalid/api/v1/write";
            signals = [ "metrics" ];
          };
          # The provider-owned health scrapes, named by their providers so the
          # targets can never drift from the listeners those units bind, with the
          # identity label each provider stamps on its own registration. Sorted
          # by job name like the rendering itself.
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
          otelScrape = telemetryHostFor system [ aspects.telemetry-otel-collector-scrape ] {
            scrape.app = {
              target = "127.0.0.1";
              port = 9187;
            };
            destinations.metrics = remoteWrite;
          };
        in
        # the default provider renders every scrape field into vmagent's own config
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
          ]
        # a metrics-only host runs the selected scrape provider and nothing else:
        # no OTel instance, no OTLP listener, no second scraper, no OTel failure
        # registration. A metrics destination alone is not OTLP admission.
        && !rendered.services.opentelemetry-collector.enable
        && !(rendered.systemd.services ? opentelemetry-collector)
        && rendered.services.opentelemetry-collector.settings == { }
        && !(rendered.services.notify.events ? opentelemetry-collector)
        # persistent StateDirectory queue, 1 GiB bound per destination, loopback
        # management endpoint, no firewall rule
        &&
          rendered.services.vmagent.extraArgs == [
            "-remoteWrite.url=https://metrics.invalid/api/v1/write"
            "-remoteWrite.tmpDataPath=%S/vmagent/remote_write_tmp"
            "-httpListenAddr=127.0.0.1:8429"
            "-remoteWrite.maxDiskUsagePerURL=1073741824"
          ]
        && rendered.systemd.services.vmagent.serviceConfig.StateDirectory == "vmagent"
        && rendered.services.vmagent.checkConfig
        && !rendered.services.vmagent.openFirewall
        && !(builtins.elem 8429 rendered.networking.firewall.allowedTCPPorts)
        && rendered.services.notify.events.vmagent.failure != null
        # The explicit scrape realization owns this host; it does not also start vmagent.
        && !(otelScrape.systemd.services ? vmagent)
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
        && !(otelScrape.services.opentelemetry-collector.settings.service.pipelines ? traces)
        && !(otelScrape.services.opentelemetry-collector.settings.service.pipelines ? logs)
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

      # Which units a composition realizes: a contract-only destination or a
      # producer-only host starts no agent, the logs lane ships without scraping,
      # and a bare scrape composition starts exactly vmagent with its health job.
      vmagentRealizationChecks =
        let
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
          contractOnlyDestination = contractHostFor system { destinations.metrics = remoteWrite; };
          producerOnly = telemetryHostFor system [
            ../../lib/telemetry-contract.nix
            aspects.node-exporter
          ] { };
          vectorOnlyJournald = telemetryHostFor system [ aspects.telemetry-vector ] {
            journald = {
              includeUnits = [ "fixture-monitored" ];
              sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
            };
          };
          noOtel = vmagentHost { destinations.metrics = remoteWrite; };
          journaldWithMetrics =
            telemetryHostFor system
              [
                aspects.telemetry-vector
                aspects.telemetry-vmagent
              ]
              {
                journald = {
                  includeUnits = [ "fixture-monitored" ];
                  sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
                };
                destinations.metrics = {
                  protocol = "prometheus-remote-write";
                  endpoint = "https://metrics.invalid/api/v1/write";
                  signals = [ "metrics" ];
                };
              };
          traceOnly = vmagentHost {
            otlp.signals = [ "traces" ];
            destinations.gateway = {
              protocol = "otlp-http";
              endpoint = "https://gateway.invalid";
              signals = [ "traces" ];
            };
          };
        in
        # The scrape realization owns vmagent and registers its own health job, so
        # a bare composition starts exactly that and nothing else.
        noOtel.services.vmagent.enable
        && noOtel.services.vmagent.prometheusConfig.scrape_configs == [ vmagentHealthJob ]
        && !noOtel.services.opentelemetry-collector.enable
        && !(noOtel.systemd.services ? opentelemetry-collector)
        && !noOtel.services.vector.enable
        # The logs lane starts the shipper and publishes health, but no scrape
        # consumer starts unless the metrics lane is also composed.
        && vectorOnlyJournald.services.vector.enable
        && builtins.hasAttr "vector-health" vectorOnlyJournald.services.telemetry.scrape
        && !vectorOnlyJournald.services.opentelemetry-collector.enable
        && !vectorOnlyJournald.services.vmagent.enable
        && !(vectorOnlyJournald.systemd.services ? vmagent)
        && traceOnly.services.vmagent.enable
        && traceOnly.services.vmagent.prometheusConfig.scrape_configs == [ vmagentHealthJob ]
        && builtins.attrNames traceOnly.services.telemetry.scrape == [ "vmagent-health" ]
        && !traceOnly.services.opentelemetry-collector.enable
        && !(traceOnly.systemd.services ? opentelemetry-collector)
        && !traceOnly.services.vector.enable
        && journaldWithMetrics.services.vector.settings.sources.internal_metrics.type == "internal_metrics"
        && journaldWithMetrics.services.vector.settings.sinks.vector-health.inputs == [ "internal_metrics" ]
        &&
          builtins.map (
            job: job.job_name
          ) journaldWithMetrics.services.vmagent.prometheusConfig.scrape_configs == [
            "vector-health"
            "vmagent-health"
          ]
        && !(journaldWithMetrics.services.telemetry.scrape ? app)
        # contract-only destinations are valid data but create no runtime.
        && !(contractOnlyDestination.systemd.services ? vmagent)
        && !(producerOnly.systemd.services ? vmagent);

      # The scrape provider's fail-closed guards: composing both scrape
      # implementations, and fanout mistakes that must fail by NAME rather than
      # as an unrelated evaluation error. Each probe host is evaluated once and
      # read twice, for its assertion messages and for its realized service.
      vmagentFanoutGuardChecks =
        let
          remoteWrite = {
            protocol = "prometheus-remote-write";
            endpoint = "https://metrics.invalid/api/v1/write";
            signals = [ "metrics" ];
          };
          fanoutFailuresOf =
            host:
            map (assertion: assertion.message) (
              builtins.filter (assertion: !assertion.assertion) host.assertions
            );
          # Composing both implementations of the scrape signal is an explicit
          # arbitration error, irrespective of whether either has export work.
          duplicateScrapeRealizations =
            telemetryRejects
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
          unwritableFanout = {
            scrape.app = {
              target = "127.0.0.1";
              port = 9187;
            };
            destinations.plain = {
              protocol = "otlp-grpc";
              endpoint = "http://gateway.invalid:4317";
              signals = [ "metrics" ];
            };
          };
          emptyFanout = {
            scrape.app = {
              target = "127.0.0.1";
              port = 9187;
            };
          };
          # A literal the adapter would render into its own comma-separated argument
          # array, so it has to be refused while it is still visible at build time.
          hostileEndpoint = {
            scrape.app = {
              target = "127.0.0.1";
              port = 9187;
            };
            destinations.metrics = remoteWrite // {
              endpoint = "https://metrics.invalid/api/v1/write?tenant=a,b";
            };
          };
          hostileHeader = {
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
          # A secret id with a structural character is refused as well, but by the
          # contract's own id charset (letters, digits, underscores) rather than by
          # this adapter — which is what lets the adapter interpolate
          # `%{VMAGENT_<id>}` into its argument without a check of its own.
          unwritable = vmagentHost unwritableFanout;
          empty = vmagentHost emptyFanout;
          hostileEndpointHost = vmagentHost hostileEndpoint;
          hostileHeaderHost = vmagentHost hostileHeader;
        in
        duplicateScrapeRealizations
        # a selected metrics destination vmagent cannot write to fails by name,
        # the selected service remains present while named assertions reject bad fanout
        && builtins.any (lib.hasPrefix "telemetry: the metrics pipeline selects") (
          fanoutFailuresOf unwritable
        )
        && unwritable.services.vmagent.enable
        # so does a scrape source with no metrics destination to land in
        && builtins.any (lib.hasPrefix "telemetry: scrape sources are registered but the metrics pipeline") (
          fanoutFailuresOf empty
        )
        && empty.services.vmagent.enable
        # and so does a LITERAL value the remote-write argument parser would treat as
        # structure: a comma in an endpoint or header prefix would otherwise shift
        # arguments onto the next destination, so it fails while it is visible
        && builtins.any (lib.hasPrefix "telemetry: the metrics pipeline selects") (
          fanoutFailuresOf hostileEndpointHost
        )
        && hostileEndpointHost.services.vmagent.enable
        && builtins.any (lib.hasPrefix "telemetry: the metrics pipeline selects") (
          fanoutFailuresOf hostileHeaderHost
        )
        && hostileHeaderHost.services.vmagent.enable
        && builtins.any (lib.hasPrefix "telemetry: the metrics pipeline selects values vmagent's argument parser") (
          fanoutFailuresOf hostileEndpointHost
        )
        && builtins.any (lib.hasPrefix "telemetry: the metrics pipeline selects values vmagent's argument parser") (
          fanoutFailuresOf hostileHeaderHost
        );

      # Selecting telemetry for metrics or traces must not start a log shipper.
      vectorDisabledWithoutJournald =
        (fixtureNixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            aspects.telemetry-otlp
            {
              services.telemetry.otlp.signals = [ "traces" ];
              services.telemetry.destinations.plain = {
                protocol = "otlp-grpc";
                endpoint = "http://gateway.invalid:4317";
                signals = [ "traces" ];
              };
            }
          ];
        }).config;

      buildAccountTrustChecks =
        let
          evaluated =
            modules:
            (fixtureNixosSystem {
              inherit system;
              inherit modules;
            }).config;
          renamed = evaluated [
            aspects.build-account
            {
              services.build-account.name = "dispatcher";
              nix.settings.trusted-users = [ "existing-coordinator" ];
            }
          ];
        in
        # The dispatch identity the consumer declares is what has to be trusted,
        # and the consumer's own entry survives the merge. The default name and
        # nixpkgs' `root` entry are the aspect's own literal and the platform's
        # baseline, not claims about a consumer's host.
        lib.elem renamed.services.build-account.name renamed.nix.settings.trusted-users
        && lib.elem "existing-coordinator" renamed.nix.settings.trusted-users;

      tailscaleAutoconnectChecks =
        let
          units =
            extra:
            (fixtureNixosSystem {
              inherit system;
              modules = [
                inputs.sops-nix.nixosModules.sops
                aspects.tailscale
                extra
              ];
            }).config.systemd.units;
          unbound = units { };
          bound = units { services.tailscale.secretFiles.auth = ./fixture.nix; };
        in
        # Unbound, no autoconnect unit exists at all; a unit holding only the
        # ordering drop-in has no ExecStart and warns on every boot. Bound, the
        # unit carries nixpkgs' script and the sops ordering together.
        !(unbound ? "tailscaled-autoconnect.service")
        && lib.hasInfix "ExecStart=" bound."tailscaled-autoconnect.service".text
        && lib.hasInfix "sops-install-secrets.service" bound."tailscaled-autoconnect.service".text;

      nixGcChecks =
        let
          evaluated =
            extra:
            (fixtureNixosSystem {
              inherit system;
              modules = [
                inputs.sops-nix.nixosModules.sops
                aspects.nix-gc
                # The notify aspect owns the fail-closed rule this leaf tests: a
                # registration may only name a unit with a real service.
                aspects.notify
                extra
              ];
            }).config;
          defaults = evaluated { };
          # Every unit off at once: the update that removes the schedule. The
          # checks below read what the composition produced — rendered units and
          # the registration set — because an override that only sets option
          # values cannot show a registration that outlived its unit.
          disabled = evaluated {
            programs.nh.clean.enable = false;
            services.fast-nix-gc.enable = false;
            services.fast-nix-optimise.enable = false;
          };
          # One flag off while the others stay on: the shape a consumer override
          # actually takes, and the only case that discriminates a registration
          # wired to a sibling's flag — with every flag off, a mis-wired
          # registration is absent for the wrong reason and passes.
          optimiseOff = evaluated { services.fast-nix-optimise.enable = false; };
        in
        # Every unit the aspect owns registers its own failure. The schedules,
        # weights and package the units carry are the aspect's own defaults on
        # the upstream options, restated in `modules/maintenance/nix-gc.nix`.
        (defaults.services.notify.events ? "nh-clean")
        && (defaults.services.notify.events ? "fast-nix-gc")
        && (defaults.services.notify.events ? "fast-nix-optimise")
        # Turning a unit off is the override the contract invites, so it must
        # leave no trace. Two defects this catches: a registration left behind
        # with no unit to attach to, and the ordering drop-in on its own, which
        # renders a phantom `nh-clean` with no ExecStart (the same failure class
        # as the unconditional `tailscaled-autoconnect`).
        && !(disabled.systemd.units ? "nh-clean.service")
        && !(disabled.services.notify.events ? "nh-clean")
        && !(disabled.services.notify.events ? "fast-nix-gc")
        && !(disabled.services.notify.events ? "fast-nix-optimise")
        # One flag off, the others on: only that unit's registration goes. A
        # registration wired to a sibling's flag survives the all-off case and
        # fails here.
        && !(optimiseOff.systemd.units ? "fast-nix-optimise.service")
        && !(optimiseOff.services.notify.events ? "fast-nix-optimise")
        && (optimiseOff.services.notify.events ? "nh-clean")
        && (optimiseOff.services.notify.events ? "fast-nix-gc")
        # The symptom in notify's own words, so this leaf fails the way a
        # consumer's build did.
        && !(lib.any (
          assertion:
          !assertion.assertion && lib.hasInfix "has no systemd service implementation" assertion.message
        ) disabled.assertions);

      nodeExporterIdentityChecks =
        # The label is consumer-owned: a value the consumer declares wins over
        # the label the aspect derives from the host name and the bound port. The
        # derived label is read off the fixture host's composed registration,
        # which couples it to the exporter's own bind.
        (fixtureNixosSystem {
          inherit system;
          modules = [
            aspects.node-exporter
            {
              networking.hostName = "other-probe";
              services.telemetry.scrape.node.labels.instance = "consumer-owned";
            }
          ];
        }).config.services.telemetry.scrape.node.labels.instance == "consumer-owned";

      # The alerting aspect's own contract: an enabled vmalert instance without a
      # datasource, a notifier or a management bind is refused by name, per
      # instance. The unbound composition is the aspect's own default, and the
      # bound instance's registration is the host's alerting→notify seam.
      alertingAdmissionChecks =
        builtins.any (lib.hasPrefix "vmalert: instance(s) 'unbound-notifier'") (admissionFailures [
          aspects.vmalert
          {
            services.vmalert.instances.unbound-notifier = {
              enable = true;
              settings."datasource.url" = "http://127.0.0.1:8428";
            };
          }
        ])
        && builtins.any (lib.hasPrefix "vmalert: instance(s) 'unbound-datasource'") (admissionFailures [
          aspects.vmalert
          { services.vmalert.instances.unbound-datasource.enable = true; }
        ])
        && builtins.any (lib.hasPrefix "vmalert: instance(s) 'unbound-management'") (admissionFailures [
          aspects.vmalert
          {
            services.vmalert.instances.unbound-management = {
              enable = true;
              settings = {
                "datasource.url" = "http://127.0.0.1:8428";
                "notifier.url" = [ "http://127.0.0.1:9093" ];
              };
            };
          }
        ]);
      # The substitution catalog is a fleet-owned baseline, not an option surface:
      # a consumer appends through nix.conf's own extra-substituters key, or
      # replaces the list outright with mkForce. Both seams are exercised here so
      # neither can rot into an option nothing renders again.
      nixBaselineSubstitutionSeams =
        let
          settingsFor =
            extra:
            (admissionEval [
              aspects.nix-baseline
              extra
            ]).config.nix.settings;
          base = settingsFor { };
          appended = settingsFor {
            nix.settings."extra-substituters" = [ "https://appended.invalid" ];
            nix.settings."extra-trusted-public-keys" = [ "appended.invalid-1:AAAA" ];
          };
          replaced = settingsFor {
            nix.settings.substituters = lib.mkForce [ "https://replaced.invalid" ];
          };
        in
        # Appending is a key of its own, so the baseline list and the baseline's
        # own keys must survive it; replacing is explicit and drops the baseline
        # entries rather than unioning them with it. The catalog's contents are
        # fleet data owned by `modules/system/nix-baseline.nix`.
        appended.substituters == base.substituters
        && appended."trusted-public-keys" == base."trusted-public-keys"
        && appended."extra-substituters" == [ "https://appended.invalid" ]
        && appended."extra-trusted-public-keys" == [ "appended.invalid-1:AAAA" ]
        && replaced.substituters == [ "https://replaced.invalid" ];
    in
    {
      # One named leaf per contract evaluation, each carried by its own check so
      # the fixture host above never forces it. A leaf that fails throws the
      # named error at evaluation, which is why every message reads as the
      # contract that broke rather than as a generic check failure.
      build-account-trust = {
        message = "build-account: dispatch trust, account renaming or trusted-user merging regressed";
        ok = buildAccountTrustChecks;
      };
      tailscale-autoconnect = {
        message = "tailscale: the autoconnect unit is rendered without an auth key, or lost its ordering";
        ok = tailscaleAutoconnectChecks;
      };
      nix-baseline-substitution = {
        message = "nix-baseline: the append or mkForce-replace seam of the substitution catalog regressed";
        ok = nixBaselineSubstitutionSeams;
      };
      nix-gc-defaults = {
        message = "nix-gc: a unit's failure registration no longer follows its enable flag, or turning the units off left a trace";
        ok = nixGcChecks;
      };
      alerting-admission = {
        message = "alerting: vmalert no longer refuses an enabled instance without a datasource, a notifier or a management bind, by name and per instance";
        ok = alertingAdmissionChecks;
      };
      telemetry-mutation-rejections = {
        message = "telemetry: a destination, fanout or secret mistake no longer fails closed";
        ok = telemetryMutationRejectionChecks;
      };
      telemetry-provider-rejections = {
        message = "telemetry: a provider-specific scrape or resource mistake no longer fails closed";
        ok = telemetryProviderRejectionChecks;
      };
      telemetry-routes = {
        message = "telemetry: explicit route selection no longer isolates general and AI-session destinations";
        ok = telemetryRouteChecks;
      };
      telemetry-otlp-rejections = {
        message = "telemetry: an OTLP admission or producer-listener rejection is missing, misnamed or no longer rejects";
        ok = telemetryOtlpRejectionChecks;
      };
      telemetry-ingress-rejections = {
        message = "telemetry: an ingress-listener rejection is missing, misnamed or no longer rejects";
        ok = telemetryIngressRejectionChecks;
      };
      telemetry-listener-collisions = {
        message = "telemetry: a same-socket ingress collision is no longer rejected";
        ok = telemetryListenerCollisionChecks;
      };
      telemetry-credential-rejections = {
        message = "telemetry: a credential binding rejection is missing, misnamed or no longer rejects";
        ok = telemetryCredentialRejectionChecks;
      };
      telemetry-endpoint-guard = {
        message = "telemetry: producer endpoint derivation or its read-time guard regressed";
        ok = telemetryEndpointGuardChecks;
      };
      telemetry-dormant-declarations = {
        message = "telemetry: contract or producer declarations are no longer dormant without a realization";
        ok = telemetryDormantDeclarationChecks;
      };
      telemetry-lane-realization = {
        message = "telemetry: selecting a lane no longer runs its realization, or a legal loopback binding regressed";
        ok = telemetryLaneRealizationChecks;
      };
      telemetry-capability-matrix = {
        message = "telemetry: explicit capability composition regressed";
        ok = telemetryCapabilityMatrixChecks;
      };
      telemetry-journald-contract = {
        message = "telemetry: the journald shipping validation or rendered Vector settings regressed";
        ok = telemetryJournaldValidationChecks;
      };
      telemetry-journald-isolation = {
        message = "telemetry: journald contract data or lane isolation from the collector regressed";
        ok = telemetryJournaldRenderingChecks && telemetryJournaldIsolationChecks;
      };
      otel-collector-resource-order = {
        message = "otel-collector: a declared resource processor no longer reaches the pipeline order";
        ok =
          collectorManualResourceOrder == [
            "memory_limiter"
            "resource"
          ];
      };
      otel-collector-unbound-secrets = {
        message = "otel-collector: an unbound credential still registers a secret or an EnvironmentFile";
        ok = collectorUnboundSecrets;
      };
      otel-collector-inactive-credentials = {
        message = "otel-collector: a dormant destination's bound credential leaked an exporter, secret or override";
        ok = collectorInactiveCredentials;
      };
      vmagent-rendered-jobs = {
        message = "vmagent: the rendered scrape jobs, arguments or queue bounds regressed";
        ok = vmagentRenderedJobChecks;
      };
      vmagent-realization = {
        message = "vmagent: provider selection or the units a composition realizes regressed";
        ok = vmagentRealizationChecks;
      };
      vmagent-fanout-guards = {
        message = "vmagent: a scrape arbitration or fanout mistake no longer fails by name";
        ok = vmagentFanoutGuardChecks;
      };
      node-exporter-identity = {
        message = "node-exporter: a consumer's scrape instance label no longer wins over the aspect's own derivation";
        ok = nodeExporterIdentityChecks;
      };
    };

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
        alertmanager
        beszel-agent
        bifrost
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

      sops.age.keyFile = fixtureAgeKeyFile;

      # Composition guard: only emergent cross-aspect properties belong here —
      # a claim no single aspect owns and that plain option evaluation cannot
      # falsify. Restating an aspect's own literal is owned by that aspect.
      assertions = [
        {
          # Emergent property of the consumer wiring: the projection the
          # flake-level API returns is what this host rendered. What the
          # projection contains is the fleet-render check's claim.
          assertion = config.nix.buildMachines != [ ] && config.programs.ssh.knownHosts != { };
          message = "fixture: the consumer build-profile wiring reached no build machine or known host.";
        }
        {
          assertion =
            cacheApiUrl == "http://oci-melb-1:5751" && cacheApiUrlMutated == "http://oci-melb-1:5752";
          message = "fixture: the CI cache URL is not derived from the niks3-write record.";
        }
        {
          assertion =
            config.systemd.services.fixture-monitored.onFailure == [ "notify-event@fixture-monitored.service" ];
          message = "fixture: the notification aspect attached no native failure hook for a registered unit.";
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
            &&
              settings.exporters."prometheusremotewrite/archive".headers.Authorization
              == "Bearer \${env:OTELCOL_metricsToken}"
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
            # receives neither metrics nor logs from the default fanout; the
            # metrics fanout is an explicit selection of the remote-write stores
            # only, so the OTLP gateway that also accepts metrics receives none.
            &&
              settings.service.pipelines.metrics.exporters == [
                "prometheusremotewrite/victoria"
                "prometheusremotewrite/archive"
              ]
            && settings.service.pipelines.logs.exporters == [ "otlp/plain" ]
            && !(builtins.elem "otlphttp/secure" settings.service.pipelines.metrics.exporters)
            && !(builtins.elem "otlphttp/secure" settings.service.pipelines.logs.exporters)
            && !(builtins.elem "otlp/plain" settings.service.pipelines.metrics.exporters)
            && !(builtins.elem "prometheusremotewrite/victoria" settings.service.pipelines.traces.exporters)
            # No standalone pre-export batch processor: acceptance commits to
            # the exporter's own persistent queue instead of to a volatile
            # batch stage.
            && !(settings.processors ? batch)
            && !(builtins.elem "batch" settings.service.pipelines.traces.processors)
            &&
              settings.service.pipelines.traces.processors == [
                "memory_limiter"
                "resource"
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
            # Persistent delivery: one exporterhelper queue per OTLP exporter,
            # fsync'd file storage under the unit's state directory, a finite
            # serialized-payload capacity and indefinite retry — never the
            # unsupported (in the pin) file_storage database cap.
            # The production queue path is only durable because it is the unit's
            # own StateDirectory, and DynamicUser is what makes it writable
            # without an owner. Assert the coupling, not the literal against
            # itself: a nixpkgs StateDirectory change must fail here rather than
            # leave every offline check green over a queue that cannot persist.
            &&
              settings.extensions.file_storage.directory
              == "/var/lib/${config.systemd.services.opentelemetry-collector.serviceConfig.StateDirectory}/queue"
            && config.systemd.services.opentelemetry-collector.serviceConfig.DynamicUser
            && settings.extensions.file_storage.fsync
            && settings.extensions.file_storage.create_directory
            && settings.extensions.file_storage.directory_permissions == "0700"
            && settings.extensions.file_storage.compaction.on_start
            && settings.extensions.file_storage.compaction.on_rebound
            && !(settings.extensions.file_storage ? max_size)
            && settings.service.extensions == [ "file_storage" ]
            &&
              builtins.all
                (
                  exporter:
                  exporter.sending_queue.sizer == "bytes"
                  && exporter.sending_queue.queue_size == 268435456
                  && exporter.sending_queue.storage == "file_storage"
                  && exporter.sending_queue.block_on_overflow == false
                  && exporter.sending_queue.batch == { }
                  && exporter.retry_on_failure.max_elapsed_time == 0
                )
                [
                  settings.exporters."otlphttp/secure"
                  settings.exporters."otlp/plain"
                ]
            # The Prometheus remote-write exporter rejects `sending_queue` in
            # Collector Contrib 0.155.0, so it persists through its own WAL and
            # keeps its finite queue there.
            && !(settings.exporters."prometheusremotewrite/victoria" ? sending_queue)
            &&
              lib.hasPrefix settings.extensions.file_storage.directory
                settings.exporters."prometheusremotewrite/victoria".wal.directory
            &&
              settings.exporters."prometheusremotewrite/victoria".wal.directory
              == "/var/lib/opentelemetry-collector/queue/wal-victoria"
            && settings.exporters."prometheusremotewrite/victoria".remote_write_queue.enabled
            && settings.exporters."prometheusremotewrite/victoria".retry_on_failure.max_elapsed_time == 0
            # Delivery health: explicit loopback metrics, never the implicit
            # port 8888 listener.
            &&
              settings.service.telemetry.metrics.readers == [
                {
                  pull.exporter.prometheus = {
                    host = "127.0.0.1";
                    port = 9464;
                  };
                }
              ]
            && !(settings.service.telemetry.metrics ? address)
            && !(builtins.elem 8888 config.networking.firewall.allowedTCPPorts)
            && !(builtins.elem 9464 config.networking.firewall.allowedTCPPorts)
            # The additional network ingress is a distinct receiver feeding the
            # same exporter IDs, with source-specific pipelines: local
            # enrichment never relabels forwarded telemetry.
            && settings.receivers."otlp/ingress".protocols.http.endpoint == "100.64.0.9:4318"
            && !(settings.receivers."otlp/ingress".protocols ? grpc)
            && telemetry.otlp.httpUrl == "http://127.0.0.1:4318"
            && telemetry.otlp.grpcUrl == "http://127.0.0.1:4317"
            && settings.service.pipelines."traces/ingress".receivers == [ "otlp/ingress" ]
            &&
              settings.service.pipelines."traces/ingress".exporters == settings.service.pipelines.traces.exporters
            && !(builtins.elem "resource" settings.service.pipelines."traces/ingress".processors)
            && builtins.elem "resource" settings.service.pipelines.traces.processors
            && settings.service.pipelines."metrics/ingress".receivers == [ "otlp/ingress" ]
            && settings.service.pipelines."logs/ingress".receivers == [ "otlp/ingress" ]
            && !(config.systemd.services ? "otlp-ingress");
          message = "fixture: the rendered telemetry receiver, exporter, processor, pipeline or ingress set regressed.";
        }
        {
          # The host-local contract: the OTLP endpoint producers read must be
          # the receiver the collector actually binds, and the collector serves
          # only the inputs it was composed for — the metrics lane's scrape
          # realization owns scraping, so this collector has no prometheus
          # receiver and no `metrics/scrape` pipeline.
          assertion =
            let
              otlp = config.services.telemetry.otlp;
              settings = config.services.opentelemetry-collector.settings;
            in
            otlp.httpUrl == "http://127.0.0.1:4318"
            && otlp.grpcUrl == "http://127.0.0.1:4317"
            # The declared ingress address is what the additional listener binds,
            # while the producer endpoints above stay loopback. Asserting the
            # address as an input would restate the fixture's own module argument;
            # asserting the listener it produces is the coupling.
            && lib.hasPrefix "${otlp.ingress.host}:" settings.receivers."otlp/ingress".protocols.http.endpoint
            && settings.receivers.otlp.protocols.http.endpoint == "${otlp.host}:${toString otlp.httpPort}"
            && settings.receivers.otlp.protocols.grpc.endpoint == "${otlp.host}:${toString otlp.grpcPort}"
            # Configuring network ingress does not move the local producer
            # endpoints: they stay loopback, and the extra listener is separate.
            && lib.hasPrefix "http://127.0.0.1:" otlp.httpUrl
            && lib.hasPrefix "http://127.0.0.1:" otlp.grpcUrl
            && !(settings.receivers ? prometheus)
            && settings.service.pipelines.metrics.receivers == [ "otlp" ]
            && settings.service.pipelines.traces.receivers == [ "otlp" ]
            && settings.service.pipelines.logs.receivers == [ "otlp" ]
            &&
              builtins.attrNames settings.service.pipelines == [
                "logs"
                "logs/ingress"
                "metrics"
                "metrics/ingress"
                "traces"
                "traces/ingress"
              ];
          message = "fixture: the telemetry scrape registration, local OTLP endpoint, or composed pipeline contract regressed.";
        }
        {
          # The vmagent realization owns its unit: every registered job in
          # its config, a bounded persistent queue, a loopback management
          # endpoint, and the credential binding its remote-write headers need.
          assertion =
            let
              vmagent = config.services.vmagent;
              unit = config.systemd.services.vmagent;
            in
            vmagent.enable
            # The build-time `-dryRun` check validates this YAML with the real
            # binary; keeping it on is what makes a malformed registration a
            # build failure.
            && vmagent.checkConfig
            &&
              vmagent.prometheusConfig.scrape_configs == [
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
                  metrics_path = "/metrics/extra";
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
                      labels.instance = "${config.networking.hostName}:9100";
                    }
                  ];
                }
                {
                  # The collector's own delivery-health endpoint, registered
                  # through the ordinary producer interface: exposing those
                  # metrics here starts no second provider — the collector owns
                  # no scraper and the target is the listener nixpkgs' unit
                  # binds.
                  job_name = "otel-collector-health";
                  metrics_path = "/metrics";
                  scheme = "http";
                  scrape_interval = "30s";
                  static_configs = [
                    {
                      targets = [ "127.0.0.1:9464" ];
                      labels.instance = "${config.networking.hostName}:otel-collector";
                    }
                  ];
                }
                {
                  # The Vector provider's loopback health listener, registered
                  # by the provider that binds it. The target is the
                  # prometheus_exporter sink below, which carries only Vector's
                  # own internal metrics.
                  job_name = "vector-health";
                  metrics_path = "/metrics";
                  scheme = "http";
                  scrape_interval = "30s";
                  static_configs = [
                    {
                      targets = [ "127.0.0.1:9598" ];
                      labels.instance = "${config.networking.hostName}:vector";
                    }
                  ];
                }
                {
                  # vmagent's own loopback management endpoint, registered the
                  # same way: the selected scrape provider collects its own
                  # backlog and send-error metrics.
                  job_name = "vmagent-health";
                  metrics_path = "/metrics";
                  scheme = "http";
                  scrape_interval = "30s";
                  static_configs = [
                    {
                      targets = [ "127.0.0.1:8429" ];
                      labels.instance = "${config.networking.hostName}:vmagent";
                    }
                  ];
                }
              ]
            &&
              (builtins.elemAt config.services.opentelemetry-collector.settings.service.telemetry.metrics.readers 0)
              .pull.exporter.prometheus.port == config.services.telemetry.scrape.otel-collector-health.port
            && !(config.services.opentelemetry-collector.settings.receivers ? prometheus)
            # One remote-write target per selected metrics destination, in
            # pipeline order: URL, then the shared queue path and loopback
            # listen, then the per-destination disk bound and headers (the
            # empty entry is the headerless destination's slot).
            &&
              vmagent.extraArgs == [
                "-remoteWrite.url=http://metrics.invalid/api/v1/write"
                "-remoteWrite.url=https://archive.invalid/api/v1/write"
                "-remoteWrite.tmpDataPath=%S/vmagent/remote_write_tmp"
                "-httpListenAddr=127.0.0.1:8429"
                "-remoteWrite.maxDiskUsagePerURL=1073741824"
                "-remoteWrite.maxDiskUsagePerURL=1073741824"
                "-remoteWrite.headers="
                "-remoteWrite.headers=Authorization: Bearer %{VMAGENT_metricsToken}"
              ]
            && unit.serviceConfig.StateDirectory == "vmagent"
            && lib.hasInfix "-httpListenAddr=127.0.0.1:8429" unit.serviceConfig.ExecStart
            && lib.hasInfix "-remoteWrite.tmpDataPath=%S/vmagent/remote_write_tmp" unit.serviceConfig.ExecStart
            && !vmagent.openFirewall
            && !(builtins.elem 8429 config.networking.firewall.allowedTCPPorts)
            && config.services.notify.events.vmagent.failure != null
            && unit.onFailure != [ ]
            # Only the destination that actually carries a header binds a
            # secret; the credential reaches the unit through the environment,
            # never through the store or the command line.
            && config.sops.secrets."vmagent/metricsToken".sopsFile == fixtureSecretFile
            && config.sops.secrets."vmagent/metricsToken".key == "metrics/token"
            && builtins.elem "vmagent.service" config.sops.secrets."vmagent/metricsToken".restartUnits
            && builtins.elem "vmagent.service" config.sops.templates."vmagent.env".restartUnits
            &&
              config.sops.templates."vmagent.env".content
              == "VMAGENT_metricsToken=${config.sops.placeholder."vmagent/metricsToken"}\n"
            && unit.serviceConfig.EnvironmentFile == [ config.sops.templates."vmagent.env".path ]
            # The credential only becomes readable at unit start, so the guard
            # runs there, before vmagent parses the argument array it indexes
            # headers into.
            && builtins.length unit.serviceConfig.ExecStartPre == 1
            && lib.hasInfix "VMAGENT_metricsToken" (builtins.head unit.serviceConfig.ExecStartPre);
          message = "fixture: the vmagent scrape provider's rendered jobs, bounded queue, loopback listen, credential binding, or notify ownership regressed.";
        }
        {
          # The node-exporter aspect owns the exporter, the loopback bind and
          # its own scrape registration, so the registration has to track
          # whatever this host binds — nixpkgs renders the listen address, the
          # aspect names the target — and the bound port stays off the firewall.
          # The notify hook is the registration contract's representative case,
          # asserted once, in the fixture-monitored block.
          assertion =
            let
              node = config.services.prometheus.exporters.node;
              unit = config.systemd.services."prometheus-node-exporter";
              scrape = config.services.telemetry.scrape.node;
            in
            scrape.target == node.listenAddress
            && scrape.port == node.port
            && scrape.labels.instance == "${config.networking.hostName}:${toString node.port}"
            && lib.hasInfix "--web.listen-address ${node.listenAddress}:${toString node.port}" unit.serviceConfig.ExecStart
            && !(builtins.elem node.port config.networking.firewall.allowedTCPPorts);
          message = "fixture: the node-exporter scrape registration no longer tracks the exporter's own bind, or the bound port reached the firewall.";
        }
        {
          # The two Vector sinks must not become one: the log sink carries
          # systemd-journal records and nothing else, the health exporter only
          # Vector's own internal metrics. Every other value in these settings
          # is the aspect's own literal, or the consumer's own input rendered
          # back — the journald leaves own the validation and the rendering of
          # the opt-in scope.
          assertion =
            let
              sinks = config.services.vector.settings.sinks;
            in
            sinks.logs.inputs == [ "journald" ] && sinks.vector-health.inputs == [ "internal_metrics" ];
          message = "fixture: a Vector sink took the other lane's inputs — the health exporter became a second log path, or the log sink lost its journal-only input.";
        }
        {
          # Each active credential reaches the unit through its own placeholder
          # in the rendered environment, and the unit restarts for the secrets
          # it reads. The sopsFile/key bindings are the consumer's own inputs,
          # and the notify hook is the registration contract's representative
          # case, asserted in the fixture-monitored block.
          assertion =
            let
              template = config.sops.templates."otel-collector.env";
            in
            # The env file binds exactly the active credentials, each to its own
            # placeholder. Line order is not part of the contract, so compare
            # the lines as a set rather than pinning the provider's iteration
            # order.
            lib.sort (a: b: a < b) (lib.splitString "\n" (lib.removeSuffix "\n" template.content))
            == lib.sort (a: b: a < b) [
              "OTELCOL_token=${config.sops.placeholder."otel-collector/token"}"
              "OTELCOL_metricsToken=${config.sops.placeholder."otel-collector/metricsToken"}"
            ]
            && builtins.elem "opentelemetry-collector.service" template.restartUnits
            &&
              builtins.elem "opentelemetry-collector.service"
                config.sops.secrets."otel-collector/token".restartUnits
            &&
              config.systemd.services.opentelemetry-collector.serviceConfig.EnvironmentFile == [
                template.path
              ];
          message = "fixture: the otel-collector environment no longer maps each active credential to its own placeholder, or the unit is not restarted for the secrets it reads.";
        }
        {
          # The alerting path end to end: vmalert renders the consumer's rule
          # file and points at the bound datasource and notifier; Alertmanager
          # listens on loopback with the configuration the build checked, and
          # its webhook receiver posts back into the notify daemon's own
          # Alertmanager route; both units register their failure.
          assertion =
            let
              vmalertUnit = config.systemd.services."vmalert-fixture";
              alertmanagerUnit = config.systemd.services.alertmanager;
              alertmanager = config.services.prometheus.alertmanager;
              receiverUrl =
                (builtins.head (builtins.head alertmanager.configuration.receivers).webhook_configs).url;
            in
            config.services.vmalert.instances.fixture.enable
            && lib.hasInfix "-datasource.url=http://127.0.0.1:8428" vmalertUnit.serviceConfig.ExecStart
            && lib.hasInfix "-notifier.url=http://127.0.0.1:9093" vmalertUnit.serviceConfig.ExecStart
            && lib.hasInfix "-httpListenAddr=127.0.0.1:8880" vmalertUnit.serviceConfig.ExecStart
            && lib.hasInfix "-rule=/etc/vmalert-fixture/rules.yml" vmalertUnit.serviceConfig.ExecStart
            && lib.hasInfix "FixtureWatchdog" (
              builtins.toJSON config.environment.etc."vmalert-fixture/rules.yml".source.value
            )
            && config.services.notify.events."vmalert-fixture".failure != null
            && vmalertUnit.onFailure != [ ]
            && alertmanager.enable
            && alertmanager.listenAddress == "127.0.0.1"
            && alertmanager.checkConfig
            && !alertmanager.openFirewall
            &&
              receiverUrl == "http://127.0.0.1:${toString config.services.notify.port}/alertmanager?topic=infra"
            && lib.hasInfix "--web.listen-address 127.0.0.1:9093" alertmanagerUnit.serviceConfig.ExecStart
            && config.services.notify.events.alertmanager.failure != null
            && alertmanagerUnit.onFailure != [ ];
          message = "fixture: the alerting path (vmalert's bound datasource/notifier and rendered rules, alertmanager's loopback bind, checked config, webhook receiver, or either unit's notify ownership) regressed.";
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
              infra = "2";
              fleet = "4";
            };
            defaultTopic = "fleet";
          };

          ntfy = {
            enable = true;
            serverUrl = "http://127.0.0.1:8082";
            topics = {
              infra = "infra";
              fleet = "fleet";
            };
            defaultTopic = "fleet";
          };
        };

        tailscale.secretFiles.auth = fixtureSecretFile;

        # The consumer owns every binding below: the alertmanager aspect
        # contributes the loopback default and the failure registration, the
        # vmalert aspect the validation and the registrations — neither enables
        # anything on its own.
        prometheus.alertmanager = {
          enable = true;
          configuration = {
            route = {
              receiver = "notify";
              group_by = [ "alertname" ];
            };
            receivers = [
              {
                name = "notify";
                webhook_configs = [
                  {
                    # The receiver is the notify daemon's Alertmanager route,
                    # on the topic the routing policy declares.
                    url = "http://127.0.0.1:${toString config.services.notify.port}/alertmanager?topic=infra";
                  }
                ];
              }
            ];
          };
        };

        vmalert.instances.fixture = {
          enable = true;
          settings = {
            "datasource.url" = "http://127.0.0.1:8428";
            "notifier.url" = [ "http://127.0.0.1:9093" ];
            # The management endpoint is bound explicitly: the aspect refuses an
            # instance that would otherwise inherit vmalert's all-interface
            # default.
            "httpListenAddr" = "127.0.0.1:8880";
          };
          # A trivial always-firing watchdog: the rule file the fixture host's
          # unit loads.
          rules.groups = [
            {
              name = "fixture";
              rules = [
                {
                  alert = "FixtureWatchdog";
                  expr = "vector(1)";
                  for = "0m";
                  labels.severity = "warning";
                  annotations.summary = "fixture always-firing watchdog";
                }
              ];
            }
          ];
        };

        telemetry = {
          # Explicit admission: this fixture host is the local-plus-network
          # gateway, so it accepts all three signals on its OTLP input and binds
          # an additional ingress alongside the loopback producer listener.
          otlp = {
            signals = [
              "traces"
              "metrics"
              "logs"
            ];
            ingress = {
              host = "100.64.0.9";
            };
          };
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
              metricsPath = "/metrics/extra";
              interval = "15s";
            };
            # The collector's own delivery-health endpoint, registered through
            # the ordinary producer interface: the mechanism exposes loopback
            # metrics, the consumer decides whether to scrape them.
            otel-collector-health = {
              target = "127.0.0.1";
              port = 9464;
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
            # The two metrics stores the scrape realization forwards to.
            victoria = {
              protocol = "prometheus-remote-write";
              endpoint = "http://metrics.invalid/api/v1/write";
              signals = [ "metrics" ];
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
          # Scraped metrics leave vmagent over Prometheus remote write only, so
          # the metrics fanout is selected explicitly: both remote-write stores,
          # and not the OTLP gateway that also accepts metrics. Selecting the
          # fanout is the consumer's call; nothing is dropped silently.
          pipelines.metrics = [
            "victoria"
            "archive"
          ];
          pipelines.logs = [ "plain" ];
          secretFiles.token = fixtureSecretFile;
          secretKeys.token = "otel/token";
          secretFiles.metricsToken = fixtureSecretFile;
          secretKeys.metricsToken = "metrics/token";
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
      # failure severity defaulted (warning), success pruned (a stop of a
      # oneshot job is not news).
      services.notify.events.fixture-monitored = {
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

  # The guard is the only thing between a secret's contents and vmagent's
  # positional argument parsing, and it is a shell script rather than a Nix
  # value, so its refusal is proven by running it — with the values it must
  # refuse and the ones it must not.
  perSystem =
    { system, ... }:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system};

      # The contract leaves: one independent check per throwaway contract
      # evaluation, so the fixture host above never forces the nested
      # evaluations its assertions used to carry.
      contract = contractLeaves system;

      # A leaf passes as a trivial derivation — the name still exists as a
      # check — and fails as the named error at evaluation, so a contract break
      # is never mistakable for an incidental evaluation error.
      contractLeaf =
        name:
        { message, ok }:
        if ok then pkgs.runCommand "check-${name}" { } "touch $out" else throw message;

      contractChecks = lib.mapAttrs contractLeaf contract;
    in
    {
      # One check per contract leaf. A leaf is an ordinary check name, so a new
      # contract keeps being an ordinary `checks.<name>` build in CI.
      checks = contractChecks // {
        # Read the generated JSON at build time. Evaluation stays portable across
        # architectures, while real output files retain the routing/default checks.
        notify-rendered-policy =
          let
            fixtureHost = "fixture-${builtins.replaceStrings [ "_" ] [ "-" ] system}";
            etc = config.flake.nixosConfigurations.${fixtureHost}.config.environment.etc;
          in
          pkgs.runCommand "notify-rendered-policy-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
            python3 - '${etc."notify/events.json".source}' '${etc."notify/config.json".source}' <<'PY'
            import json
            import sys

            with open(sys.argv[1]) as source:
                events = json.load(source)
            with open(sys.argv[2]) as source:
                config = json.load(source)
            assert events["fixture-monitored"]["failure"]["severity"] == "warning"
            for name in ("ntfy", "telegram"):
                transport = config[name]
                assert transport["topics"]
                assert transport["default_topic"] in transport["topics"], name
            assert config["ntfy"]["topics"]["fleet"] == "fleet"
            assert config["telegram"]["default_topic"] == "fleet"
            print("rendered notification policy and transport routing passed")
            PY
            touch $out
          '';

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
              # element, so the next destination receives arguments meant for
              # this one. The rest are the parser's other structural characters,
              # and a newline can start a new header line.
              refuse 'PRIMARY,X-Probe: LEAKED' 'comma'
              refuse 'a,b' 'comma (short)'
              refuse 'a]b' 'closing bracket'
              refuse 'a{b' 'opening brace'
              refuse 'a(b' 'opening parenthesis'
              refuse "q'w" 'single quote'
              refuse 'p^^r' 'header separator'
              refuse 'c^d' 'caret'
              refuse $'e\nf' 'embedded newline'
              refuse $'g\n' 'trailing newline'
              refuse $'h\ri' 'carriage return'

              # Bearer/basic credentials and the shapes consumers actually bind
              # must keep working, including one that is only structurally safe.
              accept 'sk-abc123DEF' 'opaque token'
              accept 'AbC0._~-+/=' 'base64url and padding'
              accept 'user:pa55word' 'basic-auth style'
              accept 'project-1234' 'identifier'
              accept "" 'empty'

              touch $out
            '';
      };
    };
}
