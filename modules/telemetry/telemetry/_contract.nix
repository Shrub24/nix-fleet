# The host-local telemetry contract. One namespace, `services.telemetry`,
# implementation-agnostic: a service registers a Prometheus scrape source, reads
# the local OTLP endpoint, or binds a remote destination without knowing which
# collector serves it.
#
# Declared in a fragment so a service aspect can write a registration on any
# host. Unlike the notification fragment, this one is NOT declaration-only: a
# registration that no host aspects realize must fail closed by name, so the
# fragment carries the orphan guard, and the derived OTLP endpoint fails closed
# too (a push-only consumer registers nothing). Realization (and the OTel-specific
# tuning) lives in the provider modules under telemetry/_providers/, imported by
# flake.modules.nixos.telemetry.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  cfg = config.services.telemetry;

  # Wire protocols a remote destination can speak, and the signals each can
  # carry. Shared, implementation-agnostic vocabulary — the adapter maps these
  # onto its collector's exporter components.
  protocolSignals = {
    otlp-grpc = [
      "traces"
      "metrics"
      "logs"
    ];
    otlp-http = [
      "traces"
      "metrics"
      "logs"
    ];
    prometheus-remote-write = [ "metrics" ];
  };
  allSignals = [
    "traces"
    "metrics"
    "logs"
  ];
  destinationNames = builtins.attrNames cfg.destinations;
  acceptsSignal = signal: name: builtins.elem signal cfg.destinations.${name}.signals;

  # A destination's declared signals must be a subset of what its protocol can
  # carry. Checked for every destination, not only the ones a pipeline names, so
  # an impossible pair can never reach an implementation unnoticed. `deepSeq`
  # runs the checks (a list of checks is otherwise lazy) and yields the count the
  # pipelines force with `seq`.
  validateDestination =
    name:
    let
      destination = cfg.destinations.${name};
      unsupported = builtins.filter (
        signal: !(builtins.elem signal protocolSignals.${destination.protocol})
      ) destination.signals;
    in
    if unsupported == [ ] then
      null
    else
      throw "telemetry: destination '${name}' accepts ${lib.concatStringsSep ", " unsupported}, which protocol ${destination.protocol} cannot carry";
  validatedDestinationCount = builtins.deepSeq (map validateDestination destinationNames) (
    builtins.length destinationNames
  );

  # Each signal's fanout: explicit selection wins (and is validated), otherwise
  # only the destinations that explicitly accept the signal. `signals` is
  # authoritative, never inferred from the protocol: an OTLP backend that carries
  # traces alone (an LLM-observability sink, say) must not silently receive
  # metrics and logs.
  resolvedPipeline =
    signal:
    builtins.seq validatedDestinationCount (
      let
        selected = cfg.pipelines.${signal};
        names =
          if selected == null then builtins.filter (acceptsSignal signal) destinationNames else selected;
      in
      if selected != null && names == [ ] then
        throw "telemetry: ${signal} pipeline explicitly resolves empty"
      else
        map (
          name:
          if !(builtins.hasAttr name cfg.destinations) then
            throw "telemetry: ${signal} pipeline references unknown destination '${name}'"
          else if !(acceptsSignal signal name) then
            throw "telemetry: destination '${name}' does not accept ${signal} (accepts ${
              lib.concatStringsSep ", " cfg.destinations.${name}.signals
            })"
          else
            name
        ) names
    );

  # The local endpoint is a promise that an implementation binds it. A push-only
  # consumer that imports this fragment, reads the URL, and registers nothing has
  # no orphan for the guard below to catch — and no collector would ever run — so
  # the derived value itself fails closed by name instead of advertising a dead
  # address.
  derivedUrl =
    option: port:
    if cfg.realized then
      "http://${cfg.otlp.host}:${toString port}"
    else
      throw "telemetry: ${option} was read on a host that did not select flake.modules.nixos.telemetry; no implementation binds the local OTLP endpoint. Select the host aspect or drop the read.";

  orphanReport = lib.concatStringsSep ", " (
    lib.optional (
      cfg.scrape != { }
    ) "scrape source(s) ${lib.concatStringsSep ", " (builtins.attrNames cfg.scrape)}"
    ++ lib.optional (
      cfg.destinations != { }
    ) "destination(s) ${lib.concatStringsSep ", " destinationNames}"
  );
in
{
  options.services.telemetry = {
    # Internal: set by flake.modules.nixos.telemetry. Distinguishes a host that
    # adopted the contract from a tree where a contributor merely declared a
    # registration (the orphan case the guard below rejects).
    realized = mkOption {
      type = types.bool;
      internal = true;
      default = false;
      description = "Whether flake.modules.nixos.telemetry is selected on this host. Set by that aspect; nothing else should define it.";
    };

    otlp = {
      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address the local OTLP receiver binds (loopback for an agent, a tailnet address for a gateway).";
      };
      grpcPort = mkOption {
        type = types.port;
        default = 4317;
        description = "OTLP gRPC receiver port.";
      };
      httpPort = mkOption {
        type = types.port;
        default = 4318;
        description = "OTLP HTTP receiver port.";
      };
      httpUrl = mkOption {
        type = types.str;
        readOnly = true;
        description = "OTLP/HTTP endpoint producers push to; derived from `host` and `httpPort`.";
      };
      grpcUrl = mkOption {
        type = types.str;
        readOnly = true;
        description = "OTLP/gRPC endpoint producers push to; derived from `host` and `grpcPort`.";
      };
    };

    providers = {
      otlpIngest = mkOption {
        type = types.enum [ "otel-collector" ];
        default = "otel-collector";
        description = "Implementation serving OTLP ingest on this host. The enum is the implemented set; an unimplemented value is a contract edit, not a host typo.";
      };
      prometheusScrape = mkOption {
        type = types.enum [ "otel-collector" ];
        default = "otel-collector";
        description = "Implementation serving Prometheus scrape sources on this host. Selection is per capability, so metrics and logs may split later without touching registrations.";
      };
    };

    scrape = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            target = mkOption {
              type = types.str;
              description = "Address the collector dials for this source. Host-local; fleet host IDs are not resolved here.";
            };
            port = mkOption {
              type = types.port;
              description = "Port the source exposes its metrics on.";
            };
            metricsPath = mkOption {
              type = types.str;
              default = "/metrics";
              description = "HTTP path of the metrics endpoint.";
            };
            scheme = mkOption {
              type = types.enum [
                "http"
                "https"
              ];
              default = "http";
              description = "Scrape scheme.";
            };
            interval = mkOption {
              type = types.str;
              default = "30s";
              description = "Prometheus scrape interval as a duration string.";
            };
            labels = mkOption {
              type = types.attrsOf types.str;
              default = { };
              description = "Static target labels attached to every sample from this source.";
            };
          };
        }
      );
      default = { };
      description = "Prometheus scrape sources this host's collector pulls. The attribute name is the scrape job name.";
    };

    destinations = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            protocol = mkOption {
              type = types.enum [
                "otlp-grpc"
                "otlp-http"
                "prometheus-remote-write"
              ];
              description = "Wire protocol of the remote destination.";
            };
            endpoint = mkOption {
              type = types.nonEmptyStr;
              description = "Destination URL. Repointing a backend is an edit here alone; registrations and the implementation name never move.";
            };
            signals = mkOption {
              type = types.nonEmptyListOf (types.enum allSignals);
              description = "Signals this destination accepts. Required and authoritative: a null pipeline fans out only to destinations that name the signal, so an OTLP backend carrying traces alone never receives metrics or logs. Must be a subset of what `protocol` can carry.";
            };
            headers = mkOption {
              type = types.attrsOf (
                types.submodule {
                  options = {
                    secret = mkOption {
                      type = types.str;
                      description = "ID in secretFiles and secretKeys.";
                    };
                    prefix = mkOption {
                      type = types.str;
                      default = "";
                      description = "Value prefix, such as `Bearer ` followed by a space.";
                    };
                  };
                }
              );
              default = { };
              description = "Secret-backed request headers for this destination.";
            };
          };
        }
      );
      default = { };
      description = "Named remote destinations the implementation exports to.";
    };

    pipelines = lib.genAttrs allSignals (
      signal:
      mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Destination names carrying ${signal}; null derives every destination whose `signals` lists ${signal}.";
      }
    );

    secretFiles = mkOption {
      type = types.attrsOf (types.nullOr types.path);
      default = { };
      description = "SOPS files by secret ID; null means unbound (two-step bootstrap).";
    };
    secretKeys = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "SOPS key paths by secret ID, paired with secretFiles.";
    };

    resolvedPipelines = mkOption {
      type = types.attrsOf (types.listOf types.str);
      readOnly = true;
      internal = true;
      description = "Destination names per signal after derivation and validation; consumed by the implementation.";
    };
  };

  config = {
    services.telemetry.otlp = {
      httpUrl = derivedUrl "services.telemetry.otlp.httpUrl" cfg.otlp.httpPort;
      grpcUrl = derivedUrl "services.telemetry.otlp.grpcUrl" cfg.otlp.grpcPort;
    };
    services.telemetry.resolvedPipelines = lib.genAttrs allSignals resolvedPipeline;

    assertions = [
      {
        assertion = cfg.realized || (cfg.scrape == { } && cfg.destinations == { });
        message = "telemetry: ${orphanReport} configured without the host selecting flake.modules.nixos.telemetry; select that aspect (it realizes the registration) or remove it. A registration is never silently dropped.";
      }
    ];
  };
}
