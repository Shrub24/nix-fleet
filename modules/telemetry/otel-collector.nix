# OpenTelemetry Collector contributor to flake.modules.nixos.telemetry. It
# translates `services.telemetry.{otlp,scrape,destinations,pipelines,secretFiles,
# secretKeys}` into nixpkgs' services.opentelemetry-collector settings.
#
# An OTel instance runs only for work it can serve: admitted OTLP signals
# (which may arrive on the loopback producer listener and, if declared, the
# additional network ingress) or, when it is the selected scrape provider,
# registered scrape sources. A destination alone starts nothing, and only the
# exporters the active signals actually select are rendered — with their
# credentials.
#
# `services.otel-collector.*` carries only what is genuinely specific to this
# implementation: the package, the resource processor, extra processors, the
# delivery-health metrics port, and a raw exporter override. Remote
# destinations, their protocols, headers, and the per-signal fanout are
# contract-level (`services.telemetry`), so swapping the implementation or
# repointing a backend never reshapes a registration.
#
# Delivery durability is per exporter, in the mechanism its own component
# supports: OTLP exporters get an exporterhelper `sending_queue` persisted
# through the file_storage extension with `fsync`, and the Prometheus
# remote-write exporter (which rejects `sending_queue` in Collector Contrib
# 0.155.0) persists through its WAL. Both keep their own state under the
# nixpkgs unit's StateDirectory.
_: {
  flake.modules.nixos.telemetry =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.otel-collector;
      telemetry = config.services.telemetry;

      servesOtlpIngest = telemetry.providers.otlpIngest == "otel-collector";
      servesPrometheusScrape = telemetry.providers.prometheusScrape == "otel-collector";

      exporterComponent =
        protocol:
        {
          otlp-grpc = "otlp";
          otlp-http = "otlphttp";
          prometheus-remote-write = "prometheusremotewrite";
        }
        .${protocol};
      secretReady =
        id:
        (telemetry.secretFiles.${id} or null) != null && builtins.pathExists telemetry.secretFiles.${id};
      envName = id: "OTELCOL_${id}";
      bindEndpoint =
        host: port:
        let
          address = if lib.hasInfix ":" host && !lib.hasPrefix "[" host then "[${host}]" else host;
        in
        "${address}:${toString port}";

      # A destination's header value references a secret by ID; the file is loaded
      # into the unit environment at runtime, so credentials never enter the store.
      headerValue =
        destination: header:
        let
          id = header.secret;
        in
        if !(builtins.hasAttr id telemetry.secretFiles) || !(secretReady id) then
          throw "telemetry: destination '${destination}' header references unknown or unbound secret '${id}'"
        else
          "${header.prefix}\${env:${envName id}}";

      # A scrape source the contract registered, in the Prometheus receiver's
      # native scrape-config shape. The registration name is the job name.
      scrapeConfigs = lib.mapAttrsToList (name: source: {
        job_name = name;
        scrape_interval = source.interval;
        metrics_path = source.metricsPath;
        inherit (source) scheme;
        static_configs = [
          {
            targets = [ "${source.target}:${toString source.port}" ];
            inherit (source) labels;
          }
        ];
      }) telemetry.scrape;
      hasScrapes = scrapeConfigs != [ ];

      # Work predicates. A destination is where data goes, never evidence that an
      # input exists: only admitted OTLP signals and registered scrape sources ask
      # this collector to run. The explicit scrape override therefore works with no
      # OTLP receiver at all.
      admittedSignals = telemetry.otlp.signals;
      otlpWork = servesOtlpIngest && admittedSignals != [ ];
      scrapeWork = servesPrometheusScrape && hasScrapes;
      active = otlpWork || scrapeWork;
      ingress = telemetry.otlp.ingress;
      ingressActive = otlpWork && ingress != null;

      # Signals this instance actually carries, and the exporters those signals
      # actually select. Everything else — exporters, credentials, validation
      # overrides — stays unrendered, so an unused backend is invisible here.
      otelSignals = lib.unique (admittedSignals ++ lib.optional scrapeWork "metrics");
      activeExporters = lib.unique (
        lib.concatMap (signal: telemetry.resolvedPipelines.${signal}) otelSignals
      );

      exporterIds =
        names: map (name: "${exporterComponent telemetry.destinations.${name}.protocol}/${name}") names;

      # Receiver that feeds each signal locally. OTLP is the base ingest path; the
      # prometheus receiver exists only for a scrape-capable selection with sources
      # registered.
      localReceiversFor =
        signal:
        lib.optional otlpWork "otlp" ++ lib.optional (signal == "metrics" && scrapeWork) "prometheus";

      # The additional network ingress: an OTLP receiver distinct from the local
      # one, bound to the consumer's explicit address and selected transports.
      ingressProtocols =
        if !ingressActive then
          { }
        else
          lib.optionalAttrs (ingress.httpPort != null) {
            http.endpoint = bindEndpoint ingress.host ingress.httpPort;
          }
          // lib.optionalAttrs (ingress.grpcPort != null) {
            grpc.endpoint = bindEndpoint ingress.host ingress.grpcPort;
          };

      # A resource processor is in play either generated from resourceAttributes or
      # declared directly; either way it must be listed in the pipeline, or the
      # config defines a processor no pipeline runs.
      resourceProcessor = cfg.resourceAttributes != { } || cfg.processors ? resource;
      generatedResource = cfg.resourceAttributes != { };
      extraProcessors = builtins.filter (
        name: name != "memory_limiter" && name != "batch" && name != "resource"
      ) (builtins.attrNames cfg.processors);
      localProcessors =
        lib.optionals (cfg.processors ? memory_limiter) [ "memory_limiter" ]
        ++ lib.optionals resourceProcessor [ "resource" ]
        ++ lib.optionals (cfg.processors ? batch) [ "batch" ]
        ++ extraProcessors;
      # Local enrichment must not relabel forwarded telemetry as this host's, so the
      # provider-generated resource processor is applied to locally received data
      # only. A consumer's own `processors.resource` is an explicit choice and keeps
      # applying to both.
      ingressProcessors =
        if generatedResource then
          builtins.filter (name: name != "resource") localProcessors
        else
          localProcessors;

      # One stable exporter ID per active destination, each with its own persistent
      # bounded delivery state: fan-out is independent, so one unavailable backend
      # fills only its own backlog. The OTLP exporters use an exporterhelper queue
      # backed by the file_storage extension, sized in serialized bytes (the queue
      # bounds buffered payload, not physical database size — v0.155.0's
      # file_storage exposes no database cap). The Prometheus remote-write exporter
      # does not accept `sending_queue` in this pin (verified against
      # otelcol-contrib 0.155.0: "'prometheusremotewriteexporter.Config' has invalid
      # keys: sending_queue"), so it persists through its own write-ahead log and
      # keeps its own finite queue there — see the module header.
      queuePayloadBytes = 268435456;
      persistentQueue = {
        sending_queue = {
          enabled = true;
          sizer = "bytes";
          queue_size = queuePayloadBytes;
          # Overflow rejects the request instead of stalling the receiver; the
          # rejection is counted as an enqueue failure and returned to the caller.
          block_on_overflow = false;
          storage = "file_storage";
          # Queue-integrated batching: acceptance commits to persistent storage
          # rather than to a volatile pre-export batch processor.
          batch = { };
        };
        retry_on_failure = {
          enabled = true;
          # 0 = a retryable failure keeps its place until capacity runs out; it does
          # not expire at the upstream five-minute default.
          max_elapsed_time = 0;
        };
      };
      # prometheus-remote-write's own durable delivery state: a WAL under the same
      # service state directory, plus its finite in-memory queue made explicit (the
      # unit is queued metrics, not bytes — this exporter cannot express a
      # serialized-payload cap).
      remoteWriteQueueSize = 10000;
      deliveryFor =
        name:
        if telemetry.destinations.${name}.protocol == "prometheus-remote-write" then
          {
            retry_on_failure = {
              enabled = true;
              max_elapsed_time = 0;
            };
            remote_write_queue = {
              enabled = true;
              queue_size = remoteWriteQueueSize;
            };
            wal.directory = "${stateRoot}/queue/wal-${name}";
          }
        else
          persistentQueue;

      renderDestination =
        name:
        let
          destination = telemetry.destinations.${name};
          component = exporterComponent destination.protocol;
          base = {
            inherit (destination) endpoint;
          }
          //
            lib.optionalAttrs
              (destination.protocol == "otlp-grpc" && lib.hasPrefix "http://" destination.endpoint)
              {
                tls.insecure = true;
              }
          // lib.optionalAttrs (destination.headers != { }) {
            headers = lib.mapAttrs (_: headerValue name) destination.headers;
          };
        in
        {
          "${component}/${name}" = lib.recursiveUpdate (base // deliveryFor name) (
            cfg.exporterExtra.${name} or { }
          );
        };

      renderLocalPipeline =
        signal:
        if !(builtins.elem signal otelSignals) then
          { }
        else
          {
            ${signal} = {
              receivers = localReceiversFor signal;
              processors = localProcessors;
              exporters = exporterIds telemetry.resolvedPipelines.${signal};
            };
          };

      # Forwarded telemetry keeps its originating service/host identity: the ingress
      # pipeline shares the selected exporter IDs but not the local enrichment.
      renderIngressPipeline =
        signal:
        if !ingressActive || !(builtins.elem signal admittedSignals) then
          { }
        else
          {
            "${signal}/ingress" = {
              receivers = [ "otlp/ingress" ];
              processors = ingressProcessors;
              exporters = exporterIds telemetry.resolvedPipelines.${signal};
            };
          };

      validProcessors = !(cfg.processors ? resource) || cfg.resourceAttributes == { };
      boundSecretIds = builtins.filter secretReady (
        lib.unique (
          lib.concatMap (
            name: map (header: header.secret) (lib.attrValues telemetry.destinations.${name}.headers)
          ) activeExporters
        )
      );

      # Header values are validated at build time without the real credential:
      # otelcol validates ${env:...} references against stub values.
      headerOverrides = lib.concatMap (
        name:
        lib.mapAttrsToList (
          headerName: _:
          "exporters::${
            exporterComponent telemetry.destinations.${name}.protocol
          }/${name}::headers::${headerName}=stub"
        ) telemetry.destinations.${name}.headers
      ) activeExporters;

      stateRoot = "/var/lib/opentelemetry-collector";
    in
    {
      imports = [ ../notifications/notify/_notify-events.nix ];

      options.services.otel-collector = {
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.opentelemetry-collector-contrib;
          description = "Collector implementation package; contrib includes remote-write and log components.";
        };
        resourceAttributes = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = ''
            Resource attribute names and values upserted into locally received
            signals. Applied to the loopback producer listener and local scrape
            pipelines only: forwarded ingress telemetry keeps its originating
            resource identity.
          '';
        };
        processors = lib.mkOption {
          type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
          default = { };
          description = ''
            Collector processor configuration; memory_limiter is ordered first when
            present. Explicit custom processors are an escape hatch: an asynchronous
            one placed before export weakens the default guarantee that acceptance
            means the data is in its persistent queue.
          '';
        };
        metricsPort = lib.mkOption {
          type = lib.types.port;
          default = 9464;
          description = ''
            Loopback port for this collector's own operational metrics (exporter
            queue size/capacity, enqueue and send failures). Explicit so the
            implicit all-interface port 8888 listener is never created. Host-local
            and unopened by any firewall rule; a consumer that wants these collected
            registers `services.telemetry.scrape.<job>` for this port.
          '';
        };
        exporterExtra = lib.mkOption {
          type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
          default = { };
          description = "Additional exporter configuration by destination name, recursively overriding generated fields. Collector-specific escape hatch (raw upstream settings win over the persistent-queue defaults).";
        };
      };

      config = {
        services.otel-collector.processors.memory_limiter = lib.mkDefault {
          check_interval = "1s";
          limit_percentage = 75;
          spike_limit_percentage = 15;
        };
        services.notify.events = lib.optionalAttrs active {
          opentelemetry-collector.failure = { };
        };

        services.opentelemetry-collector = {
          enable = active;
          inherit (cfg) package;
          settings =
            if !validProcessors then
              throw "otel-collector: configure the resource processor through resourceAttributes, not processors.resource"
            else if scrapeWork && telemetry.resolvedPipelines.metrics == [ ] then
              throw "telemetry: ${toString (builtins.length scrapeConfigs)} scrape source(s) are registered but the metrics pipeline has no destination to carry them"
            else if !active then
              { }
            else
              {
                receivers =
                  lib.optionalAttrs otlpWork {
                    otlp.protocols = {
                      grpc.endpoint = bindEndpoint telemetry.otlp.host telemetry.otlp.grpcPort;
                      http.endpoint = bindEndpoint telemetry.otlp.host telemetry.otlp.httpPort;
                    };
                  }
                  // lib.optionalAttrs ingressActive {
                    "otlp/ingress".protocols = ingressProtocols;
                  }
                  // lib.optionalAttrs (hasScrapes && servesPrometheusScrape) {
                    prometheus.config.scrape_configs = scrapeConfigs;
                  };
                processors =
                  cfg.processors
                  // lib.optionalAttrs (cfg.resourceAttributes != { }) {
                    resource.attributes = lib.mapAttrsToList (key: value: {
                      inherit key value;
                      action = "upsert";
                    }) cfg.resourceAttributes;
                  };
                extensions.file_storage = {
                  directory = "${stateRoot}/queue";
                  create_directory = true;
                  directory_permissions = "0700";
                  fsync = true;
                  compaction = {
                    on_start = true;
                    on_rebound = true;
                    directory = "${stateRoot}/queue/compaction";
                  };
                };
                exporters = lib.foldl' lib.recursiveUpdate { } (map renderDestination activeExporters);
                service = {
                  extensions = [ "file_storage" ];
                  telemetry.metrics.readers = [
                    {
                      pull.exporter.prometheus = {
                        host = "127.0.0.1";
                        port = cfg.metricsPort;
                      };
                    }
                  ];
                  pipelines = lib.foldl' lib.recursiveUpdate { } (
                    map renderLocalPipeline otelSignals ++ map renderIngressPipeline admittedSignals
                  );
                };
              };
          validateConfigOverrides = headerOverrides;
        };

        sops.secrets = lib.genAttrs (map (id: "otel-collector/${id}") boundSecretIds) (
          name:
          let
            id = lib.removePrefix "otel-collector/" name;
          in
          {
            sopsFile = telemetry.secretFiles.${id};
            key = telemetry.secretKeys.${id};
            restartUnits = [ "opentelemetry-collector.service" ];
          }
        );
        sops.templates."otel-collector.env" = lib.mkIf (boundSecretIds != [ ]) {
          content =
            lib.concatMapStringsSep "\n" (
              id: "${envName id}=${config.sops.placeholder."otel-collector/${id}"}"
            ) boundSecretIds
            + "\n";
          restartUnits = [ "opentelemetry-collector.service" ];
        };
        systemd.services = lib.optionalAttrs (active && boundSecretIds != [ ]) {
          opentelemetry-collector.serviceConfig.EnvironmentFile = [
            config.sops.templates."otel-collector.env".path
          ];
        };
      };
    };
}
