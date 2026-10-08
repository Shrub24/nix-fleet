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
  resolvedDocsMcp = config.flake.lib.serviceEndpoints.resolveEndpoint config.fleet {
    service = "docs-mcp";
    endpoint = "mcp";
    via = "tailnet";
  };

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
      telemetryMutationChecks =
        # Contract mutations force resolved pipelines and contract assertions;
        # provider-specific failures use their explicitly composed realization.
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
        && telemetryRejects [ aspects.telemetry ] { services.telemetry.pipelines.logs = [ ]; }
        # a scrape source with no metrics destination to carry it
        && providerRejects [ aspects.telemetry-vmagent ] {
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
      # Every failure below is a named contract error read from the host's own
      # assertions, not an incidental evaluation error: the message is asserted, so
      # renaming or dropping the check fails this fixture.
      admissionFailuresOf =
        modules:
        let
          evaluated = admissionEval modules;
        in
        map (assertion: assertion.message) (
          builtins.filter (assertion: !assertion.assertion) evaluated.config.assertions
        );
      namedContractFailures =
        let
          rejects = message: modules: builtins.any (lib.hasPrefix message) (admissionFailuresOf modules);
          host = extra: [
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
        in
        # duplicate admission is not a set
        rejects "telemetry: services.telemetry.otlp.signals names traces more than once" (host {
          services.telemetry.otlp.signals = [
            "traces"
            "traces"
          ];
        })
        # an admitted signal with no destination to carry it
        && rejects "telemetry: OTLP admits logs with no destination pipeline" (host {
          services.telemetry.otlp.signals = [
            "traces"
            "logs"
          ];
        })
        # the producer listener is loopback-only: network ingress is a separate,
        # explicitly bound listener
        &&
          rejects
            "telemetry: services.telemetry.otlp.host is '0.0.0.0', but the producer listener is loopback-only"
            (host {
              services.telemetry.otlp.signals = [ "traces" ];
              services.telemetry.otlp.host = "0.0.0.0";
            })
        # A DNS name beginning with 127. is not a loopback address, and malformed
        # octets must fail at evaluation rather than at collector startup.
        &&
          builtins.all
            (
              badHost:
              rejects
                "telemetry: services.telemetry.otlp.host is '${badHost}', but the producer listener is loopback-only"
                (host {
                  services.telemetry.otlp.signals = [ "traces" ];
                  services.telemetry.otlp.host = badHost;
                })
            )
            [
              "127.example.invalid"
              "127.999.0.1"
            ]
        # HTTP and gRPC each own a TCP listener, even within one receiver.
        && rejects "telemetry: services.telemetry.otlp.httpPort and grpcPort must differ" (host {
          services.telemetry.otlp.signals = [ "traces" ];
          services.telemetry.otlp.httpPort = 4317;
        })
        && rejects "telemetry: services.telemetry.otlp.ingress.httpPort and grpcPort must differ" (host {
          services.telemetry.otlp.signals = [ "traces" ];
          services.telemetry.otlp.ingress = {
            host = "100.64.0.2";
            httpPort = 4318;
            grpcPort = 4318;
          };
        })
        # a wildcard ingress would expose the collector on every interface
        &&
          rejects "telemetry: services.telemetry.otlp.ingress.host must be an explicit bind address"
            (host {
              services.telemetry.otlp.signals = [ "traces" ];
              services.telemetry.otlp.ingress = {
                host = "0.0.0.0";
              };
            })
        &&
          rejects "telemetry: services.telemetry.otlp.ingress.host must be an explicit bind address"
            (host {
              services.telemetry.otlp.signals = [ "traces" ];
              services.telemetry.otlp.ingress = {
                host = "";
              };
            })
        # an ingress with no transport binds nothing
        && rejects "telemetry: services.telemetry.otlp.ingress sets no HTTP or gRPC port" (host {
          services.telemetry.otlp.signals = [ "traces" ];
          services.telemetry.otlp.ingress = {
            host = "100.64.0.2";
            httpPort = null;
          };
        })
        # an ingress with nothing admitted is a dead listener
        &&
          rejects
            "telemetry: services.telemetry.otlp.ingress is configured while services.telemetry.otlp.signals is empty"
            (host {
              services.telemetry.otlp.ingress = {
                host = "100.64.0.2";
              };
            })
        # local and network listeners must not collide
        &&
          rejects "telemetry: services.telemetry.otlp.ingress binds 127.0.0.1:4318, the same address"
            (host {
              services.telemetry.otlp.signals = [ "traces" ];
              services.telemetry.otlp.ingress = {
                host = "127.0.0.1";
              };
            })
        # the same socket spelled differently: `localhost` can resolve to the local
        # listener's own address (or its IPv6 twin), and a bracketed IPv6 literal is
        # the same bind address as the unbracketed form
        &&
          rejects "telemetry: services.telemetry.otlp.ingress binds localhost:4318, the same address"
            (host {
              services.telemetry.otlp.signals = [ "traces" ];
              services.telemetry.otlp.ingress = {
                host = "localhost";
              };
            })
        && rejects "telemetry: services.telemetry.otlp.ingress binds ::1:4318, the same address" (host {
          services.telemetry.otlp.host = "[::1]";
          services.telemetry.otlp.signals = [ "traces" ];
          services.telemetry.otlp.ingress = {
            host = "::1";
          };
        })
        # credential vocabulary is shared, so it is enforced without OTel: a
        # vmagent host must not silently accept a bad secret id or an unpaired file
        && rejects "telemetry: secretFiles and secretKeys IDs must match" [
          aspects.telemetry
          aspects.telemetry-vmagent
          {
            services.telemetry.scrape.app = {
              target = "127.0.0.1";
              port = 9100;
            };
            services.telemetry.destinations.victoria = {
              protocol = "prometheus-remote-write";
              endpoint = "https://metrics.invalid/api/v1/write";
              signals = [ "metrics" ];
              headers.Authorization.secret = "token";
            };
            services.telemetry.secretFiles.token = fixtureSecretFile;
            services.telemetry.secretKeys.other = "metrics/token";
          }
        ]
        && rejects "telemetry: destination header(s) reference unknown secret(s) absent" [
          aspects.telemetry
          {
            services.telemetry.destinations.bad = {
              protocol = "otlp-http";
              endpoint = "https://invalid.example";
              signals = [ "traces" ];
              headers.Authorization.secret = "absent";
            };
          }
        ]
        && rejects "telemetry: bound credentials have no declared destination header reference: unused" [
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
          withAspect,
          withSignals ? false,
          withDestination ? false,
        }:
        (fixtureNixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
          ]
          ++ lib.optionals withAspect [ aspects.telemetry-otlp ]
          ++ lib.optionals (!withAspect) [ ../../lib/telemetry-contract.nix ]
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
      telemetryAdmissionChecks =
        let
          traceOnlyEndpoint = builtins.tryEval (pushOnlyEndpoint {
            withAspect = true;
            withSignals = true;
            withDestination = true;
          });
          destinationOnlyEndpoint = builtins.tryEval (pushOnlyEndpoint {
            withAspect = true;
            withDestination = true;
          });
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
          pushOnlyWithoutAspect = builtins.tryEval (pushOnlyEndpoint {
            withAspect = false;
          });
          pushOnlyWithoutDestination = builtins.tryEval (pushOnlyEndpoint {
            withAspect = true;
            withSignals = true;
          });
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
          # socket addresses on both receivers, not merely pass admission.
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
                admissionAccepts modules
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
        # Contract and producer data are dormant without a realization.
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
        && admissionAccepts [ aspects.telemetry ]
        # The local endpoint is only readable when an OTLP capability accepts a
        # signal and a destination carries it. The guard is a read-time throw.
        && !pushOnlyWithoutAspect.success
        && !scrapeOnlyEndpoint.success
        && !pushOnlyWithoutDestination.success
        && !destinationOnlyEndpoint.success
        && traceOnlyEndpoint.success
        && traceOnlyEndpoint.value == "http://127.0.0.1:4318"
        # Selecting the logs lane runs Vector without an explicit enable flag;
        # a valid sink and non-empty allowlist are still required.
        && admissionAccepts [
          aspects.telemetry-logs
          {
            services.telemetry.journald = {
              includeUnits = [ "fixture-monitored" ];
              sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
            };
          }
        ]
        && vectorOnly.config.services.vector.enable
        && !vectorOnly.config.services.opentelemetry-collector.enable
        && !(vectorOnly.config.systemd.services ? opentelemetry-collector)
        # A composed metrics realization consumes the published health source; the
        # publishing registration does not compose another realization.
        && admissionAccepts deliveryHealthModules
        && deliveryHealthHost.config.services.vmagent.enable
        && !deliveryHealthHost.config.services.opentelemetry-collector.enable
        && !(deliveryHealthHost.config.systemd.services ? opentelemetry-collector)
        && !(deliveryHealthHost.config.services.notify.events ? opentelemetry-collector)
        # a second, distinct loopback address is a distinct socket, not a collision,
        # and adding the gateway ingress adds neither remote scraping nor journald
        # shipping to that host
        && admissionAccepts distinctLoopbackModules
        && !(distinctLoopbackHost.config.systemd.services ? vmagent)
        && !distinctLoopbackHost.config.services.vector.enable
        && !(distinctLoopbackHost.config.services.opentelemetry-collector.settings.receivers ? prometheus)
        && ipv6Bindings
        && namedContractFailures;

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
        # Contract-only journald values remain dormant without a logs realization.
        && admissionAccepts [
          aspects.telemetry
          {
            services.telemetry.journald = {
              sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
            };
          }
        ]
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
        # the deliberate opt-in exports the whole journal, and renders no
        # include_units filter at all: an empty list would mean "no unit", so
        # "everything" has to be its own decision and its own rendering
        && admissionAccepts [
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
            ])
        # the journal read scope is Vector-equivalent and stated, not inherited
        # from a provider default that could move: the current boot only, so a
        # reboot does not replay older boots' unread records
        && (vectorSettingsOf {
          journald = {
            enable = true;
            includeUnits = [ "fixture-monitored" ];
            sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline";
          };
        }).sources.journald.current_boot_only
        # A sink endpoint without the logs capability is inert contract data.
        && admissionAccepts [
          aspects.telemetry
          { services.telemetry.journald.sink.endpoint = "http://victorialogs.invalid:9428/insert/jsonline"; }
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
      # The scrape provider: the default vmagent translating every registered job,
      # and the two fanout mistakes failing closed by NAME (an unrelated evaluation
      # error would not count).
      vmagentHost = vmagentHostFor system;
      vmagentFanoutFailures =
        telemetryConfig:
        map (assertion: assertion.message) (
          builtins.filter (assertion: !assertion.assertion) (vmagentHost telemetryConfig).assertions
        );
      vmagentChecks =
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
          vectorHealthJob = {
            job_name = "vector-health";
            scrape_interval = "30s";
            metrics_path = "/metrics";
            scheme = "http";
            static_configs = [
              {
                targets = [ "127.0.0.1:9598" ];
                labels.instance = "nixos:vector";
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
          noScrape = vmagentHost { destinations.metrics = remoteWrite; };
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
          # A trace-only host: OTLP admission plus a traces destination, no scrape
          # work. Nothing else may start because a traces gateway exists.
          traceOnly = vmagentHost {
            otlp.signals = [ "traces" ];
            destinations.gateway = {
              protocol = "otlp-http";
              endpoint = "https://gateway.invalid";
              signals = [ "traces" ];
            };
          };
          noOtel = vmagentHost { };
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
        in
        # the default provider renders every scrape field into vmagent's own config
        duplicateScrapeRealizations
        && rendered.services.vmagent.enable
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
          ]
        # A host that binds a metrics destination but registers no scrape source
        # still starts the provider: its own loopback health scrape is a
        # registered job like any other, so the agent that would ship those
        # metrics exists exactly when the lane can carry them.
        && noScrape.services.vmagent.enable
        && noScrape.services.vmagent.prometheusConfig.scrape_configs == [ vmagentHealthJob ]
        && !(noScrape.systemd.services ? opentelemetry-collector)
        && !noScrape.services.opentelemetry-collector.enable
        # A traces destination is not a scrape source: a declared gateway starts
        # nothing beyond the composed scrape provider's own health job — no OTLP
        # listener, no log shipper, and no consumer scrape registration.
        && traceOnly.services.vmagent.enable
        && traceOnly.services.vmagent.prometheusConfig.scrape_configs == [ vmagentHealthJob ]
        && builtins.attrNames traceOnly.services.telemetry.scrape == [ "vmagent-health" ]
        && !traceOnly.services.opentelemetry-collector.enable
        && !(traceOnly.systemd.services ? opentelemetry-collector)
        && !traceOnly.services.vector.enable
        # The scrape realization owns vmagent and registers its own health job, so
        # a bare composition starts exactly that and nothing else.
        && noOtel.services.vmagent.enable
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
        # and when the same host also composes the scrape realization, the log
        # lane's delivery health and the agent's own management scrape are both
        # jobs the agent carries — the shipper's health arrives through the
        # ordinary contract rather than a second, log-carrying sink.
        && journaldWithMetrics.services.vector.settings.sources.internal_metrics.type == "internal_metrics"
        && journaldWithMetrics.services.vector.settings.sinks.vector-health.inputs == [ "internal_metrics" ]
        &&
          journaldWithMetrics.services.vmagent.prometheusConfig.scrape_configs == [
            vectorHealthJob
            vmagentHealthJob
          ]
        && !(journaldWithMetrics.services.telemetry.scrape ? app)
        # a selected metrics destination vmagent cannot write to fails by name,
        # the selected service remains present while named assertions reject bad fanout
        && builtins.any (lib.hasPrefix "telemetry: the metrics pipeline selects") (
          vmagentFanoutFailures unwritableFanout
        )
        && (vmagentHost unwritableFanout).services.vmagent.enable
        # so does a scrape source with no metrics destination to land in
        && builtins.any (lib.hasPrefix "telemetry: scrape sources are registered but the metrics pipeline") (
          vmagentFanoutFailures emptyFanout
        )
        && (vmagentHost emptyFanout).services.vmagent.enable
        # and so does a LITERAL value the remote-write argument parser would treat as
        # structure: a comma in an endpoint or header prefix would otherwise shift
        # arguments onto the next destination, so it fails while it is visible
        && builtins.any (lib.hasPrefix "telemetry: the metrics pipeline selects") (
          vmagentFanoutFailures hostileEndpoint
        )
        && (vmagentHost hostileEndpoint).services.vmagent.enable
        && builtins.any (lib.hasPrefix "telemetry: the metrics pipeline selects") (
          vmagentFanoutFailures hostileHeader
        )
        && (vmagentHost hostileHeader).services.vmagent.enable
        && builtins.any (lib.hasPrefix "telemetry: the metrics pipeline selects values vmagent's argument parser") (
          vmagentFanoutFailures hostileEndpoint
        )
        && builtins.any (lib.hasPrefix "telemetry: the metrics pipeline selects values vmagent's argument parser") (
          vmagentFanoutFailures hostileHeader
        )
        # contract-only destinations are valid data but create no runtime.
        && !(contractOnlyDestination.systemd.services ? vmagent)
        && !(producerOnly.systemd.services ? vmagent);

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
      # The node-exporter aspect owns both ends of its scrape and remains
      # independently composable without a consumer lane.
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
        && admissionAccepts [ aspects.node-exporter ];

      nixBaselineChecks =
        let
          evaluated =
            extra:
            (fixtureNixosSystem {
              inherit system;
              modules = [
                aspects.nix-baseline
                extra
              ];
            }).config;
          defaults = evaluated { };
          overridden = evaluated {
            nix.daemonCPUSchedPolicy = "idle";
            nix.daemonIOSchedClass = "idle";
            systemd.services.nix-daemon.serviceConfig.MemoryHigh = "8G";
          };
        in
        defaults.nix.package.version == inputs.nixpkgs.legacyPackages.${system}.nixVersions.latest.version
        && defaults.nix.daemonCPUSchedPolicy == "batch"
        && defaults.nix.daemonIOSchedClass == "best-effort"
        && defaults.nix.daemonIOSchedPriority == 7
        && defaults.systemd.services.nix-daemon.serviceConfig.CPUWeight == 50
        && defaults.systemd.services.nix-daemon.serviceConfig.IOWeight == 50
        && !(defaults.systemd.services.nix-daemon.serviceConfig ? MemoryHigh)
        && overridden.nix.daemonCPUSchedPolicy == "idle"
        && overridden.nix.daemonIOSchedClass == "idle"
        && overridden.systemd.services.nix-daemon.serviceConfig.MemoryHigh == "8G";

      buildAccountTrustChecks =
        let
          evaluated =
            modules:
            (fixtureNixosSystem {
              inherit system;
              inherit modules;
            }).config;
          defaults = evaluated [ aspects.build-account ];
          renamed = evaluated [
            aspects.build-account
            {
              services.build-account.name = "dispatcher";
              nix.settings.trusted-users = [ "existing-coordinator" ];
            }
          ];
          unselected = evaluated [ ];
        in
        lib.elem "nixbuild" defaults.nix.settings.trusted-users
        && lib.elem "dispatcher" renamed.nix.settings.trusted-users
        && lib.elem "existing-coordinator" renamed.nix.settings.trusted-users
        && lib.elem "root" renamed.nix.settings.trusted-users
        && !(lib.elem "nixbuild" renamed.nix.settings.trusted-users)
        && !(lib.elem "nixbuild" unselected.nix.settings.trusted-users);

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
          tuned = evaluated {
            services.fast-nix-gc.dates = "daily";
            services.fast-nix-optimise.enable = false;
          };
          # Every unit off at once: the update that removes the schedule. The
          # checks below read what the composition produced — rendered units and
          # the registration set — because an override that only sets option
          # values cannot show a registration that outlived its unit.
          disabled = evaluated {
            programs.nh.clean.enable = false;
            services.fast-nix-gc.enable = false;
            services.fast-nix-optimise.enable = false;
          };
        in
        # Collection is unconditional: with no free-space threshold every run
        # collects everything unreferenced rather than waiting for the store to
        # reach a watermark. A day of grace spares freshly built paths.
        defaults.services.fast-nix-gc.enable
        && defaults.services.fast-nix-gc.automatic
        && defaults.services.fast-nix-gc.dates == [ "hourly" ]
        && defaults.services.fast-nix-gc.ensureFree == null
        && defaults.services.fast-nix-gc.keepRecent == "1d"
        && defaults.services.fast-nix-gc.deleteOlderThan == null
        # Pruning never collects, and runs first when both timers fire.
        && defaults.programs.nh.clean.enable
        && lib.hasInfix "--no-gc" defaults.programs.nh.clean.extraArgs
        && lib.hasInfix "--keep-since 7d" defaults.programs.nh.clean.extraArgs
        && defaults.systemd.services.nh-clean.before == [ "fast-nix-gc.service" ]
        # Optimise stays a weekly safety net for pre-auto-optimise paths.
        && defaults.services.fast-nix-optimise.enable
        && defaults.services.fast-nix-optimise.dates == [ "weekly" ]
        # Every unit the aspect owns registers its own failure.
        && defaults.services.notify.events ? "nh-clean"
        && defaults.services.notify.events ? "fast-nix-gc"
        && defaults.services.notify.events ? "fast-nix-optimise"
        # The collector is installed as the manual tool for the same store.
        && lib.elem defaults.services.fast-nix-gc.package defaults.environment.systemPackages
        # The fleet's values are defaults on the upstream options, so a host
        # overrides them directly instead of through a fleet namespace.
        && tuned.services.fast-nix-gc.dates == [ "daily" ]
        && !tuned.services.fast-nix-optimise.enable
        # Turning a unit off is the override the contract invites, so it must
        # leave no trace. Two defects this catches: a registration left behind
        # with no unit to attach to, and the ordering drop-in on its own, which
        # renders a phantom `nh-clean` with no ExecStart (the same failure class
        # as the unconditional `tailscaled-autoconnect`).
        && !(disabled.systemd.units ? "nh-clean.service")
        && !(disabled.services.notify.events ? "nh-clean")
        && !(disabled.services.notify.events ? "fast-nix-gc")
        && !(disabled.services.notify.events ? "fast-nix-optimise")
        # The symptom in notify's own words, so this leaf fails the way a
        # consumer's build did.
        && !(lib.any (
          assertion:
          !assertion.assertion && lib.hasInfix "has no systemd service implementation" assertion.message
        ) disabled.assertions);

      nodeExporterIdentityChecks =
        let
          identity =
            extra:
            (fixtureNixosSystem {
              inherit system;
              modules = [
                aspects.node-exporter
                extra
              ];
            }).config.services.telemetry.scrape.node.labels.instance;
        in
        identity {
          networking.hostName = "node-probe";
          services.node-exporter.port = 9200;
        } == "node-probe:9200"
        &&
          identity {
            networking.hostName = "other-probe";
            services.telemetry.scrape.node.labels.instance = "consumer-owned";
          } == "consumer-owned";

      # The alerting aspects' own contract: selected but unbound leaves no unit and
      # no registration, an enabled vmalert instance without a datasource or a
      # notifier is refused by name (per instance), and a fully bound one is
      # accepted and registers its failure.
      alertingAdmissionChecks =
        let
          inert = admissionEval [
            aspects.vmalert
            aspects.alertmanager
          ];
          bound = {
            services.vmalert.instances.bound = {
              enable = true;
              settings = {
                "datasource.url" = "http://127.0.0.1:8428";
                "notifier.url" = [ "http://127.0.0.1:9093" ];
                "httpListenAddr" = "127.0.0.1:8880";
              };
            };
          };
        in
        !(inert.config.systemd.services ? "vmalert")
        && !(inert.config.systemd.services ? alertmanager)
        && inert.config.services.notify.events == { }
        && builtins.any (lib.hasPrefix "vmalert: instance(s) 'unbound-notifier'") (admissionFailures [
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
        ])
        && admissionAccepts [
          aspects.vmalert
          bound
        ]
        && (admissionEval [
          aspects.vmalert
          bound
        ]).config.services.notify.events
          ? "vmalert-bound";
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
        base.substituters == [
          # Appended to nixpkgs' own contribution, not restated by the aspect.
          "https://cache.nixos.org/"
          "https://nix-community.cachix.org"
          "https://cache.numtide.com"
          "https://cache.shrublab.xyz"
        ]
        && builtins.all (message: builtins.elem message base."trusted-substituters") [
          "https://cache.shrublab.xyz"
          "ssh-ng://eu.nixbuild.net"
        ]
        && builtins.any (lib.hasPrefix "cache.nixos.org-1:") base."trusted-public-keys"
        &&
          builtins.elem "nix-cache-1:FW0bJll9BP5ch0mHI+bXOImcD0RKLrH117WfQC+CU4A="
            base."trusted-public-keys"
        # Appending is a key of its own, so the baseline list must survive it.
        && appended.substituters == base.substituters
        && appended."extra-substituters" == [ "https://appended.invalid" ]
        && appended."extra-trusted-public-keys" == [ "appended.invalid-1:AAAA" ]
        # Replacing is explicit and drops the baseline entries rather than unioning.
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
      nix-baseline = {
        message = "nix-baseline: the daemon baseline or its consumer overrides regressed";
        ok = nixBaselineChecks;
      };
      nix-baseline-substitution = {
        message = "nix-baseline: the substitution catalog or its append/replace seams regressed";
        ok = nixBaselineSubstitutionSeams;
      };
      nix-gc-defaults = {
        message = "nix-gc: unconditional collection, root pruning, optimise or their overrides regressed";
        ok = nixGcChecks;
      };
      alerting-admission = {
        message = "alerting: vmalert or alertmanager instance admission regressed";
        ok = alertingAdmissionChecks;
      };
      telemetry-rejects = {
        message = "telemetry: a destination, fanout or secret mistake no longer fails closed";
        ok = telemetryMutationChecks;
      };
      telemetry-named-rejections = {
        message = "telemetry: a named admission rejection is missing, misnamed or no longer rejects";
        ok = namedContractFailures;
      };
      telemetry-admission = {
        message = "telemetry: dormant declarations or endpoint derivation regressed";
        ok = telemetryAdmissionChecks;
      };
      telemetry-capability-matrix = {
        message = "telemetry: explicit capability composition regressed";
        ok = telemetryCapabilityMatrixChecks;
      };
      telemetry-journald = {
        message = "telemetry: the journald shipping contract or its isolation from the collector regressed";
        ok = telemetryJournaldChecks;
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
      vmagent = {
        message = "vmagent: provider selection, rendered jobs, the bounded queue or credential binding regressed";
        ok = vmagentChecks;
      };
      node-exporter-identity = {
        message = "node-exporter: the scrape instance label no longer follows the exporter's own bind";
        ok = nodeExporterIdentityChecks;
      };
      node-exporter-admission = {
        message = "node-exporter: a scrape registration without the host aspect no longer fails by name";
        ok = nodeExporterAdmissionChecks;
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

      # Non-vacuity guard: every aspect must show its contribution.
      assertions = [
        {
          assertion =
            config.systemd.services.bifrost.serviceConfig.User == "bifrost"
            && config.services.bifrost.renderedConfig.config_store.enabled
            && config.services.bifrost.renderedConfig.source_of_truth == "config.json"
            && config.services.notify.events.bifrost.failure != null
            && config.systemd.services.bifrost.onFailure != [ ];
          message = "fixture: the Bifrost aspect lost its service, config authority or notify hook.";
        }
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
          assertion =
            cacheApiUrl == "http://oci-melb-1:5751" && cacheApiUrlMutated == "http://oci-melb-1:5752";
          message = "fixture: the CI cache URL is not derived from the niks3-write record.";
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
          # Severity vocabulary: three values, defaulted per event kind in the
          # rendered policy map (failure -> warning, success -> info), a
          # per-registration override winning, and routing declared by use
          # case. Check the generator's policy data without an evaluation-time
          # build; checks.notify-rendered-policy reads the actual JSON files.
          assertion =
            let
              events = config.environment.etc."notify/events.json".source.value;
            in
            events.fixture-monitored.failure.severity == "warning"
            && config.services.notify.events.fixture-monitored.failure.severity or null == null;
          message = "fixture: the notification aspect's severity defaults or rendered policy map regressed.";
        }
        {
          assertion =
            config.systemd.services.fixture-monitored.onFailure == [ "notify-event@fixture-monitored.service" ];
          message = "fixture: the notification aspect attached no native failure hook for a registered unit.";
        }
        {
          # Routing policy reaches the runtime intact: each enabled transport's
          # rendered config carries its use-case map and a default that names a
          # key of it, so a notification the deployment did not explicitly topic
          # is still routable rather than a dispatch error.
          assertion =
            let
              rendered = builtins.fromJSON config.environment.etc."notify/config.json".text;
              routable =
                transport:
                let
                  topics = transport.topics or { };
                  default = transport.default_topic or null;
                in
                topics != { } && default != null && topics ? ${default};
            in
            routable rendered.ntfy
            && routable rendered.telegram
            && rendered.ntfy.topics.fleet == "fleet"
            && rendered.telegram.default_topic == "fleet";
          message = "fixture: the notify aspect's rendered routing config lost a transport's use-case map or a default that names one of its keys.";
        }
        {
          assertion = config.services.niks3-auto-upload.enable && config.nix.settings.post-build-hook != "";
          message = "fixture: the niks3-publisher aspect did not wire the upload client.";
        }
        {
          assertion =
            (config.systemd.services."nh-clean".onFailure or [ ]) != [ ]
            && (config.systemd.services."fast-nix-gc".onFailure or [ ]) != [ ];
          message = "fixture: the nix-gc aspect lost a cleanup unit or its failure hook.";
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
          message = "fixture: the nix-baseline substitution catalog regressed.";
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
            &&
              otlp.signals == [
                "traces"
                "metrics"
                "logs"
              ]
            && otlp.ingress.host == "100.64.0.9"
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
            && config.services.telemetry.scrape.node.labels.instance == "${config.networking.hostName}:9100"
            && config.services.notify.events.prometheus-node-exporter.failure != null
            && unit.onFailure != [ ];
          message = "fixture: the node-exporter aspect's loopback bind, scrape registration or notify hook regressed.";
        }
        {
          # The journald logs lane: a Vector journald source writing JSON lines
          # to the consumer's endpoint over a bounded disk buffer, alongside
          # independent OTLP pipelines.
          assertion =
            let
              vector = config.services.vector;
              sink = vector.settings.sinks.logs;
              otel = config.services.opentelemetry-collector.settings;
            in
            vector.enable
            && vector.journaldAccess
            && vector.settings.data_dir == "/var/lib/vector"
            && vector.settings.sources.journald.type == "journald"
            && vector.settings.sources.journald.current_boot_only
            && vector.settings.sources.journald.include_units == [ "fixture-monitored" ]
            && !(vector.settings.sources.journald ? exclude_units)
            && vector.settings.sources.internal_metrics.type == "internal_metrics"
            && vector.settings.sinks.vector-health.type == "prometheus_exporter"
            # The health exporter carries only internal metrics — it must never
            # become a second path for journal records, and the log sink keeps
            # its journal-only inputs.
            && vector.settings.sinks.vector-health.inputs == [ "internal_metrics" ]
            && vector.settings.sinks.vector-health.address == "127.0.0.1:9598"
            && vector.settings.sinks.vector-health.default_namespace == "vector"
            && config.services.telemetry.scrape.vector-health.port == 9598
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
            && otel.service.pipelines.logs.exporters == [ "otlp/plain" ]
            && otel.service.pipelines.traces.receivers == [ "otlp" ];
          message = "fixture: the journald log path (Vector journald source, JSON-line sink, disk buffer, notify) regressed.";
        }
        {
          assertion =
            config.services.notify.events.opentelemetry-collector.failure != null
            && config.systemd.services.opentelemetry-collector.onFailure != [ ]
            && config.sops.secrets."otel-collector/token".sopsFile == fixtureSecretFile
            && config.sops.secrets."otel-collector/token".key == "otel/token"
            && config.sops.secrets."otel-collector/metricsToken".key == "metrics/token"
            &&
              builtins.elem "opentelemetry-collector.service"
                config.sops.templates."otel-collector.env".restartUnits
            &&
              builtins.elem "opentelemetry-collector.service"
                config.sops.secrets."otel-collector/token".restartUnits
            &&
              # The env file binds exactly the active credentials, each to its own
              # placeholder. Line order is not part of the contract, so compare
              # the lines as a set rather than pinning the provider's iteration
              # order.
              lib.sort (a: b: a < b) (
                lib.splitString "\n" (lib.removeSuffix "\n" config.sops.templates."otel-collector.env".content)
              ) == lib.sort (a: b: a < b) [
                "OTELCOL_token=${config.sops.placeholder."otel-collector/token"}"
                "OTELCOL_metricsToken=${config.sops.placeholder."otel-collector/metricsToken"}"
              ]
            &&
              config.systemd.services.opentelemetry-collector.serviceConfig.EnvironmentFile == [
                config.sops.templates."otel-collector.env".path
              ];
          message = "fixture: the otel-collector SOPS or notify contract regressed.";
        }
        {
          assertion = config.users.users ? "nixbuild" && config.users.users.nixbuild.isSystemUser;
          message = "fixture: the build-account aspect created no dispatch account.";
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
          # A trivial always-firing watchdog: this is the rule file
          # checks.vmalert-rules evaluates through the real vmalert, and the
          # one the fixture host's unit loads.
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

      # Runtime delivery checks run the real pinned collector binary against the
      # settings this adapter renders. Only test plumbing is changed: loopback
      # test ports, the JSON wire encoding the local mock receivers can read,
      # sub-second retry intervals (so a bounded check does not sleep through the
      # upstream backoff) and a delivery state path inside the build directory.
      harnessSettings =
        modules:
        (fixtureNixosSystem {
          inherit system;
          modules = [
            inputs.sops-nix.nixosModules.sops
            config.flake.modules.nixos.telemetry-otel-collector-otlp
            modules
          ];
        }).config.services.opentelemetry-collector.settings;
      # `statePath` keeps each harness phase on its own queue state, so phases
      # cannot inherit a backlog from one another. `batch` is only overridden by
      # the phase that has to distinguish persisted acceptance from a batch
      # timer; every other config renders the production default (`batch = { }`).
      testPlumbing =
        {
          queueSize,
          statePath,
          batch ? { },
        }:
        settings:
        settings
        // {
          extensions.file_storage = settings.extensions.file_storage // {
            directory = "@STATE@/${statePath}";
            compaction = settings.extensions.file_storage.compaction // {
              directory = "@STATE@/${statePath}/compaction";
            };
          };
          exporters = lib.mapAttrs (
            _: exporter:
            exporter
            // {
              encoding = "json";
              sending_queue = exporter.sending_queue // {
                queue_size = queueSize;
                inherit batch;
              };
              # `timeout` is not a valid `retry_on_failure` key in this pin
              # (only enabled/initial_interval/max_interval/max_elapsed_time are),
              # so the harness never injects one.
              retry_on_failure = exporter.retry_on_failure // {
                initial_interval = "100ms";
                max_interval = "200ms";
              };
            }
          ) settings.exporters;
        };
      tracesDestination = port: {
        protocol = "otlp-http";
        endpoint = "http://127.0.0.1:${toString port}";
        signals = [ "traces" ];
      };
      deliveryConfig = (pkgs.formats.yaml { }).generate "telemetry-delivery.yaml" (
        testPlumbing
          {
            queueSize = 268435456;
            statePath = "delivery";
          }
          (harnessSettings {
            services.telemetry.otlp.signals = [ "traces" ];
            services.telemetry.otlp.httpPort = 14318;
            services.telemetry.otlp.grpcPort = 14317;
            services.telemetry.destinations.backendA = tracesDestination 19001;
            services.telemetry.destinations.backendB = tracesDestination 19002;
            services.telemetry.destinations.backendC = tracesDestination 19003;
          })
      );
      # A deliberately small persistent queue: 1 MiB of serialized payload, the
      # smallest the pinned collector accepts (an implicit 1 MiB `min_size`
      # floor rejects anything smaller), which one test payload can exhaust.
      smallQueueConfig = (pkgs.formats.yaml { }).generate "telemetry-overflow.yaml" (
        testPlumbing
          {
            queueSize = 1048576;
            statePath = "overflow";
          }
          (harnessSettings {
            services.telemetry.otlp.signals = [ "traces" ];
            services.telemetry.otlp.httpPort = 14318;
            services.telemetry.otlp.grpcPort = 14317;
            services.telemetry.destinations.overflow = tracesDestination 19004;
          })
      );
      # Acknowledgement-before-batch evidence: the queue's batch timer is set
      # deliberately long (15s) and its byte threshold far above one request, so
      # a trace acknowledged milliseconds before an abrupt kill can only be
      # delivered after a restart if acceptance already reached persistent
      # storage — a timer-driven flush could not have run.
      lateFlushSeconds = 15;
      lateFlushConfig = (pkgs.formats.yaml { }).generate "telemetry-late-flush.yaml" (
        testPlumbing
          {
            queueSize = 268435456;
            statePath = "late-flush";
            batch = {
              flush_timeout = "${toString lateFlushSeconds}s";
              sizer = "bytes";
              min_size = 1048576;
              max_size = 4194304;
            };
          }
          (harnessSettings {
            services.telemetry.otlp.signals = [ "traces" ];
            services.telemetry.otlp.httpPort = 14318;
            services.telemetry.otlp.grpcPort = 14317;
            services.telemetry.destinations.late = tracesDestination 19005;
          })
      );
      ingressConfig = (pkgs.formats.yaml { }).generate "telemetry-ingress.yaml" (
        testPlumbing
          {
            queueSize = 268435456;
            statePath = "ingress";
          }
          (harnessSettings {
            services.telemetry.otlp.signals = [ "traces" ];
            services.telemetry.otlp.httpPort = 14318;
            services.telemetry.otlp.grpcPort = 14317;
            services.telemetry.otlp.ingress = {
              host = "127.0.0.2";
              httpPort = 14319;
              grpcPort = null;
            };
            services.telemetry.destinations.backend = tracesDestination 19011;
            services.otel-collector.resourceAttributes."host.name" = "gateway";
          })
      );
      # Delivery storage that cannot be created: the harness makes the parent
      # path a regular file, so the extension cannot make its directory.
      blockedStorageConfig = (pkgs.formats.yaml { }).generate "telemetry-storage-failure.yaml" (
        testPlumbing
          {
            queueSize = 268435456;
            statePath = "blocker/queue";
          }
          (harnessSettings {
            services.telemetry.otlp.signals = [ "traces" ];
            services.telemetry.otlp.httpPort = 14318;
            services.telemetry.otlp.grpcPort = 14317;
            services.telemetry.destinations.overflow = tracesDestination 19004;
          })
      );
      # Start with usable storage, then bound file growth in the child process:
      # the runtime check reaches an I/O failure without filling a builder disk.
      exhaustedStorageConfig = (pkgs.formats.yaml { }).generate "telemetry-exhausted-storage.yaml" (
        testPlumbing
          {
            queueSize = 268435456;
            statePath = "exhausted";
          }
          (harnessSettings {
            services.telemetry.otlp.signals = [ "traces" ];
            services.telemetry.otlp.httpPort = 14318;
            services.telemetry.otlp.grpcPort = 14317;
            services.telemetry.destinations.exhausted = tracesDestination 19004;
          })
      );
      collector = pkgs.opentelemetry-collector-contrib;
      telemetryTestInputs = [
        pkgs.python3
        pkgs.coreutils
        pkgs.gnugrep
      ];

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

      # The registry is the literal this split commits to: a leaf dropped,
      # renamed, or defined without reaching the check set fails closed here
      # rather than silently shrinking the checked surface.
      expectedContractLeaves = [
        "alerting-admission"
        "build-account-trust"
        "nix-baseline"
        "nix-baseline-substitution"
        "nix-gc-defaults"
        "node-exporter-admission"
        "node-exporter-identity"
        "otel-collector-inactive-credentials"
        "otel-collector-resource-order"
        "otel-collector-unbound-secrets"
        "tailscale-autoconnect"
        "telemetry-admission"
        "telemetry-capability-matrix"
        "telemetry-journald"
        "telemetry-named-rejections"
        "telemetry-rejects"
        "vmagent"
      ];
      contractChecks = lib.mapAttrs contractLeaf contract;
      contractLeafRegistry =
        lib.sort (a: b: a < b) (builtins.attrNames contract)
        == lib.sort (a: b: a < b) expectedContractLeaves
        &&
          builtins.length (builtins.filter (name: contractChecks ? ${name}) expectedContractLeaves)
          == builtins.length expectedContractLeaves;
    in
    {
      # One check per contract leaf, plus the registry that keeps the list
      # honest. A leaf is an ordinary check name, so a new contract keeps being
      # an ordinary `checks.<name>` build in CI.
      checks = contractChecks // {
        contract-leaf-registry = contractLeaf "contract-leaf-registry" {
          message = "fixture: the contract-leaf registry no longer matches the leaves this file defines";
          ok = contractLeafRegistry;
        };
        # The rendered rule file is a vmalert input, not a Nix value: this check
        # feeds the fixture host's own rules.yml to the real evaluator, offline —
        # a rule that does not parse or does not fire is caught here rather than
        # on the host it was meant to alert from.
        vmalert-rules =
          let
            fixtureHost = "fixture-${builtins.replaceStrings [ "_" ] [ "-" ] system}";
            rulesFile =
              config.flake.nixosConfigurations.${fixtureHost}.config.environment.etc."vmalert-fixture/rules.yml".source;
            unitTest = pkgs.writeText "vmalert-unittest.yaml" ''
              rule_files:
                - ${rulesFile}
              evaluation_interval: 1m
              tests:
                - interval: 1m
                  alert_rule_test:
                    - eval_time: 1m
                      groupname: fixture
                      alertname: FixtureWatchdog
                      exp_alerts:
                        - exp_labels:
                            severity: warning
                          exp_annotations:
                            summary: fixture always-firing watchdog
            '';
          in
          pkgs.runCommand "vmalert-rules-check"
            {
              nativeBuildInputs = [ pkgs.victoriametrics ];
            }
            ''
              vmalert-tool unittest -files=${unitTest} > $TMPDIR/unittest.log 2>&1 || {
                cat $TMPDIR/unittest.log
                exit 1
              }
              grep -q SUCCESS $TMPDIR/unittest.log || {
                cat $TMPDIR/unittest.log
                exit 1
              }
              touch $out
            '';

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

        # Offline runtime delivery check: the pinned collector binary, a
        # build-directory state path and local mock receivers. Nothing here
        # reaches a live endpoint or needs a credential.
        telemetry-delivery =
          pkgs.runCommand "telemetry-delivery-check"
            {
              nativeBuildInputs = telemetryTestInputs;
            }
            ''
              export OTELCOL=${collector}/bin/otelcol-contrib
              export CONFIG=$PWD/delivery.yaml
              export SMALL_CONFIG=$PWD/overflow.yaml
              export BLOCKED_CONFIG=$PWD/blocked.yaml
              export LATE_CONFIG=$PWD/late-flush.yaml
              export EXHAUSTED_CONFIG=$PWD/exhausted.yaml
              export EXHAUSTED_STATE=$PWD/exhausted
              export RECEIVE_PORT=14318
              export BACKEND_PORTS=19001,19002,19003
              export SMALL_BACKEND=19004
              export LATE_BACKEND=19005
              export LATE_FLUSH_SECONDS=${toString lateFlushSeconds}
              sed "s|@STATE@|$PWD|g" ${deliveryConfig} > "$CONFIG"
              sed "s|@STATE@|$PWD|g" ${smallQueueConfig} > "$SMALL_CONFIG"
              sed "s|@STATE@|$PWD|g" ${blockedStorageConfig} > "$BLOCKED_CONFIG"
              sed "s|@STATE@|$PWD|g" ${lateFlushConfig} > "$LATE_CONFIG"
              sed "s|@STATE@|$PWD|g" ${exhaustedStorageConfig} > "$EXHAUSTED_CONFIG"
              # Config validity against the pinned binary, before anything runs: the
              # harness only proves semantics if the config it starts is one the
              # collector accepts. (The blocked-storage config is validated by
              # phase 4, which requires it to be rejected at start-up.)
              ${collector}/bin/otelcol-contrib validate --config=file:"$CONFIG"
              ${collector}/bin/otelcol-contrib validate --config=file:"$SMALL_CONFIG"
              ${collector}/bin/otelcol-contrib validate --config=file:"$LATE_CONFIG"
              ${collector}/bin/otelcol-contrib validate --config=file:"$EXHAUSTED_CONFIG"
              python3 ${../../tests/telemetry/delivery_check.py}
              touch $out
            '';

        # Offline gateway check: producer and ingress listeners, admitted-signal
        # enforcement and origin identity across the relay, against the same
        # rendered settings and local mock receivers.
        telemetry-ingress =
          pkgs.runCommand "telemetry-ingress-check"
            {
              nativeBuildInputs = telemetryTestInputs;
            }
            ''
              export OTELCOL=${collector}/bin/otelcol-contrib
              export CONFIG=$PWD/ingress.yaml
              export LOCAL_PORT=14318
              export INGRESS_ADDR=127.0.0.2
              export INGRESS_PORT=14319
              export BACKEND_PORT=19011
              sed "s|@STATE@|$PWD|g" ${ingressConfig} > "$CONFIG"
              ${collector}/bin/otelcol-contrib validate --config=file:"$CONFIG"
              python3 ${../../tests/telemetry/ingress_check.py}
              touch $out
            '';
      };
    };
}
