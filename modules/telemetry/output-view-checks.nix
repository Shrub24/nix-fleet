# Focused checks for the native telemetry output-view example
# (`examples/telemetry-output-views.nix`).
#
# Two leaves, split by cost:
#
#   * `telemetry-output-view-composition` evaluates one throwaway host — the
#     example composed with the OTLP realization — and inspects the *effective*
#     rendered receivers, processors, exporters and credentials. A native
#     pipeline override means the route declaration alone proves nothing, so
#     each view's effective pipeline is pinned to exactly the route-scoped
#     exporters its declaration materializes.
#   * `telemetry-output-view-projection` runs the pinned Collector against local
#     mock backends and asserts the projections this repository authors: the
#     lean profile strips the named content carriers while span identity
#     survives, and the Latitude bridge's precedence rule holds. It also emits
#     the span-attribute artifact the separately pinned Latitude parser probe
#     reads.
#
# The validator is published as `flake.lib.telemetryOutputViews` so a registry
# leaf elsewhere can reuse it instead of re-deriving the same wiring.
{
  lib,
  config,
  inputs,
  ...
}:
let
  example = import ../../examples/telemetry-output-views.nix { inherit lib; };

  # Guard over effective settings. Every failure names the pipeline, exporter or
  # destination that has to change, because the whole point of the recipe is
  # that the declaration no longer decides.
  compositionFailures =
    {
      settings,
      instances,
      destinations,
      views,
      route,
      resolvedRoutes,
      resolvedPipelines,
      sops,
    }:
    let
      pipelines = settings.service.pipelines;
      inherit (settings) exporters;
      processorDefs = settings.processors;

      viewNames = builtins.attrNames views;

      exportersOf = view: pipelines.${view.pipeline}.exporters or [ ];

      # `settings.exporters` is keyed `<component>/<instance id>`, and the id is
      # the fleet's own instance identity: an effective exporter resolves to the
      # destination the route declaration materialized by that identity, so the
      # guard never re-derives the key format.
      instanceOfKey =
        key:
        let
          matches = builtins.filter (instance: lib.hasSuffix "/${instance.id}" key) instances;
        in
        if builtins.length matches == 1 then builtins.head matches else null;
      destinationOfKey =
        key:
        let
          instance = instanceOfKey key;
        in
        if instance == null then null else instance.destination;

      assigned = lib.concatMap (
        name:
        map (key: {
          view = name;
          inherit key;
        }) (exportersOf views.${name})
      ) viewNames;

      assignmentsOf =
        destination:
        map (entry: entry.view) (
          builtins.filter (entry: destinationOfKey entry.key == destination) assigned
        );

      instanceDestinations = lib.unique (map (instance: instance.destination) instances);

      viewFailures =
        name:
        let
          view = views.${name};
          pipeline = pipelines.${view.pipeline} or null;
          actualProcessors = if pipeline == null then [ ] else pipeline.processors or [ ];
          actualExporters = if pipeline == null then [ ] else pipeline.exporters or [ ];
          positions = map (
            processor: lib.lists.findFirstIndex (candidate: candidate == processor) null actualProcessors
          ) view.requiredProcessors;
          indexes = builtins.filter (index: index != null) positions;
        in
        lib.optional (pipeline == null)
          "view '${name}' has no effective pipeline '${view.pipeline}'; the view is declared but nothing carries it"
        ++ lib.optionals (pipeline != null) (
          lib.optional ((pipeline.receivers or [ ]) != [ view.receiver ])
            "view '${name}' consumes ${
              builtins.toJSON (pipeline.receivers or [ ])
            } instead of the shared receiver '${view.receiver}'"
          ++ map (
            processor:
            "view '${name}' requires processor '${processor}', which its effective pipeline does not list"
          ) (builtins.filter (processor: !(builtins.elem processor actualProcessors)) view.requiredProcessors)
          ++
            lib.optional (indexes != lib.sort (a: b: a < b) indexes)
              "view '${name}' lists its processors out of the required order: ${builtins.toJSON actualProcessors}"
          ++ map (processor: "view '${name}' carries '${processor}', which belongs to another view") (
            builtins.filter (processor: builtins.elem processor view.forbiddenProcessors) actualProcessors
          )
          ++ lib.optional (builtins.elem "batch" actualProcessors) "view '${name}' batches before its durable export queue; the fleet's persistent queue is the acknowledgement boundary"
          ++ lib.optional (
            !(builtins.elem "memory_limiter" actualProcessors)
          ) "view '${name}' dropped the memory limiter the generated route pipeline carries"
          ++ map (
            processor: "view '${name}' names processor '${processor}', which the configuration never defines"
          ) (builtins.filter (processor: !(processorDefs ? ${processor})) actualProcessors)
          ++ map (
            key:
            "view '${name}' references exporter '${key}', which the route declaration never materialized; a view must reference an existing route-scoped exporter"
          ) (builtins.filter (key: !(exporters ? ${key})) actualExporters)
          ++
            map
              (
                key:
                "view '${name}' exports through '${key}', which carries destination '${toString (destinationOfKey key)}' rather than one of ${builtins.toJSON view.destinations}"
              )
              (
                builtins.filter (
                  key:
                  let
                    destination = destinationOfKey key;
                  in
                  destination == null || !(builtins.elem destination view.destinations)
                ) actualExporters
              )
          ++
            map
              (
                key:
                "view '${name}' exports through '${key}', which is not a route-scoped exporter instance of this view"
              )
              (
                builtins.filter (
                  key:
                  let
                    instance = instanceOfKey key;
                  in
                  instance == null || instance.route != view.instanceRoute
                ) actualExporters
              )
          ++
            map
              (
                destination:
                "view '${name}' declares destination '${destination}' but no exporter of its pipeline carries it"
              )
              (
                builtins.filter (
                  destination: !(builtins.elem destination (map destinationOfKey actualExporters))
                ) view.destinations
              )
          ++
            map
              (
                option:
                "view '${name}' exporter '${toString (builtins.head actualExporters)}' does not carry destination-scoped option ${option} = ${
                  builtins.toJSON view.exporterOptions.${option}
                }"
              )
              (
                builtins.filter (
                  option:
                  actualExporters == [ ]
                  || (exporters.${builtins.head actualExporters}.${option} or null) != view.exporterOptions.${option}
                ) (builtins.attrNames view.exporterOptions)
              )
        );

      # The effective exporter list has to be exactly the route-scoped
      # instances the view's declaration materializes: a dropped, duplicated or
      # foreign member leaves every mapping check above intact, so membership is
      # asserted as set equality on the rendered list.
      routeScopedExportersOf =
        view:
        lib.sort (a: b: a < b) (
          builtins.filter (
            key:
            let
              instance = instanceOfKey key;
            in
            instance != null
            && instance.route == view.instanceRoute
            && builtins.elem instance.destination view.destinations
          ) (builtins.attrNames exporters)
        );

      membershipFailures =
        name:
        let
          view = views.${name};
          pipeline = pipelines.${view.pipeline} or null;
          expected = routeScopedExportersOf view;
          actual = lib.sort (a: b: a < b) (if pipeline == null then [ ] else pipeline.exporters or [ ]);
        in
        lib.optional (pipeline != null && actual != expected)
          "view '${name}' pipeline '${view.pipeline}' exports through ${builtins.toJSON actual} instead of exactly the route-scoped members ${builtins.toJSON expected}";

      duplicated = builtins.filter (
        destination: builtins.length (assignmentsOf destination) > 1
      ) instanceDestinations;

      routeAssigned = lib.unique (
        lib.concatMap (name: map destinationOfKey (exportersOf views.${name})) (
          builtins.filter (name: views.${name}.instanceRoute == route) viewNames
        )
      );
      generalAssigned = lib.unique (
        lib.concatMap (name: map destinationOfKey (exportersOf views.${name})) (
          builtins.filter (name: views.${name}.instanceRoute == null) viewNames
        )
      );
      routeDeclared = resolvedRoutes.${route}.traces;
      generalDeclared = resolvedPipelines.traces;

      referenced = lib.unique (
        lib.concatMap (name: pipelines.${name}.exporters or [ ]) (builtins.attrNames pipelines)
      );

      credentialedKeys = builtins.filter (
        key:
        let
          destination = destinationOfKey key;
        in
        destination != null && (destinations.${destination}.headers or { }) != { }
      ) (builtins.attrNames exporters);

      exporterFailures = lib.concatMap (
        key:
        let
          exporter = exporters.${key};
          queue = exporter.sending_queue or { };
          retry = exporter.retry_on_failure or { };
        in
        lib.optional (
          (queue.enabled or false) != true
        ) "exporter '${key}' has no persistent export queue; a view must not change delivery state identity"
        ++ lib.optional (
          (queue.storage or null) != "file_storage"
        ) "exporter '${key}' does not use the shared file_storage queue"
        ++ lib.optional (
          (queue.block_on_overflow or false) != false
        ) "exporter '${key}' blocks on queue overflow instead of shedding load"
        ++ lib.optional ((retry.enabled or false) != true) "exporter '${key}' has retries disabled"
        ++ lib.optional ((retry.max_elapsed_time or null) != 0) "exporter '${key}' bounds its retry window"
        ++ lib.concatMap (
          header:
          let
            destination = destinationOfKey key;
            declared = destinations.${destination}.headers.${header};
            expected = "${declared.prefix}\${env:OTELCOL_${declared.secret}}";
            rendered = exporter.headers.${header} or null;
          in
          lib.optional (rendered != expected)
            "exporter '${key}' renders header '${header}' as ${builtins.toJSON rendered} instead of the credential reference '${expected}'"
          ++
            lib.optional (!(sops.secrets ? "otel-collector/${declared.secret}"))
              "exporter '${key}' references credential '${declared.secret}', which is not provisioned as a sops secret"
          ++
            lib.optional (!(lib.hasInfix "OTELCOL_${declared.secret}=" sops.env))
              "exporter '${key}' references credential '${declared.secret}', which the collector environment file does not carry"
        ) (builtins.attrNames (destinations.${destinationOfKey key}.headers or { }))
      ) credentialedKeys;
    in
    lib.concatMap viewFailures viewNames
    ++ lib.concatMap membershipFailures viewNames
    ++ map (
      destination:
      "destination '${destination}' is assigned to ${toString (builtins.length (assignmentsOf destination))} effective output pipelines (${lib.concatStringsSep ", " (assignmentsOf destination)}); each declared destination needs exactly one output path"
    ) duplicated
    ++ map (
      destination:
      "destination '${destination}' is materialized but no effective pipeline exports through it"
    ) (builtins.filter (destination: assignmentsOf destination == [ ]) instanceDestinations)
    ++ map (
      destination:
      "route '${route}' declares destination '${destination}' for traces but no view exports it"
    ) (builtins.filter (destination: !(builtins.elem destination routeAssigned)) routeDeclared)
    ++ map (
      destination:
      "the view composition exports destination '${destination}' on route '${route}', which the route declaration does not select"
    ) (builtins.filter (destination: !(builtins.elem destination routeDeclared)) routeAssigned)
    ++
      lib.optional (lib.sort (a: b: a < b) generalAssigned != lib.sort (a: b: a < b) generalDeclared)
        "the general pipeline no longer matches its declaration: effective ${builtins.toJSON generalAssigned} vs declared ${builtins.toJSON generalDeclared}"
    ++ map (
      key:
      "exporter '${key}' is configured but no effective pipeline uses it; a view must reference the materialized exporters rather than add its own"
    ) (builtins.filter (key: !(builtins.elem key referenced)) (builtins.attrNames exporters))
    ++ exporterFailures;
in
{
  flake.lib.telemetryOutputViews = {
    inherit (example)
      route
      defaultEndpoints
      moduleFor
      views
      ;
    inherit compositionFailures;

    # Compose the example into a throwaway host's merged configuration, so a
    # registry leaf can inspect the same effective settings:
    #
    #   evaluate { inherit system sopsModule otlpModule; }
    evaluate =
      {
        system,
        sopsModule,
        otlpModule,
        endpoints ? example.defaultEndpoints,
        extraModules ? [ ],
      }:
      (lib.nixosSystem {
        inherit system;
        modules = [
          sopsModule
          otlpModule
          (example.moduleFor { inherit endpoints; })
          { system.stateVersion = "25.11"; }
        ]
        ++ extraModules;
      }).config;
  };

  perSystem =
    { system, ... }:
    let
      pkgs = inputs.nixpkgs.legacyPackages.${system};
      sopsModule = inputs.sops-nix.nixosModules.sops;
      otlpModule = config.flake.modules.nixos.telemetry-otel-collector-otlp;
      evaluate = config.flake.lib.telemetryOutputViews.evaluate;

      # One host carries the composition assertions. The examples' endpoints are
      # synthetic; nothing here reaches a network.
      composed = evaluate { inherit system sopsModule otlpModule; };
      composedSettings = composed.services.opentelemetry-collector.settings;
      inspection = {
        settings = composedSettings;
        instances = composed.services.otel-collector.exporterInstances;
        destinations = composed.services.telemetry.destinations;
        inherit (example) views;
        inherit (example) route;
        resolvedRoutes = composed.services.telemetry.resolvedRoutePipelines;
        resolvedPipelines = composed.services.telemetry.resolvedPipelines;
        sops = {
          secrets = composed.sops.secrets;
          env = composed.sops.templates."otel-collector.env".content;
        };
      };
      failures = compositionFailures inspection;

      # Non-vacuity: the regression this recipe exists to prevent is the
      # generated pipeline keeping every declared destination, which would
      # assign the store to a second output path. The guard has to reject that
      # from the effective settings alone.
      mutantSettings = lib.recursiveUpdate composedSettings {
        service.pipelines."traces/route-${example.route}".exporters =
          composedSettings.service.pipelines."traces/route-${example.route}".exporters
          ++ composedSettings.service.pipelines.${example.views.lean.pipeline}.exporters;
      };
      mutantFailures = compositionFailures (inspection // { settings = mutantSettings; });

      # Runtime uses the same example, changing only listeners, endpoints and
      # test delivery plumbing.
      loopbackEndpoints = {
        general = "http://127.0.0.1:19061";
        store = "http://127.0.0.1:19062";
        langfuse = "http://127.0.0.1:19063";
        latitude = "http://127.0.0.1:19064";
      };
      runtimeConfigValue = evaluate {
        inherit system sopsModule otlpModule;
        endpoints = loopbackEndpoints;
        extraModules = [
          {
            services.telemetry.otlp.httpPort = lib.mkForce 14368;
            services.telemetry.otlp.grpcPort = lib.mkForce 14367;
            services.telemetry.routes.${example.route}.ingress = lib.mkForce {
              host = "127.0.0.2";
              httpPort = 14369;
              grpcPort = null;
            };
            services.opentelemetry-collector.settings = {
              extensions.file_storage = {
                directory = lib.mkForce "@STATE@/queue";
                compaction.directory = lib.mkForce "@STATE@/queue/compaction";
              };
              exporters =
                lib.mapAttrs
                  (
                    _: exporter:
                    exporter
                    // {
                      encoding = "json";
                      sending_queue = exporter.sending_queue // {
                        queue_size = 268435456;
                        batch = { };
                      };
                      retry_on_failure = exporter.retry_on_failure // {
                        initial_interval = "100ms";
                        max_interval = "200ms";
                      };
                    }
                  )
                  (evaluate {
                    inherit system sopsModule otlpModule;
                    endpoints = loopbackEndpoints;
                  }).services.opentelemetry-collector.settings.exporters;
            };
          }
        ];
      };
      runtimeSettings = runtimeConfigValue.services.opentelemetry-collector.settings;
      runtimeConfig = (pkgs.formats.yaml { }).generate "telemetry-output-views.yaml" runtimeSettings;
    in
    {
      checks = {
        telemetry-output-view-composition =
          if failures != [ ] then
            throw ("telemetry-output-views: " + lib.concatStringsSep "; " failures)
          else if mutantFailures == [ ] then
            throw "telemetry-output-views: the composition check accepted a destination assigned to two effective output pipelines; the guard is vacuous"
          else if
            builtins.length (
              builtins.filter (
                failure: lib.hasInfix "instead of exactly the route-scoped members" failure
              ) mutantFailures
            ) == 0
          then
            throw "telemetry-output-views: the duplicated-assignment mutation passed the exporter-membership assertion: ${lib.concatStringsSep "; " mutantFailures}"
          else
            pkgs.runCommand "telemetry-output-view-composition-check" { } ''
              echo "effective output views match the route declaration" > $out
            '';

        telemetry-output-view-projection =
          pkgs.runCommand "telemetry-output-view-projection-check"
            {
              nativeBuildInputs = [ pkgs.python3 ];
            }
            ''
              export OTELCOL=${pkgs.opentelemetry-collector-contrib}/bin/otelcol-contrib
              export CONFIG=$PWD/output-views.yaml
              export ROUTE_ADDR=127.0.0.2
              export ROUTE_PORT=14369
              export STORE_BACKEND_PORT=19062
              export LATITUDE_BACKEND_PORT=19064
              export LATITUDE_ATTRS_OUT=$PWD/telemetry-output-views-latitude-attributes.json
              export OTELCOL_langfuseAuth=synthetic-langfuse-auth
              export OTELCOL_latitudeApiKey=synthetic-latitude-api-key
              export OTELCOL_latitudeProject=synthetic-project
              sed "s|@STATE@|$PWD|g" ${runtimeConfig} > "$CONFIG"
              ${pkgs.opentelemetry-collector-contrib}/bin/otelcol-contrib validate --config=file:"$CONFIG"
              python3 ${../../tests/telemetry/output_views_check.py}
              # The pinned Latitude parser probe reads this artifact, so a missing
              # or empty one fails here rather than silently retiring the claim.
              test -s "$LATITUDE_ATTRS_OUT"
              python3 -c 'import json, sys; entries = json.load(open(sys.argv[1])); assert entries and entries[0].get("attributes"), "Latitude span-attribute artifact is empty"' "$LATITUDE_ATTRS_OUT"
              mkdir $out
              cp "$LATITUDE_ATTRS_OUT" $out/telemetry-output-views-latitude-attributes.json
            '';
      };
    };
}
