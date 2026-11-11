# The telemetry contract's own refusals and the composition claims that need a
# realization. A refusal case names the mistake; the branch firing is the
# contract, not the wording, so cases compare the refusal, and only the loopback
# address family (where unrelated errors are plausible) pins the message prefix.
{
  lib,
  config,
  inputs,
  ...
}:
let
  fixtureSecretFile = ../flake/fixture-secrets.yaml;

  # The contract reads no `pkgs`, so its cases are registered once, canonically.
  canonicalSystem = "x86_64-linux";
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

  # Refused however the contract says so: a throw, or a failed `telemetry:`
  # assertion. The branch firing is the contract; the sentence is not.
  refused =
    values:
    telemetryRefuses values
    || (
      let
        named = builtins.tryEval (
          builtins.any (lib.hasPrefix "telemetry: ") (assertionFailures (telemetryContract values))
        );
      in
      named.success && named.value
    );

  # `<case name> = <values>`: the name reports the mistake, the values must be
  # refused.
  refusals =
    cases:
    lib.mapAttrsToList (name: values: {
      message = name;
      ok = refused values;
    }) cases;

  tracesDestination = {
    protocol = "otlp-http";
    endpoint = "https://backend.invalid";
    signals = [ "traces" ];
  };
  admitted =
    extra:
    {
      otlp.signals = [ "traces" ];
      destinations.traces = tracesDestination;
    }
    // extra;
in
{
  flake.checks.${canonicalSystem} = {
    # A destination, fanout or credential mistake fails closed at the contract
    # level, whichever implementation is composed.
    telemetry-mutation-rejections = canonical.leaf "telemetry-mutation-rejections" (refusals {
      unknown-header-secret = {
        destinations.bad = {
          protocol = "otlp-http";
          endpoint = "https://invalid.example";
          signals = [ "traces" ];
          headers.Authorization.secret = "absent";
        };
      };
      secret-ids-must-pair = {
        secretFiles.token = fixtureSecretFile;
        secretKeys.other = "otel/token";
      };
      fanout-names-unknown-destination.pipelines.traces = [ "absent" ];
      signal-not-carried-by-protocol.destinations.metricsWire = {
        protocol = "prometheus-remote-write";
        endpoint = "http://metrics.invalid/api/v1/write";
        signals = [
          "metrics"
          "logs"
        ];
      };
      pipeline-names-destination-for-signal-it-rejects = {
        destinations.tracesOnly = {
          protocol = "otlp-http";
          endpoint = "https://langfuse.invalid";
          signals = [ "traces" ];
        };
        pipelines.logs = [ "tracesOnly" ];
      };
      explicit-empty-fanout.pipelines.logs = [ ];
    });

    telemetry-otlp-rejections = canonical.leaf "telemetry-otlp-rejections" (refusals {
      duplicate-signal = admitted {
        otlp.signals = [
          "traces"
          "traces"
        ];
      };
      admitted-signal-without-pipeline = admitted {
        otlp.signals = [
          "traces"
          "logs"
        ];
      };
      non-loopback-host = admitted {
        otlp.signals = [ "traces" ];
        otlp.host = "0.0.0.0";
      };
      dns-name-starting-with-127 = admitted {
        otlp.signals = [ "traces" ];
        otlp.host = "127.example.invalid";
      };
      malformed-loopback-address = admitted {
        otlp.signals = [ "traces" ];
        otlp.host = "127.999.0.1";
      };
    });

    telemetry-ingress-rejections = canonical.leaf "telemetry-ingress-rejections" (refusals {
      colliding-local-ports = admitted { otlp.httpPort = 4317; };
      colliding-ingress-ports = admitted {
        otlp.ingress = {
          host = "100.64.0.2";
          httpPort = 4318;
          grpcPort = 4318;
        };
      };
      wildcard-ingress-host = admitted { otlp.ingress.host = "0.0.0.0"; };
      empty-ingress-host = admitted { otlp.ingress.host = ""; };
      ingress-without-transport = admitted {
        otlp.ingress = {
          host = "100.64.0.2";
          httpPort = null;
          grpcPort = null;
        };
      };
      ingress-without-admitted-signal = {
        otlp.ingress.host = "100.64.0.2";
      };
    });

    # A bind string is a name: the spellings that land on one socket are the
    # claim, and the distinct loopback is the accept case that proves the
    # comparison is not "everything on 127.".
    telemetry-listener-collisions = canonical.leaf "telemetry-listener-collisions" (
      refusals {
        ingress-on-producer-address = admitted { otlp.ingress.host = "127.0.0.1"; };
        ingress-spelled-localhost = admitted { otlp.ingress.host = "localhost"; };
        bracketed-vs-unbracketed-ipv6 = admitted {
          otlp.host = "[::1]";
          otlp.ingress.host = "::1";
        };
      }
      ++ [
        {
          message = "a second, distinct loopback address is no longer admitted as its own socket";
          ok = telemetryAccepts (admitted {
            otlp.ingress.host = "127.0.0.2";
          });
        }
      ]
    );

    telemetry-credential-rejections = canonical.leaf "telemetry-credential-rejections" (
      refusals {
        unused-credential = {
          secretFiles.unused = fixtureSecretFile;
          secretKeys.unused = "unused/key";
        };
      }
      ++ [
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
      ]
    );
  };

  perSystem =
    { system, ... }:
    let
      inherit (plumbingFor system) leaf;
      aspects = config.flake.modules.nixos;

      # A throwaway host for the cases whose subject is the composition.
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
      producerHost = values: hostFor [ aspects.telemetry-otlp endpointReader ] values;
      localDestination = {
        protocol = "otlp-grpc";
        endpoint = "http://gateway.invalid:4317";
        signals = [ "traces" ];
      };
    in
    {
      checks = {
        # The local producer endpoint is readable only with a composed OTLP
        # capability, an admitted signal and a destination to carry it.
        telemetry-endpoint-guard = leaf "telemetry-endpoint-guard" [
          {
            message = "reading the local OTLP URL without an admitted signal is no longer refused";
            ok =
              !(builtins.tryEval
                (producerHost { destinations.local = localDestination; })
                .environment.variables.OTEL_EXPORTER_OTLP_ENDPOINT
              ).success;
          }
          {
            message = "reading the local OTLP URL with no OTLP push realization is no longer refused";
            ok = !(builtins.tryEval (telemetryContract { }).services.telemetry.otlp.httpUrl).success;
          }
          {
            message = "the local OTLP URL is no longer the loopback listener its realization binds";
            ok =
              (producerHost {
                otlp.signals = [ "traces" ];
                destinations.local = localDestination;
              }).environment.variables.OTEL_EXPORTER_OTLP_ENDPOINT == "http://127.0.0.1:4318";
          }
        ];

        # A named route is its own listener, receiver and route-scoped exporters,
        # never a filter over the general route's destinations.
        telemetry-routes = leaf "telemetry-routes" (
          let
            routeValues = {
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
              message = "a route naming two destinations no longer gets a separate route-scoped exporter each";
              ok =
                builtins.sort builtins.lessThan dual.service.pipelines."traces/route-ai".exporters == [
                  "otlphttp/route-ai-general"
                  "otlphttp/route-ai-langfuse"
                ]
                && dual.service.pipelines.traces.exporters == [ "otlphttp/general" ];
            }
          ]
          ++ refusals {
            route-names-unknown-destination = lib.recursiveUpdate routeValues {
              routes.ai.pipelines.traces = [ "missing" ];
            };
            route-without-signal = {
              routes.empty = {
                signals = [ ];
                ingress = {
                  host = "127.0.0.2";
                  httpPort = 14321;
                };
              };
            };
            wildcard-route-ingress = lib.recursiveUpdate routeValues {
              routes.ai.ingress.host = "0.0.0.0";
            };
            two-routes-on-one-socket = lib.recursiveUpdate routeValues {
              routes.second = {
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
        );
      };
    };
}
