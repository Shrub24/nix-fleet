# Common host settings for either OpenTelemetry Collector realization.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.otel-collector;
  telemetry = config.services.telemetry;
  stateRoot = "/var/lib/opentelemetry-collector";
  component =
    protocol:
    {
      otlp-grpc = "otlp";
      otlp-http = "otlphttp";
      prometheus-remote-write = "prometheusremotewrite";
    }
    .${protocol};
  active = lib.unique cfg.exporterDestinations;
  ready =
    id:
    (telemetry.secretFiles.${id} or null) != null && builtins.pathExists telemetry.secretFiles.${id};
  envName = id: "OTELCOL_${id}";
  persistentQueue = {
    sending_queue = {
      enabled = true;
      sizer = "bytes";
      queue_size = 268435456;
      block_on_overflow = false;
      storage = "file_storage";
      batch = { };
    };
    retry_on_failure = {
      enabled = true;
      max_elapsed_time = 0;
    };
  };
  render =
    name:
    let
      d = telemetry.destinations.${name};
      protocol = component d.protocol;
      headers = lib.mapAttrs (
        _: h:
        if !(builtins.hasAttr h.secret telemetry.secretFiles) || !(ready h.secret) then
          throw "telemetry: destination '${name}' header references unknown or unbound secret '${h.secret}'"
        else
          "${h.prefix}\${env:${envName h.secret}}"
      ) d.headers;
      base = {
        inherit (d) endpoint;
      }
      // lib.optionalAttrs (d.protocol == "otlp-grpc" && lib.hasPrefix "http://" d.endpoint) {
        tls.insecure = true;
      }
      // lib.optionalAttrs (d.headers != { }) { inherit headers; };
      delivery =
        if d.protocol == "prometheus-remote-write" then
          {
            retry_on_failure = {
              enabled = true;
              max_elapsed_time = 0;
            };
            remote_write_queue = {
              enabled = true;
              queue_size = 10000;
            };
            wal.directory = "${stateRoot}/queue/wal-${name}";
          }
        else
          persistentQueue;
    in
    {
      "${protocol}/${name}" = lib.recursiveUpdate (base // delivery) (cfg.exporterExtra.${name} or { });
    };
  referencedSecretIds = lib.unique (
    lib.concatMap (
      name: map (header: header.secret) (lib.attrValues telemetry.destinations.${name}.headers)
    ) active
  );
  secretIds = builtins.filter ready referencedSecretIds;
  overrides = lib.concatMap (
    name:
    lib.mapAttrsToList (
      header: _:
      "exporters::${component telemetry.destinations.${name}.protocol}/${name}::headers::${header}=stub"
    ) telemetry.destinations.${name}.headers
  ) active;
  generatedResource = cfg.resourceAttributes != { };
  processors =
    cfg.processors
    // lib.optionalAttrs generatedResource {
      resource.attributes = lib.mapAttrsToList (key: value: {
        inherit key value;
        action = "upsert";
      }) cfg.resourceAttributes;
    };
in
{
  imports = [ ../modules/notifications/notify/_notify-events.nix ];
  options.services.otel-collector = {
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.opentelemetry-collector-contrib;
    };
    resourceAttributes = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
    };
    processors = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
    };
    metricsPort = lib.mkOption {
      type = lib.types.port;
      default = 9464;
    };
    exporterExtra = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
    };
    exporterDestinations = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      internal = true;
    };
  };
  config = {
    assertions = [
      {
        assertion = !generatedResource || !(cfg.processors ? resource);
        message = "otel-collector: configure the resource processor through resourceAttributes, not processors.resource";
      }
    ];
    services.otel-collector.processors.memory_limiter = lib.mkDefault {
      check_interval = "1s";
      limit_percentage = 75;
      spike_limit_percentage = 15;
    };
    services.opentelemetry-collector = {
      enable = true;
      inherit (cfg) package;
      settings = {
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
        inherit processors;
        exporters = lib.foldl' lib.recursiveUpdate { } (map render active);
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
        };
      };
      validateConfigOverrides = overrides;
    };
    services.telemetry.scrape.otel-collector-health = {
      target = "127.0.0.1";
      port = cfg.metricsPort;
      labels.instance = "${config.networking.hostName}:otel-collector";
    };
    services.notify.events.opentelemetry-collector.failure = { };
    sops.secrets = lib.genAttrs (map (id: "otel-collector/${id}") secretIds) (
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
    sops.templates."otel-collector.env" = lib.mkIf (secretIds != [ ]) {
      content =
        lib.concatMapStringsSep "\n" (
          id: "${envName id}=${config.sops.placeholder."otel-collector/${id}"}"
        ) secretIds
        + "\n";
      restartUnits = [ "opentelemetry-collector.service" ];
    };
    systemd.services = lib.optionalAttrs (secretIds != [ ]) {
      opentelemetry-collector.serviceConfig.EnvironmentFile = [
        config.sops.templates."otel-collector.env".path
      ];
    };
  };
}
