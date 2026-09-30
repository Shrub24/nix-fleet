# OpenTelemetry Collector implementation of the host-local telemetry contract
# (flake.modules.nixos.telemetry, imported as a private module — this is not a
# public aspect). It translates `services.telemetry.{otlp,scrape,destinations,
# pipelines,secretFiles,secretKeys}` into nixpkgs'
# services.opentelemetry-collector settings.
#
# `services.otel-collector.*` carries only what is genuinely specific to this
# implementation: the package, the resource processor, extra processors, and a
# raw exporter override. Remote destinations, their protocols, headers, and the
# per-signal fanout are contract-level (`services.telemetry`), so swapping the
# implementation or repointing a backend never reshapes a registration.
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

  secretIds = builtins.attrNames telemetry.secretFiles;
  secretReady =
    id: telemetry.secretFiles.${id} != null && builtins.pathExists telemetry.secretFiles.${id};
  envName = id: "OTELCOL_${id}";

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

  destinationNames = builtins.attrNames telemetry.destinations;
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
      "${component}/${name}" = lib.recursiveUpdate base (cfg.exporterExtra.${name} or { });
    };

  # Receiver that feeds each signal. OTLP is the base ingest path; the
  # prometheus receiver exists only for a scrape-capable selection with
  # sources registered.
  receiversFor =
    signal:
    lib.optional servesOtlpIngest "otlp"
    ++ lib.optional (signal == "metrics" && hasScrapes && servesPrometheusScrape) "prometheus";

  # A resource processor is in play either generated from resourceAttributes or
  # declared directly; either way it must be listed in the pipeline, or the
  # config defines a processor no pipeline runs.
  resourceProcessor = cfg.resourceAttributes != { } || cfg.processors ? resource;
  processorOrder =
    lib.optionals (cfg.processors ? memory_limiter) [ "memory_limiter" ]
    ++ lib.optionals resourceProcessor [ "resource" ]
    ++ lib.optionals (cfg.processors ? batch) [ "batch" ]
    ++ builtins.filter (name: name != "memory_limiter" && name != "batch" && name != "resource") (
      builtins.attrNames cfg.processors
    );

  renderPipeline =
    signal: names:
    if names == [ ] then
      { }
    else
      {
        ${signal} = {
          receivers = receiversFor signal;
          processors = processorOrder;
          exporters = map (
            name: "${exporterComponent telemetry.destinations.${name}.protocol}/${name}"
          ) names;
        };
      };

  secretNamesMatch = secretIds == builtins.attrNames telemetry.secretKeys;
  validSecretIds = builtins.all (id: builtins.match "[A-Za-z0-9_]+" id != null) secretIds;
  validProcessors = !(cfg.processors ? resource) || cfg.resourceAttributes == { };
  boundSecrets =
    if !secretNamesMatch then
      throw "telemetry: secretFiles and secretKeys IDs must match"
    else if !validSecretIds then
      throw "telemetry: secret IDs must contain only letters, digits, or underscores"
    else
      builtins.filter secretReady secretIds;

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
  ) destinationNames;
in
{
  imports = [ ../../../notifications/notify/_notify-events.nix ];

  options.services.otel-collector = {
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.opentelemetry-collector-contrib;
      description = "Collector implementation package; contrib includes remote-write and log components.";
    };
    resourceAttributes = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Resource attribute names and values upserted into all signals.";
    };
    processors = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      description = "Collector processor configuration; memory_limiter is ordered first when present.";
    };
    exporterExtra = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      description = "Additional exporter configuration by destination name, recursively overriding generated fields. Collector-specific escape hatch.";
    };
  };

  config = {
    services.otel-collector.processors = {
      memory_limiter = lib.mkDefault {
        check_interval = "1s";
        limit_percentage = 75;
        spike_limit_percentage = 15;
      };
      batch = lib.mkDefault { };
    };
    services.notify.events = lib.optionalAttrs (destinationNames != [ ]) {
      opentelemetry-collector.failure = { };
    };

    services.opentelemetry-collector = {
      enable = destinationNames != [ ];
      inherit (cfg) package;
      settings =
        if !secretNamesMatch then
          throw "telemetry: secretFiles and secretKeys IDs must match"
        else if !validSecretIds then
          throw "telemetry: secret IDs must contain only letters, digits, or underscores"
        else if !validProcessors then
          throw "otel-collector: configure the resource processor through resourceAttributes, not processors.resource"
        else if hasScrapes && telemetry.resolvedPipelines.metrics == [ ] then
          throw "telemetry: ${toString (builtins.length scrapeConfigs)} scrape source(s) are registered but the metrics pipeline has no destination to carry them"
        else
          {
            receivers =
              lib.optionalAttrs servesOtlpIngest {
                otlp.protocols = {
                  grpc.endpoint = "${telemetry.otlp.host}:${toString telemetry.otlp.grpcPort}";
                  http.endpoint = "${telemetry.otlp.host}:${toString telemetry.otlp.httpPort}";
                };
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
            exporters = lib.foldl' lib.recursiveUpdate { } (map renderDestination destinationNames);
            service.pipelines = lib.foldl' lib.recursiveUpdate { } (
              lib.mapAttrsToList renderPipeline telemetry.resolvedPipelines
            );
          };
      validateConfigOverrides = headerOverrides;
    };

    sops.secrets = lib.genAttrs (map (id: "otel-collector/${id}") boundSecrets) (
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
    sops.templates."otel-collector.env" = lib.mkIf (boundSecrets != [ ]) {
      content =
        lib.concatMapStringsSep "\n" (
          id: "${envName id}=${config.sops.placeholder."otel-collector/${id}"}"
        ) boundSecrets
        + "\n";
      restartUnits = [ "opentelemetry-collector.service" ];
    };
    systemd.services = lib.optionalAttrs (destinationNames != [ ] && boundSecrets != [ ]) {
      opentelemetry-collector.serviceConfig.EnvironmentFile = [
        config.sops.templates."otel-collector.env".path
      ];
    };
  };
}
