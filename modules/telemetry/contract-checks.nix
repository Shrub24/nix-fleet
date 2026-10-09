# Validation cases the telemetry contract owns (`lib/telemetry-contract.nix`): a
# destination, fanout, route or credential mistake must fail closed by name, and
# a declaration must stay inert until a realization consumes it.
#
# Most cases evaluate the contract module alone through `evalModules` — no
# aspect, sops or systemd evaluation is paid for a claim the contract itself
# makes. A case whose subject is the composition (a realization-consuming
# declaration, the endpoint guard, route rendering) evaluates a throwaway host
# and says so.
{
  lib,
  config,
  inputs,
  ...
}:
let
  # Stand-in for a consumer's SOPS file: an existing YAML placeholder in the
  # flake source, so the contract's readership gate passes without committing
  # secret material.
  fixtureSecretFile = ../flake/fixture-secrets.yaml;

  # The contract module carries no package or architecture behaviour, so the
  # cases whose only input is the contract are registered once, on the
  # canonical system: a per-system copy would be a second identical
  # evaluation. A case whose subject is the composition stays in `perSystem`
  # below, where its result can differ per architecture.
  canonicalSystem = "x86_64-linux";

  # Only `leaf` is system-bound — it stamps a check derivation — so the
  # plumbing is imported with the system each leaf registers under, while the
  # helpers below are shared: `evalModules` over the contract reads no `pkgs`.
  plumbingFor =
    system:
    import ../../lib/contract-leaf.nix {
      inherit lib;
      pkgs = inputs.nixpkgs.legacyPackages.${system};
    };

  canonical = plumbingFor canonicalSystem;

  inherit (canonical)
    assertionFailures
    telemetryAccepts
    telemetryContract
    telemetryRefuses
    ;

  # The message the contract publishes for a refusal, so an
  # assertion-delivered case pins the branch rather than "something failed".
  refusesWith =
    message: values:
    builtins.any (lib.hasPrefix message) (assertionFailures (telemetryContract values));

  # A traces destination the OTLP and ingress probes compose with.
  tracesDestination = {
    protocol = "otlp-http";
    endpoint = "https://backend.invalid";
    signals = [ "traces" ];
  };
in
{
  # Contract-only policy: refusals the contract owns and inert declarations it
  # must accept, with no aspect, sops or systemd evaluation in the way.
  flake.checks.${canonicalSystem} = {
    # A destination, fanout or credential mistake must fail closed at the
    # contract level, whichever implementation is composed.
    telemetry-mutation-rejections = canonical.leaf "telemetry-mutation-rejections" [
      {
        message = "a destination header referencing an unknown secret is no longer refused by name";
        ok = refusesWith "telemetry: destination header(s) reference unknown secret(s) absent" {
          destinations.bad = {
            protocol = "otlp-http";
            endpoint = "https://invalid.example";
            signals = [ "traces" ];
            headers.Authorization.secret = "absent";
          };
        };
      }
      {
        message = "secretFiles and secretKeys no longer have to pair";
        ok = refusesWith "telemetry: secretFiles and secretKeys IDs must match" {
          secretFiles.token = fixtureSecretFile;
          secretKeys.other = "otel/token";
        };
      }
      {
        message = "an explicit fanout naming an unknown destination is no longer refused";
        ok = telemetryRefuses { pipelines.traces = [ "absent" ]; };
      }
      {
        message = "a destination signalling more than its protocol carries is no longer refused";
        ok = telemetryRefuses {
          destinations.metricsWire = {
            protocol = "prometheus-remote-write";
            endpoint = "http://metrics.invalid/api/v1/write";
            signals = [
              "metrics"
              "logs"
            ];
          };
        };
      }
      {
        message = "an explicit pipeline naming a destination for a signal it does not accept is no longer refused";
        ok = telemetryRefuses {
          destinations.tracesOnly = {
            protocol = "otlp-http";
            endpoint = "https://langfuse.invalid";
            signals = [ "traces" ];
          };
          pipelines.logs = [ "tracesOnly" ];
        };
      }
      {
        message = "an explicit empty fanout is no longer refused";
        ok = telemetryRefuses { pipelines.logs = [ ]; };
      }
    ];

    # The OTLP input's own admission rules, including the address validation
    # that keeps a DNS name beginning with 127. out of the loopback set.
    telemetry-otlp-rejections = canonical.leaf "telemetry-otlp-rejections" (
      let
        admitted = extra: { destinations.traces = tracesDestination; } // extra;
      in
      [
        {
          message = "an admitted signal named twice is no longer refused by name";
          ok =
            refusesWith "telemetry: services.telemetry.otlp.signals names traces more than once"
              (admitted {
                otlp.signals = [
                  "traces"
                  "traces"
                ];
              });
        }
        {
          message = "an admitted signal with no destination pipeline is no longer refused by name";
          ok = refusesWith "telemetry: OTLP admits logs with no destination pipeline" (admitted {
            otlp.signals = [
              "traces"
              "logs"
            ];
          });
        }
        {
          message = "a non-loopback producer host is no longer refused by name";
          ok =
            refusesWith
              "telemetry: services.telemetry.otlp.host is '0.0.0.0', but the producer listener is loopback-only"
              (admitted {
                otlp.signals = [ "traces" ];
                otlp.host = "0.0.0.0";
              });
        }
        {
          message = "a DNS name beginning with 127. is no longer distinguished from a loopback address";
          ok =
            refusesWith
              "telemetry: services.telemetry.otlp.host is '127.example.invalid', but the producer listener is loopback-only"
              (admitted {
                otlp.signals = [ "traces" ];
                otlp.host = "127.example.invalid";
              });
        }
        {
          message = "a malformed 127.0.0.0/8 address is no longer refused by name";
          ok =
            refusesWith
              "telemetry: services.telemetry.otlp.host is '127.999.0.1', but the producer listener is loopback-only"
              (admitted {
                otlp.signals = [ "traces" ];
                otlp.host = "127.999.0.1";
              });
        }
      ]
    );

    # The additional ingress binds its own listener, so it owns its own
    # transport and host rules.
    telemetry-ingress-rejections = canonical.leaf "telemetry-ingress-rejections" (
      let
        admitted =
          extra:
          {
            otlp.signals = [ "traces" ];
            destinations.traces = tracesDestination;
          }
          // extra;
      in
      [
        {
          message = "colliding local HTTP and gRPC ports are no longer refused by name";
          ok = refusesWith "telemetry: services.telemetry.otlp.httpPort and grpcPort must differ" (admitted {
            otlp.httpPort = 4317;
          });
        }
        {
          message = "colliding ingress HTTP and gRPC ports are no longer refused by name";
          ok =
            refusesWith "telemetry: services.telemetry.otlp.ingress.httpPort and grpcPort must differ"
              (admitted {
                otlp.ingress = {
                  host = "100.64.0.2";
                  httpPort = 4318;
                  grpcPort = 4318;
                };
              });
        }
        {
          message = "a wildcard ingress host is no longer refused by name";
          ok =
            refusesWith "telemetry: services.telemetry.otlp.ingress.host must be an explicit bind address"
              (admitted {
                otlp.ingress.host = "0.0.0.0";
              });
        }
        {
          message = "an empty ingress host is no longer refused by name";
          ok =
            refusesWith "telemetry: services.telemetry.otlp.ingress.host must be an explicit bind address"
              (admitted {
                otlp.ingress.host = "";
              });
        }
        {
          message = "an ingress with no transport is no longer refused by name";
          ok = refusesWith "telemetry: services.telemetry.otlp.ingress sets no HTTP or gRPC port" (admitted {
            otlp.ingress = {
              host = "100.64.0.2";
              httpPort = null;
              grpcPort = null;
            };
          });
        }
        {
          message = "an ingress with nothing admitted is no longer refused by name";
          ok =
            refusesWith
              "telemetry: services.telemetry.otlp.ingress is configured while services.telemetry.otlp.signals is empty"
              {
                otlp.ingress.host = "100.64.0.2";
              };
        }
      ]
    );

    # Local and network listeners must not collide: a bind string is a name,
    # so the spellings that can land on the same socket are the claim.
    telemetry-listener-collisions = canonical.leaf "telemetry-listener-collisions" (
      let
        admitted =
          extra:
          {
            otlp.signals = [ "traces" ];
            destinations.traces = tracesDestination;
          }
          // extra;
      in
      [
        {
          message = "an ingress on the producer listener's own address is no longer refused by name";
          ok =
            refusesWith "telemetry: services.telemetry.otlp.ingress binds 127.0.0.1:4318, the same address"
              (admitted {
                otlp.ingress.host = "127.0.0.1";
              });
        }
        {
          message = "an ingress spelled localhost is no longer treated as the producer listener's own socket";
          ok =
            refusesWith "telemetry: services.telemetry.otlp.ingress binds localhost:4318, the same address"
              (admitted {
                otlp.ingress.host = "localhost";
              });
        }
        {
          message = "a bracketed and an unbracketed IPv6 spelling of one socket no longer collide";
          ok =
            refusesWith "telemetry: services.telemetry.otlp.ingress binds ::1:4318, the same address"
              (admitted {
                otlp.host = "[::1]";
                otlp.ingress.host = "::1";
              });
        }
        {
          message = "a second, distinct loopback address is no longer admitted as its own socket";
          ok = telemetryAccepts (admitted {
            otlp.ingress.host = "127.0.0.2";
          });
        }
      ]
    );

    # Credential vocabulary is provider-independent, so it is enforced
    # without composing a realization.
    telemetry-credential-rejections = canonical.leaf "telemetry-credential-rejections" [
      {
        message = "a bound credential no destination header references is no longer refused by name";
        ok =
          refusesWith "telemetry: bound credentials have no declared destination header reference: unused"
            {
              secretFiles.unused = fixtureSecretFile;
              secretKeys.unused = "unused/key";
            };
      }
      {
        message = "a credential bound only to a dormant destination's header is no longer accepted";
        ok = telemetryAccepts {
          destinations.dormant = {
            protocol = "otlp-http";
            endpoint = "https://dormant.invalid";
            signals = [ "logs" ];
            headers.Authorization.secret = "unused";
          };
          secretFiles.unused = fixtureSecretFile;
          secretKeys.unused = "unused/key";
        };
      }
    ];
  };

  perSystem =
    { system, ... }:
    let
      inherit (plumbingFor system) leaf;

      aspects = config.flake.modules.nixos;

      # A throwaway host, for the cases whose subject is the composition itself:
      # the contract plus the caller's modules, never the fixture.
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
          ];
        }).config;

      # A consumer reading the local OTLP URL out of the contract.
      endpointReader =
        { config, ... }:
        {
          environment.variables.OTEL_EXPORTER_OTLP_ENDPOINT = config.services.telemetry.otlp.httpUrl;
        };
    in
    {
      checks = {

        # The local producer endpoint is readable only with a composed OTLP
        # capability, an admitted signal and a destination to carry it. The guard
        # is a read-time throw.
        telemetry-endpoint-guard = leaf "telemetry-endpoint-guard" [
          {
            message = "reading the local OTLP URL with a composed OTLP realization but no admitted signal is no longer refused";
            ok =
              !(builtins.tryEval
                (hostFor [ aspects.telemetry-otlp endpointReader ] {
                  destinations.local = {
                    protocol = "otlp-grpc";
                    endpoint = "http://gateway.invalid:4317";
                    signals = [ "traces" ];
                  };
                }).environment.variables.OTEL_EXPORTER_OTLP_ENDPOINT
              ).success;
          }
          {
            message = "reading the local OTLP URL with no OTLP push realization is no longer refused";
            ok = !(builtins.tryEval (telemetryContract { }).services.telemetry.otlp.httpUrl).success;
          }
          {
            message = "the local OTLP URL is no longer the loopback listener its realization binds";
            ok =
              (hostFor [ aspects.telemetry-otlp endpointReader ] {
                otlp.signals = [ "traces" ];
                destinations.local = {
                  protocol = "otlp-grpc";
                  endpoint = "http://gateway.invalid:4317";
                  signals = [ "traces" ];
                };
              }).environment.variables.OTEL_EXPORTER_OTLP_ENDPOINT == "http://127.0.0.1:4318";
          }
        ];

        # A named route is an input of its own: its own listener, its own
        # receiver and its own route-scoped exporter instances, never a filter
        # over the general route's destinations.
        telemetry-routes = leaf "telemetry-routes" (
          let
            generalDestination = {
              protocol = "otlp-http";
              endpoint = "https://victoria.invalid/v1/traces";
              signals = [ "traces" ];
            };
            langfuseDestination = {
              protocol = "otlp-http";
              endpoint = "https://langfuse.invalid/api/public/otel/v1/traces";
              signals = [ "traces" ];
            };
            routeValues = {
              otlp.signals = [ "traces" ];
              destinations.general = generalDestination;
              destinations.langfuse = langfuseDestination;
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
            settingsOf =
              values:
              (hostFor [ aspects.telemetry-otel-collector-otlp ] values)
              .services.opentelemetry-collector.settings;
            settings = settingsOf routeValues;
            dual = settingsOf (
              lib.recursiveUpdate routeValues {
                routes.ai.pipelines.traces = [
                  "langfuse"
                  "general"
                ];
              }
            );
          in
          [
            {
              message = "the general route no longer exports through its own destination alone";
              ok = settings.service.pipelines.traces.exporters == [ "otlphttp/general" ];
            }
            {
              message = "a route no longer consumes its own receiver or renders its own listener";
              ok =
                settings.service.pipelines."traces/route-ai".receivers == [ "otlp/route-ai" ]
                && settings.receivers."otlp/route-ai".protocols.http.endpoint == "127.0.0.2:14320";
            }
            {
              message = "a route pipeline no longer exports only through its route-scoped exporter";
              ok =
                settings.service.pipelines."traces/route-ai".exporters == [ "otlphttp/route-ai-langfuse" ]
                && settings.exporters."otlphttp/route-ai-langfuse".sending_queue.storage == "file_storage";
            }
            {
              message = "a route naming another destination no longer gets a separate route-scoped exporter";
              ok =
                builtins.sort builtins.lessThan dual.service.pipelines."traces/route-ai".exporters == [
                  "otlphttp/route-ai-general"
                  "otlphttp/route-ai-langfuse"
                ]
                && dual.service.pipelines.traces.exporters == [ "otlphttp/general" ];
            }
            {
              message = "a route pipeline naming an unknown destination is no longer refused";
              ok = telemetryRefuses (
                lib.recursiveUpdate routeValues {
                  routes.ai.pipelines.traces = [ "missing" ];
                }
              );
            }
            {
              message = "a route carrying no signal is no longer refused by name";
              ok = refusesWith "telemetry: route(s) empty declare no signals" {
                routes.empty = {
                  signals = [ ];
                  ingress = {
                    host = "127.0.0.2";
                    httpPort = 14321;
                  };
                };
              };
            }
            {
              message = "a wildcard route ingress is no longer refused by name";
              ok = refusesWith "telemetry: route(s) ai ingress.host must be an explicit bind address" (
                lib.recursiveUpdate routeValues {
                  routes.ai.ingress.host = "0.0.0.0";
                }
              );
            }
            {
              message = "two routes on one socket are no longer refused by name";
              ok = refusesWith "telemetry: route 'ai' binds 127.0.0.2:14320" (
                lib.recursiveUpdate routeValues {
                  routes.second = {
                    signals = [ "traces" ];
                    pipelines.traces = [ "langfuse" ];
                    ingress = {
                      host = "127.0.0.2";
                      httpPort = 14320;
                      grpcPort = null;
                    };
                  };
                }
              );
            }
          ]
        );
      };
    };
}
