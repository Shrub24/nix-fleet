# The host-local telemetry contract: one implementation-agnostic namespace.
# Registrations are dormant data; composition of a lane selects a consumer.
{
  config,
  lib,
  options,
  ...
}:
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
    lib.optional ((listener.httpPort or null) != null) {
      inherit (listener) host;
      port = listener.httpPort;
    }
    ++ lib.optional ((listener.grpcPort or null) != null) {
      inherit (listener) host;
      port = listener.grpcPort;
    }
  ) ingressHosts;
  routeIngressBinds = lib.concatMap (
    route:
    let
      listener = routeIngress route;
    in
    lib.optional (listener != null && listener.httpPort != null) {
      inherit route;
      inherit (listener) host;
      port = listener.httpPort;
    }
    ++ lib.optional (listener != null && listener.grpcPort != null) {
      inherit route;
      inherit (listener) host;
      port = listener.grpcPort;
    }
  ) routeNames;
  # Reported as the consumer spelled it, so the named error points at the value
  # that has to change.
  listenerCollisions = map (bind: "${bind.host}:${toString bind.port}") (
    builtins.filter (
      ingressBind: builtins.any (localBind: bindsSameSocket localBind ingressBind) localBinds
    ) ingressBinds
  );
  ingressTransports = lib.concatMap (
    listener:
    lib.optional ((listener.httpPort or null) != null) "http"
    ++ lib.optional ((listener.grpcPort or null) != null) "grpc"
  ) ingressHosts;
  localIngressBinds = lib.concatMap (
    listener:
    lib.optional ((listener.httpPort or null) != null) {
      inherit (listener) host;
      port = listener.httpPort;
    }
    ++ lib.optional ((listener.grpcPort or null) != null) {
      inherit (listener) host;
      port = listener.grpcPort;
    }
  ) localBinds;

  # Named routes: additional, explicitly selected OTLP inputs. A route inherits
  # nothing — neither the general route's pipelines nor destination presence —
  # because "this backend exists" is not "this audience wants it". Route
  # identity is the listener a producer sends to; no span or resource attribute
  # ever selects the route, and this contract adds no authentication.
  routeNames = builtins.attrNames cfg.routes;
  routeSignals = route: cfg.routes.${route}.signals;
  routeIngress = route: cfg.routes.${route}.ingress;
  duplicatesOf =
    values:
    builtins.filter (
      value: builtins.length (builtins.filter (other: other == value) values) > 1
    ) values;
  routePipelineNames = lib.genAttrs routeNames (
    route:
    lib.genAttrs allSignals (
      signal:
      builtins.seq validatedDestinationCount (
        let
          selected = cfg.routes.${route}.pipelines.${signal};
        in
        map (
          name:
          if !(builtins.hasAttr name cfg.destinations) then
            throw "telemetry: route '${route}' ${signal} pipeline references unknown destination '${name}'"
          else if !(acceptsSignal signal name) then
            throw "telemetry: route '${route}' ${signal} pipeline selects destination '${name}', which does not accept ${signal} (accepts ${
              lib.concatStringsSep ", " cfg.destinations.${name}.signals
            })"
          else
            name
        ) (if selected == null then [ ] else selected)
      )
    )
  );
  validatedRoutePipelines = builtins.deepSeq routePipelineNames (builtins.length routeNames);
  invalidRouteNames = builtins.filter (name: builtins.match "[A-Za-z0-9_]+" name == null) routeNames;
  emptyRouteSignals = builtins.filter (route: routeSignals route == [ ]) routeNames;
  duplicateRouteSignals = lib.unique (
    builtins.filter (route: duplicatesOf (routeSignals route) != [ ]) routeNames
  );
  unservedRouteSignals = lib.concatMap (
    route:
    map (signal: "route '${route}' pipeline for ${signal}") (
      builtins.filter (signal: routePipelineNames.${route}.${signal} == [ ]) (routeSignals route)
    )
  ) routeNames;
  missingRouteIngress = builtins.filter (route: routeIngress route == null) routeNames;
  routeIngressHosts = builtins.filter (route: routeIngress route != null) routeNames;
  wildcardRouteIngress = builtins.filter (
    route: (routeIngress route).host == "" || builtins.elem (routeIngress route).host wildcardHosts
  ) routeIngressHosts;
  transportlessRouteIngress = builtins.filter (
    route: (routeIngress route).httpPort == null && (routeIngress route).grpcPort == null
  ) routeIngressHosts;
  equalPortRouteIngress = builtins.filter (
    route:
    (routeIngress route).httpPort != null
    && (routeIngress route).grpcPort != null
    && (routeIngress route).httpPort == (routeIngress route).grpcPort
  ) routeIngressHosts;
  routeBindLabel = bind: "${bind.host}:${toString bind.port}";
  routeCollisions = lib.concatMap (
    bind:
    lib.optional (builtins.any (localBind: bindsSameSocket localBind bind) localIngressBinds)
      "route '${bind.route}' binds ${routeBindLabel bind}, the same address and transport port as the local producer listener"
    ++
      lib.optional (builtins.any (generalBind: bindsSameSocket generalBind bind) ingressBinds)
        "route '${bind.route}' binds ${routeBindLabel bind}, the same address and transport port as services.telemetry.otlp.ingress"
    ++
      map
        (
          other:
          "route '${bind.route}' binds ${routeBindLabel bind}, the same address and transport port as route '${other.route}'"
        )
        (builtins.filter (other: other.route != bind.route && bindsSameSocket other bind) routeIngressBinds)
  ) routeIngressBinds;

  # Credential vocabulary. Provider-independent: validating secret wiring must
  # not depend on whether an OTel instance happens to run, because the scrape
  # provider binds credentials too.
  secretIds = builtins.attrNames cfg.secretFiles;
  validSecretIds = builtins.all (id: builtins.match "[A-Za-z0-9_]+" id != null) secretIds;
  headerSecretIds = lib.unique (
    lib.concatMap (
      name: map (header: header.secret) (lib.attrValues cfg.destinations.${name}.headers)
    ) destinationNames
  );
  unknownHeaderSecrets = builtins.filter (id: !(builtins.hasAttr id cfg.secretFiles)) headerSecretIds;
  unusedBoundSecrets = builtins.filter (
    id:
    cfg.secretFiles.${id} != null
    && builtins.pathExists cfg.secretFiles.${id}
    && !(builtins.elem id headerSecretIds)
  ) secretIds;

  # A sink endpoint is a URL the provider dials; a bare `host:port` is the
  # mistake this catches, not a stylistic preference.
  validSinkUrl = url: lib.hasPrefix "http://" url || lib.hasPrefix "https://" url;

in
{
  options.services.telemetry = {
    scrapeRealization = mkOption {
      type =
        types.unique
          {
            message = "telemetry: scrape realization conflict; compose exactly one of telemetry-vmagent or telemetry-otel-collector-scrape";
          }
          (
            types.enum [
              "vmagent"
              "otel-collector"
            ]
          );
      internal = true;
      description = "Internal exclusive scrape-realization identity.";
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
          default: a destination declares where data
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
        default = throw "telemetry: services.telemetry.otlp.httpUrl was read without composing an OTLP realization; no implementation binds the local OTLP endpoint. Compose telemetry-otlp or telemetry-otel-collector-otlp, or drop the read.";
        description = "OTLP/HTTP endpoint producers push to; derived from `host` and `httpPort`, and readable only once an admitted signal has a destination pipeline to carry it.";
      };
      grpcUrl = mkOption {
        type = types.str;
        default = throw "telemetry: services.telemetry.otlp.grpcUrl was read without composing an OTLP realization; no implementation binds the local OTLP endpoint. Compose telemetry-otlp or telemetry-otel-collector-otlp, or drop the read.";
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

    routes = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            signals = mkOption {
              type = types.listOf (types.enum allSignals);
              default = [ ];
              description = ''
                Signals this route's listener accepts, as a unique nonempty set.
                A route is a second, explicitly selected OTLP input: it admits
                its own signals and inherits nothing from `otlp.signals`, which
                stays the general route's admission set.
              '';
            };
            pipelines = lib.genAttrs allSignals (
              signal:
              mkOption {
                type = types.nullOr (types.listOf types.str);
                default = null;
                description = ''
                  Destination names carrying ${signal} on this route. Unlike the
                  general route, a route derives nothing from destination
                  presence: null (the default) and an empty list both name no
                  destination, and a signal this route accepts with no
                  destination fails closed by name. A route's destinations are
                  only the ones its own pipelines name.
                '';
              }
            );
            ingress = mkOption {
              type = types.nullOr (
                types.submodule {
                  options = {
                    host = mkOption {
                      type = types.str;
                      description = ''
                        Address this route's listener binds — the consumer's
                        tailnet (or other) bind address. Required and explicit:
                        there is no automatic address discovery, and a wildcard
                        or empty value fails closed by name.
                      '';
                    };
                    httpPort = mkOption {
                      type = types.nullOr types.port;
                      default = 4318;
                      description = "OTLP HTTP port for this route. Null disables the HTTP transport.";
                    };
                    grpcPort = mkOption {
                      type = types.nullOr types.port;
                      default = null;
                      description = "OTLP gRPC port for this route. Null (the default) disables the gRPC transport.";
                    };
                  };
                }
              );
              default = null;
              description = ''
                Listener that carries this route: the address and transport
                port(s) a producer selects the route by sending to. Required for
                every route — a route is an input, not a filter — and it must
                not share a socket with the loopback producer listener, the
                general `otlp.ingress`, or another route.
              '';
            };
          };
        }
      );
      default = { };
      description = ''
        Named routes, each with its own listener and its own destination
        policy. Selecting a route is a routing decision, never an
        authorization one: the contract adds no authentication, and the
        consumer owns any admission and firewall policy in front of a listener.
      '';
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
    # shipping its journal as a side effect — and deliberately explicit about
    # scope: `includeUnits` is an allowlist, and an empty allowlist needs
    # `includeAll` to mean the whole journal.
    journald = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Ship this host's systemd journal to `journald.sink.endpoint`.";
      };
      includeUnits = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Only ship entries whose `_SYSTEMD_UNIT` is listed, matched exactly
          and case-sensitively — this is not `journalctl -u`: records the kernel
          or PID 1 logs about a unit usually carry `init.scope`, not the unit's
          own name, and a template instance needs its own exact name
          (`[EMAIL_REDACTED]`, not `foo@.service`). Empty is not "no units" and
          not by itself "every unit": it must be paired with `includeAll`.
          Unit names without a `.` get `.service` appended by the reader.
        '';
      };
      includeAll = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Ship the whole journal, deliberately. An empty `includeUnits` with
          this false fails closed by name: an absent allowlist is a missing
          selection, not a licence to export every unit's records, and the
          fleet baseline forbids whole-journal adoption without an explicit
          policy decision. Setting both is contradictory.
        '';
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
            names no backend, and the whole URL is one value so repointing it is
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

    resolvedRoutePipelines = mkOption {
      type = types.attrsOf (types.attrsOf (types.listOf types.str));
      readOnly = true;
      internal = true;
      description = "Destination names per route and signal after validation; consumed by an implementation that binds routes.";
    };
  };

  config = {
    services.telemetry.resolvedPipelines = lib.genAttrs allSignals resolvedPipeline;
    services.telemetry.resolvedRoutePipelines = builtins.seq validatedRoutePipelines routePipelineNames;

    assertions = [
      {
        assertion = unusedBoundSecrets == [ ];
        message = "telemetry: bound credentials have no declared destination header reference: ${lib.concatStringsSep ", " unusedBoundSecrets}";
      }
      {
        assertion =
          !options.services.telemetry.scrapeRealization.isDefined || builtins.seq cfg.scrapeRealization true;
        message = "telemetry: compose only one scrape realization";
      }
      {
        assertion = cfg.journald.sink.endpoint == null || validSinkUrl cfg.journald.sink.endpoint;
        message = "telemetry: journald sink endpoint '${cfg.journald.sink.endpoint}' must be an http:// or https:// URL.";
      }
      {
        assertion = !cfg.journald.enable || cfg.journald.includeUnits != [ ] || cfg.journald.includeAll;
        message = "telemetry: journald shipping is enabled with an empty includeUnits and includeAll = false; an empty allowlist is not a whole-journal licence. List the operating units this host ships, or set services.telemetry.journald.includeAll = true to export the whole journal deliberately.";
      }
      {
        assertion = !cfg.journald.includeAll || cfg.journald.includeUnits == [ ];
        message = "telemetry: services.telemetry.journald.includeAll is true with a non-empty includeUnits (${lib.concatStringsSep ", " cfg.journald.includeUnits}); the two are contradictory — drop includeUnits to export the whole journal, or drop includeAll to export the listed units.";
      }
      {
        assertion = isLoopbackHost cfg.otlp.host;
        message = "telemetry: services.telemetry.otlp.host is '${cfg.otlp.host}', but the producer listener is loopback-only. Bind the network-facing listener through services.telemetry.otlp.ingress instead.";
      }
      {
        assertion = duplicateSignals == [ ];
        message = "telemetry: services.telemetry.otlp.signals names ${lib.concatStringsSep ", " (lib.unique duplicateSignals)} more than once; admitted signals are a unique set.";
      }
      {
        assertion = admittedSignals == [ ] || unservedSignals == [ ];
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
        assertion = invalidRouteNames == [ ];
        message = "telemetry: route names must contain only letters, digits, or underscores; got ${lib.concatStringsSep ", " invalidRouteNames}.";
      }
      {
        assertion = emptyRouteSignals == [ ];
        message = "telemetry: route(s) ${lib.concatStringsSep ", " emptyRouteSignals} declare no signals; a route binds a listener, so it must carry at least one signal.";
      }
      {
        assertion = duplicateRouteSignals == [ ];
        message = "telemetry: route(s) ${lib.concatStringsSep ", " duplicateRouteSignals} name a signal more than once; a route's signals are a unique set.";
      }
      {
        assertion = unservedRouteSignals == [ ];
        message = "telemetry: ${lib.concatStringsSep ", " unservedRouteSignals} names no destination; a route's destinations are only the ones its own pipelines name, so a carried signal needs the destinations its audience requires — name them, or drop the signal from the route.";
      }
      {
        assertion = missingRouteIngress == [ ];
        message = "telemetry: route(s) ${lib.concatStringsSep ", " missingRouteIngress} declare no ingress; a route is selected by the listener its producers send to, so bind one (host plus an httpPort or grpcPort).";
      }
      {
        assertion = wildcardRouteIngress == [ ];
        message = "telemetry: route(s) ${lib.concatStringsSep ", " wildcardRouteIngress} ingress.host must be an explicit bind address, not wildcard or empty; a wildcard route listener would expose the collector on every interface.";
      }
      {
        assertion = transportlessRouteIngress == [ ];
        message = "telemetry: route(s) ${lib.concatStringsSep ", " transportlessRouteIngress} ingress sets no HTTP or gRPC port; declare at least one transport or remove the ingress.";
      }
      {
        assertion = equalPortRouteIngress == [ ];
        message = "telemetry: route(s) ${lib.concatStringsSep ", " equalPortRouteIngress} ingress.httpPort and grpcPort must differ when both transports are enabled.";
      }
      {
        assertion = routeCollisions == [ ];
        message = "telemetry: ${lib.concatStringsSep "; " routeCollisions}; the listeners must be distinct.";
      }
      {
        assertion = secretIds == builtins.attrNames cfg.secretKeys;
        message = "telemetry: secretFiles and secretKeys IDs must match; secretFiles has ${lib.concatStringsSep ", " secretIds} and secretKeys has ${lib.concatStringsSep ", " (builtins.attrNames cfg.secretKeys)}.";
      }
      {
        assertion = validSecretIds;
        message = "telemetry: secret IDs must contain only letters, digits, or underscores; got ${
          lib.concatStringsSep ", " (
            builtins.filter (id: builtins.match "[A-Za-z0-9_]+" id == null) secretIds
          )
        }.";
      }
      {
        assertion = unknownHeaderSecrets == [ ];
        message = "telemetry: destination header(s) reference unknown secret(s) ${lib.concatStringsSep ", " unknownHeaderSecrets}; declare them in services.telemetry.secretFiles and secretKeys or fix the reference.";
      }
    ];
  };
}
