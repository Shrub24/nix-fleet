_: {
  flake.modules.nixos.otel-collector =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.otel-collector;
      exporterNames = builtins.attrNames cfg.exporters;
      secretIds = builtins.attrNames cfg.secretFiles;
      supportedSignals =
        type:
        if type == "prometheusremotewrite" then
          [ "metrics" ]
        else
          [
            "traces"
            "metrics"
            "logs"
          ];
      secretName = id: "otel-collector/${id}";
      envName = id: "OTELCOL_${id}";
      secretReady = id: cfg.secretFiles.${id} != null && builtins.pathExists cfg.secretFiles.${id};
      headerValue =
        header:
        let
          id = header.secret;
        in
        if !(builtins.hasAttr id cfg.secretFiles) || !(secretReady id) then
          throw "otel-collector: header references unknown or unbound secret '${id}'"
        else
          "${header.prefix}\${env:${envName id}}";
      renderExporter =
        name: exporter:
        let
          key = "${exporter.type}/${name}";
          base =
            lib.optionalAttrs (exporter.endpoint != null) { inherit (exporter) endpoint; }
            //
              lib.optionalAttrs
                (exporter.type == "otlp" && exporter.endpoint != null && lib.hasPrefix "http://" exporter.endpoint)
                {
                  tls.insecure = true;
                }
            // lib.optionalAttrs (exporter.headers != { }) {
              headers = lib.mapAttrs (_header: headerValue) exporter.headers;
            };
        in
        if exporter.type != "debug" && exporter.endpoint == null then
          throw "otel-collector: exporter '${name}' (${exporter.type}) requires endpoint"
        else
          {
            ${key} = lib.recursiveUpdate base exporter.extra;
          };
      # A resource processor is in play either generated from
      # resourceAttributes or declared directly; either way it must be listed in
      # the pipeline, or the config defines a processor no pipeline runs.
      resourceProcessor = cfg.resourceAttributes != { } || cfg.processors ? resource;
      processorOrder =
        lib.optionals (cfg.processors ? memory_limiter) [ "memory_limiter" ]
        ++ lib.optionals resourceProcessor [ "resource" ]
        ++ lib.optionals (cfg.processors ? batch) [ "batch" ]
        ++ builtins.filter (name: name != "memory_limiter" && name != "batch" && name != "resource") (
          builtins.attrNames cfg.processors
        );
      resolvePipeline =
        signal: selected:
        let
          names =
            if selected == null then
              builtins.filter (
                name: builtins.elem signal (supportedSignals cfg.exporters.${name}.type)
              ) exporterNames
            else
              selected;
          checked = map (
            name:
            if !(builtins.hasAttr name cfg.exporters) then
              throw "otel-collector: ${signal} pipeline references unknown exporter '${name}'"
            else if !(builtins.elem signal (supportedSignals cfg.exporters.${name}.type)) then
              throw "otel-collector: ${signal} pipeline exporter '${name}' cannot carry ${signal}"
            else
              "${cfg.exporters.${name}.type}/${name}"
          ) names;
        in
        if selected != null && names == [ ] then
          throw "otel-collector: ${signal} pipeline explicitly resolves empty"
        else if checked == [ ] then
          { }
        else
          {
            ${signal} = {
              receivers = [ "otlp" ];
              processors = processorOrder;
              exporters = checked;
            };
          };
      secretNamesMatch = secretIds == builtins.attrNames cfg.secretKeys;
      validSecretIds = builtins.all (id: builtins.match "[A-Za-z0-9_]+" id != null) secretIds;
      validProcessors = !(cfg.processors ? resource) || cfg.resourceAttributes == { };
      headers = lib.concatMap (
        name:
        lib.mapAttrsToList (
          headerName: _: "exporters::${cfg.exporters.${name}.type}/${name}::headers::${headerName}=stub"
        ) cfg.exporters.${name}.headers
      ) exporterNames;
      boundSecrets =
        if !secretNamesMatch then
          throw "otel-collector: secretFiles and secretKeys IDs must match"
        else if !validSecretIds then
          throw "otel-collector: secret IDs must contain only letters, digits, or underscores"
        else
          builtins.filter secretReady secretIds;
    in
    {
      imports = [ ../notifications/notify/_notify-events.nix ];

      options.services.otel-collector = {
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.opentelemetry-collector-contrib;
          description = "Collector implementation package; contrib includes remote-write and log components.";
        };
        ingest = {
          address = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = "OTLP listener address (loopback for an agent, tailnet address for a gateway).";
          };
          grpcPort = lib.mkOption {
            type = lib.types.port;
            default = 4317;
            description = "OTLP gRPC listener port.";
          };
          httpPort = lib.mkOption {
            type = lib.types.port;
            default = 4318;
            description = "OTLP HTTP listener port.";
          };
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
        exporters = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options = {
                type = lib.mkOption {
                  type = lib.types.enum [
                    "otlp"
                    "otlphttp"
                    "prometheusremotewrite"
                    "debug"
                  ];
                  description = "Collector exporter type.";
                };
                endpoint = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Destination URL; required except for debug exporters.";
                };
                headers = lib.mkOption {
                  type = lib.types.attrsOf (
                    lib.types.submodule {
                      options = {
                        secret = lib.mkOption {
                          type = lib.types.str;
                          description = "ID in secretFiles and secretKeys.";
                        };
                        prefix = lib.mkOption {
                          type = lib.types.str;
                          default = "";
                          description = "Value prefix, such as Bearer followed by a space.";
                        };
                      };
                    }
                  );
                  default = { };
                  description = "Secret-backed exporter request headers.";
                };
                extra = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = { };
                  description = "Additional exporter configuration, recursively overriding generated fields.";
                };
              };
            }
          );
          default = { };
          description = "Named collector exporters.";
        };
        secretFiles = lib.mkOption {
          type = lib.types.attrsOf (lib.types.nullOr lib.types.path);
          default = { };
          description = "SOPS files by secret ID; null means unbound.";
        };
        secretKeys = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = "SOPS key paths by secret ID, paired with secretFiles.";
        };
        pipelines = lib.genAttrs [ "traces" "metrics" "logs" ] (
          signal:
          lib.mkOption {
            type = lib.types.nullOr (lib.types.listOf lib.types.str);
            default = null;
            description = "Exporter names for ${signal}; null derives compatible exporters.";
          }
        );
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
        services.notify.events.opentelemetry-collector.failure = { };
        services.opentelemetry-collector = {
          enable = true;
          inherit (cfg) package;
          settings =
            if !secretNamesMatch then
              throw "otel-collector: secretFiles and secretKeys IDs must match"
            else if !validSecretIds then
              throw "otel-collector: secret IDs must contain only letters, digits, or underscores"
            else if !validProcessors then
              throw "otel-collector: configure the resource processor through resourceAttributes, not processors.resource"
            else
              {
                receivers.otlp.protocols = {
                  grpc.endpoint = "${cfg.ingest.address}:${toString cfg.ingest.grpcPort}";
                  http.endpoint = "${cfg.ingest.address}:${toString cfg.ingest.httpPort}";
                };
                processors =
                  cfg.processors
                  // lib.optionalAttrs (cfg.resourceAttributes != { }) {
                    resource.attributes = lib.mapAttrsToList (key: value: {
                      inherit key value;
                      action = "upsert";
                    }) cfg.resourceAttributes;
                  };
                exporters = lib.foldl' lib.recursiveUpdate { } (lib.mapAttrsToList renderExporter cfg.exporters);
                service.pipelines = lib.foldl' lib.recursiveUpdate { } (
                  lib.mapAttrsToList resolvePipeline cfg.pipelines
                );
              };
          validateConfigOverrides = headers;
        };
        sops.secrets = lib.genAttrs (map secretName boundSecrets) (
          name:
          let
            id = lib.removePrefix "otel-collector/" name;
          in
          {
            sopsFile = cfg.secretFiles.${id};
            key = cfg.secretKeys.${id};
            restartUnits = [ "opentelemetry-collector.service" ];
          }
        );
        sops.templates."otel-collector.env" = lib.mkIf (boundSecrets != [ ]) {
          content =
            lib.concatMapStringsSep "\n" (
              id: "${envName id}=${config.sops.placeholder.${secretName id}}"
            ) boundSecrets
            + "\n";
          restartUnits = [ "opentelemetry-collector.service" ];
        };
        systemd.services.opentelemetry-collector.serviceConfig.EnvironmentFile = lib.optionals (
          boundSecrets != [ ]
        ) [ config.sops.templates."otel-collector.env".path ];
      };
    };
}
