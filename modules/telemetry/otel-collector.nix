# OpenTelemetry Collector scrape and OTLP realizations.
{ config, ... }:
let
  mkRealization =
    realization:
    { config, lib, ... }:
    let
      telemetry = config.services.telemetry;
      cfg = config.services.otel-collector;
      otlp = realization == "otlp";
      admitted = telemetry.otlp.signals;
      bind =
        host: port:
        let
          address = if lib.hasInfix ":" host && !lib.hasPrefix "[" host then "[${host}]" else host;
        in
        "${address}:${toString port}";
      endpoint =
        port:
        let
          host = telemetry.otlp.host;
          address = if lib.hasInfix ":" host && !lib.hasPrefix "[" host then "[${host}]" else host;
        in
        if admitted == [ ] then
          throw "telemetry: local OTLP URL was read without admitting any OTLP signal"
        else if !served then
          throw "telemetry: local OTLP URL was read while admitted signals have no destination pipeline to carry them"
        else
          "http://${address}:${toString port}";
      component =
        protocol:
        {
          otlp-grpc = "otlp";
          otlp-http = "otlphttp";
          prometheus-remote-write = "prometheusremotewrite";
        }
        .${protocol};
      exporterIds =
        names: map (name: "${component telemetry.destinations.${name}.protocol}/${name}") names;
      resource = cfg.resourceAttributes != { };
      processors =
        lib.optionals (cfg.processors ? memory_limiter) [ "memory_limiter" ]
        ++ lib.optionals (resource || cfg.processors ? resource) [ "resource" ]
        ++ lib.optionals (cfg.processors ? batch) [ "batch" ]
        ++ builtins.filter (
          name:
          !(builtins.elem name [
            "memory_limiter"
            "batch"
            "resource"
          ])
        ) (builtins.attrNames cfg.processors);
      ingressProcessors =
        if resource then builtins.filter (name: name != "resource") processors else processors;
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
      ingress = telemetry.otlp.ingress;
      ingressActive = otlp && admitted != [ ] && ingress != null;
      ingressProtocols =
        lib.optionalAttrs (ingressActive && ingress.httpPort != null) {
          http.endpoint = bind ingress.host ingress.httpPort;
        }
        // lib.optionalAttrs (ingressActive && ingress.grpcPort != null) {
          grpc.endpoint = bind ingress.host ingress.grpcPort;
        };
      scrapePipeline = {
        "metrics/scrape" = {
          receivers = [ "prometheus" ];
          inherit processors;
          exporters = exporterIds telemetry.resolvedPipelines.metrics;
        };
      };
      otlpPipelines = builtins.listToAttrs (
        map (signal: {
          name = signal;
          value = {
            receivers = [ "otlp" ];
            inherit processors;
            exporters = exporterIds telemetry.resolvedPipelines.${signal};
          };
        }) admitted
      );
      ingressPipelines = builtins.listToAttrs (
        map (signal: {
          name = "${signal}/ingress";
          value = {
            receivers = [ "otlp/ingress" ];
            processors = ingressProcessors;
            exporters = exporterIds telemetry.resolvedPipelines.${signal};
          };
        }) (lib.optionals ingressActive admitted)
      );
      served = builtins.all (signal: telemetry.resolvedPipelines.${signal} != [ ]) admitted;
      selectedDestinations = lib.unique (
        lib.concatMap (signal: telemetry.resolvedPipelines.${signal}) (
          lib.optionals (otlp && served) admitted
        )
        ++ lib.optionals (realization == "scrape") telemetry.resolvedPipelines.metrics
      );
    in
    {
      key = "nix-fleet/telemetry-otel-collector-${realization}";
      imports = [
        ../../lib/telemetry-contract.nix
        ../notifications/notify/_notify-events.nix
      ];
      config = {
        services.otel-collector.exporterDestinations = lib.mkIf (
          otlp && admitted != [ ] || realization == "scrape"
        ) selectedDestinations;
        services.telemetry.scrapeRealization = lib.mkIf (realization == "scrape") "otel-collector";
        services.telemetry.otlp.httpUrl = lib.mkIf otlp (endpoint telemetry.otlp.httpPort);
        services.telemetry.otlp.grpcUrl = lib.mkIf otlp (endpoint telemetry.otlp.grpcPort);
        assertions =
          lib.optional (realization == "scrape") {
            assertion = telemetry.resolvedPipelines.metrics != [ ];
            message = "telemetry: scrape sources are registered but the metrics pipeline has no destination to carry them";
          }
          ++ lib.optionals otlp [
            {
              assertion = admitted != [ ];
              message = "telemetry: OTLP realization requires at least one admitted signal in services.telemetry.otlp.signals";
            }
            {
              assertion = admitted == [ ] || served;
              message = "telemetry: admitted OTLP signals have no destination pipeline to carry them";
            }
          ];
        services.opentelemetry-collector = {
          enable = true;
          settings = {
            receivers =
              lib.optionalAttrs (otlp && admitted != [ ]) {
                otlp.protocols = {
                  grpc.endpoint = bind telemetry.otlp.host telemetry.otlp.grpcPort;
                  http.endpoint = bind telemetry.otlp.host telemetry.otlp.httpPort;
                };
              }
              // lib.optionalAttrs ingressActive { "otlp/ingress".protocols = ingressProtocols; }
              // lib.optionalAttrs (realization == "scrape") {
                prometheus.config.scrape_configs = scrapeConfigs;
              };
            service.pipelines =
              (lib.optionalAttrs (realization == "scrape") scrapePipeline)
              // lib.optionalAttrs otlp otlpPipelines
              // ingressPipelines;
          };
        };
      };
    };
in
{
  flake.modules.nixos.telemetry-otel-collector-scrape = {
    imports = [
      config.flake.modules.nixos.telemetry
      ../../lib/telemetry-otel-collector-common.nix
      (mkRealization "scrape")
    ];
  };
  flake.modules.nixos.telemetry-otel-collector-otlp = {
    imports = [
      config.flake.modules.nixos.telemetry
      ../../lib/telemetry-otel-collector-common.nix
      (mkRealization "otlp")
    ];
  };
}
