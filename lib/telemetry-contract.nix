# The host-local telemetry contract. One namespace, `services.telemetry`,
# implementation-agnostic: a service registers a Prometheus scrape source, reads
# the local OTLP endpoint, opts into journald shipping, or binds a remote
# destination without knowing which implementation serves it.
#
# Declared in a fragment so a service aspect can write a registration on any
# host. Unlike the notification fragment, this one is NOT declaration-only: a
# registration that no host aspect realizes must fail closed by name, so the
# fragment carries the orphan guard, and the derived OTLP endpoint fails closed
# too (a push-only consumer registers nothing, and a destination alone does not
# admit a signal). Everything that is implementation-independent lives here —
# including the secret-ID vocabulary — so validating the contract never depends
# on which implementation happens to be selected.
#
# Realization (`services.telemetry.realized`) is set by flake.modules.nixos.telemetry,
# whose contributors are the sibling flake-parts files under modules/telemetry/.
# OTel-specific tuning lives under `services.otel-collector`.
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

  # OTLP admission: the signals this host's OTLP input accepts. Empty by
  # default — a destination declares where data goes, never that an input
  # exists — and every admitted signal must have somewhere to go, or the
  # receiver would acknowledge what it silently drops.
  admittedSignals = cfg.otlp.signals;
  duplicateSignals = builtins.filter (
    signal: builtins.length (builtins.filter (other: other == signal) admittedSignals) > 1
  ) admittedSignals;
  unservedSignals = builtins.filter (signal: resolvedPipeline signal == [ ]) admittedSignals;

  # The producer listener is loopback-only: the network-facing listener is the
  # explicit, separately bound additional ingress below. A host id or tailnet
  # address here would silently move the producer interface onto the network.
  loopbackHosts = [
    "127.0.0.1"
    "::1"
    "[::1]"
    "localhost"
  ];
  ipv4Octet = "([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])";
  isLoopbackHost =
    host:
    builtins.elem host loopbackHosts
    || builtins.match "127\\.${ipv4Octet}\\.${ipv4Octet}\\.${ipv4Octet}" host != null;

  ingress = cfg.otlp.ingress;
  ingressHosts = lib.optional (ingress != null) ingress;
  wildcardHosts = [
    "0.0.0.0"
    "::"
    "[::]"
    "*"
  ];
  # A bind string is a name, not a socket. `localhost` may land on either
  # loopback address, an IPv6 literal is bracketed in a bind string but not in
  # the address, and 127.0.0.2 is a different socket from 127.0.0.1. Comparing
  # the addresses a host can occupy is what turns "the collector failed to
  # bind" into the named conflict the contract promises; treating every distinct
  # spelling as a distinct socket would miss the alias case and treating every
  # loopback address as one socket would reject a legitimate second listener.
  bindAddresses =
    host:
    let
      unbracketed = lib.removePrefix "[" (lib.removeSuffix "]" host);
    in
    if unbracketed == "localhost" then
      [
        "127.0.0.1"
        "::1"
      ]
    else
      [ unbracketed ];
  bindsSameSocket =
    left: right:
    left.port == right.port
    && builtins.any (address: builtins.elem address (bindAddresses right.host)) (
      bindAddresses left.host
    );
  localBinds = [
    {
      host = cfg.otlp.host;
      port = cfg.otlp.httpPort;
    }
    {
      host = cfg.otlp.host;
      port = cfg.otlp.grpcPort;
    }
  ];
  ingressBinds = lib.concatMap (
    listener:
    lib.optional (listener.httpPort != null) {
      inherit (listener) host;
      port = listener.httpPort;
    }
    ++ lib.optional (listener.grpcPort != null) {
      inherit (listener) host;
      port = listener.grpcPort;
    }
  ) ingressHosts;
  # Reported as the consumer spelled it, so the named error points at the value
  # that has to change.
  listenerCollisions = map (bind: "${bind.host}:${toString bind.port}") (
    builtins.filter (
      ingressBind: builtins.any (localBind: bindsSameSocket localBind ingressBind) localBinds
    ) ingressBinds
  );
  ingressTransports = lib.concatMap (
    listener:
    lib.optional (listener.httpPort != null) "http" ++ lib.optional (listener.grpcPort != null) "grpc"
  ) ingressHosts;

  # Credential vocabulary. Provider-independent: validating secret wiring must
  # not depend on whether an OTel instance happens to run, because the scrape
  # provider binds credentials too.
  secretIds = builtins.attrNames cfg.secretFiles;
  secretNamesMatch = secretIds == builtins.attrNames cfg.secretKeys;
  validSecretIds = builtins.all (id: builtins.match "[A-Za-z0-9_]+" id != null) secretIds;
  headerSecretIds = lib.unique (
    lib.concatMap (
      name: map (header: header.secret) (lib.attrValues cfg.destinations.${name}.headers)
    ) destinationNames
  );
  unknownHeaderSecrets = builtins.filter (id: !(builtins.hasAttr id cfg.secretFiles)) headerSecretIds;

  # The local endpoint is a promise that an implementation binds it AND accepts
  # what is pushed there. A push-only consumer that imports this fragment, reads
  # the URL, and registers nothing has no orphan for the guard below to catch,
  # and a destination alone never admits a signal — so the derived value itself
  # fails closed by name instead of advertising a dead or deaf address. An
  # admitted signal with no pipeline to carry it is the same broken promise from
  # the other side: the listener would acknowledge what it silently drops.
  derivedUrl =
    option: port:
    if !cfg.realized then
      throw "telemetry: ${option} was read on a host that did not select flake.modules.nixos.telemetry; no implementation binds the local OTLP endpoint. Select the host aspect or drop the read."
    else if admittedSignals == [ ] then
      throw "telemetry: ${option} was read without admitting any OTLP signal; the local endpoint promises an input this host accepts, so declare services.telemetry.otlp.signals (for example [ \"traces\" ]) before reading it. Binding a destination alone admits nothing."
    else if unservedSignals != [ ] then
      throw "telemetry: ${option} was read while OTLP admits ${lib.concatStringsSep ", " unservedSignals} with no destination pipeline to carry them; an admitted input is only a realized input once a destination accepts it. Bind a destination accepting the signal or remove it from services.telemetry.otlp.signals."
    else
      let
        host =
          if lib.hasInfix ":" cfg.otlp.host && !lib.hasPrefix "[" cfg.otlp.host then
            "[${cfg.otlp.host}]"
          else
            cfg.otlp.host;
      in
      "http://${host}:${toString port}";

  orphanReport = lib.concatStringsSep ", " (
    lib.optional (
      cfg.scrape != { }
    ) "scrape source(s) ${lib.concatStringsSep ", " (builtins.attrNames cfg.scrape)}"
    ++ lib.optional (
      cfg.destinations != { }
    ) "destination(s) ${lib.concatStringsSep ", " destinationNames}"
    ++ lib.optional (cfg.journald.sink.endpoint != null) "journald sink"
  );

  # A sink endpoint is a URL the provider dials; a bare `host:port` is the
  # mistake this catches, not a stylistic preference.
  validSinkUrl = url: lib.hasPrefix "http://" url || lib.hasPrefix "https://" url;

  nothingRegistered =
    cfg.scrape == { } && cfg.destinations == { } && cfg.journald.sink.endpoint == null;
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
        description = ''
          Address the local OTLP producer listener binds. Loopback-only: the
          producer interface is host-local by construction, and a host that must
          receive telemetry from other machines binds the explicit additional
          ingress (`otlp.ingress`) instead. A non-loopback value fails closed by
          name.
        '';
      };
      signals = mkOption {
        type = types.listOf (types.enum allSignals);
        default = [ ];
        description = ''
          Signals this host's OTLP input accepts, as a unique set. Empty by
          default: a destination or a provider selection declares where data
          goes, never that an input exists, so a host must admit its signals
          explicitly. Every admitted signal needs a nonempty destination
          pipeline (otherwise the receiver would acknowledge what it drops), and
          the local OTLP URLs are only readable once an admitted signal has a destination to carry it.
        '';
      };
      httpPort = mkOption {
        type = types.port;
        default = 4318;
        description = "OTLP HTTP receiver port for the loopback producer listener.";
      };
      grpcPort = mkOption {
        type = types.port;
        default = 4317;
        description = "OTLP gRPC receiver port for the loopback producer listener.";
      };
      httpUrl = mkOption {
        type = types.str;
        readOnly = true;
        description = "OTLP/HTTP endpoint producers push to; derived from `host` and `httpPort`, and readable only once an admitted signal has a destination pipeline to carry it.";
      };
      grpcUrl = mkOption {
        type = types.str;
        readOnly = true;
        description = "OTLP/gRPC endpoint producers push to; derived from `host` and `grpcPort`, and readable only once an admitted signal has a destination pipeline to carry it.";
      };
      ingress = mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              host = mkOption {
                type = types.str;
                description = ''
                  Address the additional OTLP ingress listener binds — the
                  consumer's tailnet (or other) bind address. Required and
                  explicit: there is no automatic address discovery, and a
                  wildcard or empty value fails closed by name.
                '';
              };
              httpPort = mkOption {
                type = types.nullOr types.port;
                default = 4318;
                description = "OTLP HTTP port for the additional ingress. Null disables the HTTP transport.";
              };
              grpcPort = mkOption {
                type = types.nullOr types.port;
                default = null;
                description = "OTLP gRPC port for the additional ingress. Null (the default) disables the gRPC transport.";
              };
            };
          }
        );
        default = null;
        description = ''
          Optional network-facing OTLP listener for a gateway that receives
          telemetry from other hosts. Absent by default: a host that admits OTLP
          signals creates no network listener and no firewall opening. The
          ingress carries the host's admitted `otlp.signals` — it is not another
          routing or signal-selection surface — and leaves the loopback producer
          URLs untouched. The consumer owns interface-specific firewall policy
          and any authentication in front of it.
        '';
      };
    };

    providers = {
      otlpIngest = mkOption {
        type = types.enum [ "otel-collector" ];
        default = "otel-collector";
        description = "Implementation serving OTLP ingest on this host. The enum is the implemented set; an unimplemented value is a contract edit, not a host typo.";
      };
      prometheusScrape = mkOption {
        type = types.enum [
          "vmagent"
          "otel-collector"
        ];
        default = "vmagent";
        description = ''
          Implementation serving Prometheus scrape sources on this host.
          Selection is per capability, so metrics and logs may split later
          without touching registrations. `vmagent` is the default: an agent
          that scrapes and forwards over Prometheus remote write. It can only
          write to destinations the metrics pipeline selects that speak
          `prometheus-remote-write`, so a fanout naming any other protocol is a
          named failure; `otel-collector` remains the override for a host whose
          scraped metrics go to an OTLP destination.
        '';
      };
      journaldIngest = mkOption {
        type = types.enum [ "vector" ];
        default = "vector";
        description = "Implementation shipping this host's journald logs (`services.telemetry.journald`). Per capability like the others: a future implementation is an enum value plus its private module, never a registration change.";
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

    # The host-local log source: systemd's journal. Deliberately opt-in — a
    # host that selected telemetry for metrics or traces must not start
    # shipping its journal as a side effect.
    journald = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Ship this host's systemd journal to `journald.sink.endpoint`.";
      };
      includeUnits = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Only ship entries whose `_SYSTEMD_UNIT` is listed. Empty means every unit. Unit names without a `.` get `.service` appended by the reader.";
      };
      excludeUnits = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Never ship entries whose `_SYSTEMD_UNIT` is listed.";
      };
      sink = {
        endpoint = mkOption {
          type = types.nullOr types.nonEmptyStr;
          default = null;
          description = ''
            Remote log-store ingest URL, including any path the backend needs
            (VictoriaLogs' HTTP JSON-line endpoint is
            `https://<store>/insert/jsonline`). Consumer policy: the aspect
            names no backend, and the whole URL is one value so repointing is
            an edit here alone.
          '';
        };
        streamFields = mkOption {
          type = types.listOf types.str;
          default = [
            "_HOSTNAME"
            "_SYSTEMD_UNIT"
          ];
          description = ''
            Journal fields the backend groups log streams by. Keep this
            low-cardinality: a stream field is a storage/grep partition, and a
            high-cardinality one (a pid, a message) multiplies stream count.
            Mirrors the defaults VictoriaLogs uses for its own journald
            ingestion path.
          '';
        };
      };
      buffer = {
        maxSizeMb = mkOption {
          type = types.ints.positive;
          default = 512;
          description = "On-disk buffer capacity for log records not yet accepted by the sink. Bounds what an outage can hold, not a lossless-forever promise.";
        };
        whenFull = mkOption {
          type = types.enum [
            "block"
            "drop_newest"
          ];
          default = "block";
          description = "What happens when the buffer is full: `block` stops reading the journal (the journal keeps its own records, so nothing is lost until it rotates) and `drop_newest` discards. Blocking trades memory pressure upstream for durability.";
        };
      };
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
        assertion = cfg.realized || nothingRegistered;
        message = "telemetry: ${orphanReport} configured without the host selecting flake.modules.nixos.telemetry; select that aspect (it realizes the registration) or remove it. A registration is never silently dropped.";
      }
      {
        assertion = !cfg.realized || destinationNames != [ ] || cfg.journald.enable;
        message = "telemetry: the host selected flake.modules.nixos.telemetry without any OTLP destinations or journald shipping; bind a destination or configure the journald sink.";
      }
      {
        assertion = !cfg.journald.enable || cfg.journald.sink.endpoint != null;
        message = "telemetry: journald shipping is enabled but services.telemetry.journald.sink.endpoint is not set; the host's journal has nowhere to go.";
      }
      {
        assertion = cfg.journald.sink.endpoint == null || cfg.journald.enable;
        message = "telemetry: services.telemetry.journald.sink.endpoint is set while journald shipping is disabled; enable it or remove the sink. A registration is never silently dropped.";
      }
      {
        assertion = cfg.journald.sink.endpoint == null || validSinkUrl cfg.journald.sink.endpoint;
        message = "telemetry: journald sink endpoint '${cfg.journald.sink.endpoint}' must be an http:// or https:// URL.";
      }
      {
        assertion = !cfg.realized || isLoopbackHost cfg.otlp.host;
        message = "telemetry: services.telemetry.otlp.host is '${cfg.otlp.host}', but the producer listener is loopback-only. Bind the network-facing listener through services.telemetry.otlp.ingress instead.";
      }
      {
        assertion = duplicateSignals == [ ];
        message = "telemetry: services.telemetry.otlp.signals names ${lib.concatStringsSep ", " (lib.unique duplicateSignals)} more than once; admitted signals are a unique set.";
      }
      {
        assertion = unservedSignals == [ ];
        message = "telemetry: OTLP admits ${lib.concatStringsSep ", " unservedSignals} with no destination pipeline to carry them; bind a destination accepting the signal or remove it from services.telemetry.otlp.signals. A receiver never acknowledges what it cannot export.";
      }
      {
        assertion =
          ingressHosts == [ ]
          || !builtins.any (
            listener: listener.host == "" || builtins.elem listener.host wildcardHosts
          ) ingressHosts;
        message = "telemetry: services.telemetry.otlp.ingress.host must be an explicit bind address, not wildcard or empty; a wildcard ingress would expose the collector on every interface. Set the consumer's tailnet (or other) address.";
      }
      {
        assertion = ingressHosts == [ ] || ingressTransports != [ ];
        message = "telemetry: services.telemetry.otlp.ingress sets no HTTP or gRPC port; declare at least one transport or remove the ingress.";
      }
      {
        assertion = ingressHosts == [ ] || admittedSignals != [ ];
        message = "telemetry: services.telemetry.otlp.ingress is configured while services.telemetry.otlp.signals is empty; the ingress carries the host's admitted OTLP signals, so declare at least one signal or remove the ingress.";
      }
      {
        assertion = cfg.otlp.httpPort != cfg.otlp.grpcPort;
        message = "telemetry: services.telemetry.otlp.httpPort and grpcPort must differ; both bind port ${toString cfg.otlp.httpPort}.";
      }
      {
        assertion =
          ingress == null
          || ingress.httpPort == null
          || ingress.grpcPort == null
          || ingress.httpPort != ingress.grpcPort;
        message = "telemetry: services.telemetry.otlp.ingress.httpPort and grpcPort must differ when both transports are enabled.";
      }
      {
        assertion = listenerCollisions == [ ];
        message = "telemetry: services.telemetry.otlp.ingress binds ${lib.concatStringsSep ", " listenerCollisions}, the same address and transport port as the local producer listener; the two listeners must be distinct.";
      }
      {
        assertion = !cfg.realized || secretNamesMatch;
        message = "telemetry: secretFiles and secretKeys IDs must match; secretFiles has ${lib.concatStringsSep ", " secretIds} and secretKeys has ${lib.concatStringsSep ", " (builtins.attrNames cfg.secretKeys)}.";
      }
      {
        assertion = !cfg.realized || validSecretIds;
        message = "telemetry: secret IDs must contain only letters, digits, or underscores; got ${
          lib.concatStringsSep ", " (
            builtins.filter (id: builtins.match "[A-Za-z0-9_]+" id == null) secretIds
          )
        }.";
      }
      {
        assertion = !cfg.realized || unknownHeaderSecrets == [ ];
        message = "telemetry: destination header(s) reference unknown secret(s) ${lib.concatStringsSep ", " unknownHeaderSecrets}; declare them in services.telemetry.secretFiles and secretKeys or fix the reference.";
      }
    ];
  };
}
