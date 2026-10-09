# Checked example: destination-specific payload views over one explicitly
# selected OTLP route, composed natively by the Collector.
#
# The seam:
#
#   * `services.telemetry.routes.<name>` selects a *listener* — an input
#     audience — and declares the destinations it may reach. Declaring a
#     destination there is what makes the fleet materialize its exporter: one
#     per route and destination, carrying that destination's credentials,
#     persistent queue, WAL and retry policy.
#   * Native `services.opentelemetry-collector.settings` decides what each
#     destination receives. The generated `traces/route-<name>` pipeline is the
#     unmodified rich view; sibling pipelines that consume the same route
#     receiver and reference the same route-scoped exporters add a lean
#     operational view and a backend-adapted rich view.
#   * Branch-only processors are declared in `settings.processors` and named by
#     the pipelines that use them. `services.otel-collector.processors` is not
#     the place for them: every generated pipeline, metrics included, carries
#     that list.
#
# Native overrides decide delivery, so the declaration alone proves nothing:
# `telemetry-output-view-composition` inspects the effective rendered pipelines,
# and `telemetry-output-view-isolation` runs the pinned Collector against mock
# backends to show both payloads leaving one receiver.
#
# Everything here is consumer policy: the endpoints are synthetic, the
# bindings below are placeholder paths, and no view is enabled by default.
{ lib }:
let
  route = "mixed";

  leanProcessors = [
    "transform/output-view-lean"
    "filter/output-view-lean-events"
  ];
  latitudeProcessors = [ "transform/output-view-latitude" ];

  # The lean profile's deny list: the content carriers this example removes
  # before the operational exporter queue stores them. Each entry is a known
  # carrier — Hindsight's own attributes plus the message carriers the AI
  # backends parse — not an allow list, so unknown instrumentation fields still
  # reach the store. Resource attributes, span status descriptions and any
  # field a producer renames are outside this list and need consumer review.
  leanAttributeKeys = [
    "hindsight.query"
    "hindsight.tool.arguments"
    "gen_ai.input.messages"
    "gen_ai.output.messages"
    "gen_ai.system_instructions"
    "gen_ai.tool.call.arguments"
    "gen_ai.tool.call.result"
    "gen_ai.prompt"
    "gen_ai.completion"
    "input.value"
    "output.value"
  ];
  leanAttributePatterns = [
    "^gen_ai\\.(prompt|completion)\\..*"
    "^llm\\.(input_messages|output_messages)\\..*"
  ];

  # An OTTL string literal escapes backslashes, so a regex's `\.` has to be
  # written `\\.` in the emitted statement. Escaping at the render site keeps
  # the patterns above readable as the regexes they are.
  ottl = lib.escape [ "\\" ];

  # Content-bearing span events: the GenAI inference/tool families (including
  # Hindsight's `gen_ai.client.inference.operation.details`) and the SDK's
  # `exception` event, whose message and stacktrace can echo provider payloads.
  # The span's own `error.type` attribute and status survive, so lean keeps a
  # non-content error signal.
  leanEventCondition = ''IsMatch(spanevent.name, "${ottl "^(gen_ai\\..*|exception)$"}")'';

  leanStatements =
    map (key: ''delete_key(span.attributes, "${key}")'') leanAttributeKeys
    ++ map (
      pattern: ''delete_matching_keys(span.attributes, "${ottl pattern}")''
    ) leanAttributePatterns;

  # Latitude 0.3.118 reads span attributes only. Its deprecated
  # gen_ai.prompt/completion parser accepts the exact role/content arrays that
  # Hindsight emits, including system messages. The bridge fills a legacy
  # carrier only where the span already carries neither that legacy key nor its
  # current counterpart, so existing canonical (`gen_ai.input.messages`,
  # `gen_ai.output.messages`) and producer-set legacy attributes keep
  # precedence. It is deliberately a version-scoped compatibility bridge.
  latitudeStatements = [
    ''set(span.attributes["gen_ai.prompt"], spanevent.attributes["gen_ai.input.messages"]) where spanevent.name == "gen_ai.client.inference.operation.details" and spanevent.attributes["gen_ai.input.messages"] != nil and span.attributes["gen_ai.prompt"] == nil and span.attributes["gen_ai.input.messages"] == nil''
    ''set(span.attributes["gen_ai.completion"], spanevent.attributes["gen_ai.output.messages"]) where spanevent.name == "gen_ai.client.inference.operation.details" and spanevent.attributes["gen_ai.output.messages"] != nil and span.attributes["gen_ai.completion"] == nil and span.attributes["gen_ai.output.messages"] == nil''
    ''set(span.attributes["gen_ai.system_instructions"], spanevent.attributes["gen_ai.system_instructions"]) where spanevent.name == "gen_ai.client.inference.operation.details" and spanevent.attributes["gen_ai.system_instructions"] != nil and span.attributes["gen_ai.system_instructions"] == nil''
  ];

  # Synthetic consumer-shaped endpoints. `.invalid` on purpose: this example
  # never points at a real backend, and runtime checks pass loopback ports.
  defaultEndpoints = {
    general = "https://traces.invalid/v1/traces";
    store = "https://traces.invalid/v1/traces";
    langfuse = "https://langfuse.invalid/api/public/otel";
    latitude = "https://ingest.latitude.invalid/v1/traces";
  };

  # Placeholder credentials: the retrieval value never enters this repository,
  # and the example binds a path that exists and parses as YAML. A consumer
  # binds its own SOPS file and key here.
  fixtureSecretFile = ../modules/flake/fixture-secrets.yaml;

  moduleFor =
    { endpoints }:
    { config, ... }:
    let
      collector = config.services.opentelemetry-collector.settings;
      # The generated route pipeline's processors are the base every sibling
      # view extends: the retained memory limiter plus whatever native
      # processors the consumer declared on the fleet option. Reusing the
      # rendered list keeps the views free of a volatile batch processor before
      # the durable export queue.
      richProcessors = collector.service.pipelines."traces/route-${route}".processors;
    in
    {
      services.telemetry = {
        otlp.signals = [ "traces" ];

        # The general route is a different input audience. It is declared so the
        # composition stays honest about what the views do *not* touch.
        pipelines.traces = [ "general" ];

        destinations = {
          general = {
            protocol = "otlp-http";
            endpoint = endpoints.general;
            signals = [ "traces" ];
          };
          # Lean operational store: the same received spans, without the payload
          # carriers the lean profile names.
          store = {
            protocol = "otlp-http";
            endpoint = endpoints.store;
            signals = [ "traces" ];
          };
          langfuse = {
            protocol = "otlp-http";
            endpoint = endpoints.langfuse;
            signals = [ "traces" ];
            headers.Authorization = {
              secret = "langfuseAuth";
              prefix = "Basic ";
            };
          };
          latitude = {
            protocol = "otlp-http";
            endpoint = endpoints.latitude;
            signals = [ "traces" ];
            # Organization-scoped API key plus the project the records belong
            # to. Deployment-reported for the pinned 0.3.118 image.
            headers = {
              Authorization = {
                secret = "latitudeApiKey";
                prefix = "Bearer ";
              };
              "X-Latitude-Project" = {
                secret = "latitudeProject";
                prefix = "";
              };
            };
          };
        };

        routes.${route} = {
          signals = [ "traces" ];
          # Every destination of this audience is declared here, so the route
          # owns one exporter, credential and queue per destination. The
          # pipelines below are what partition them into output views.
          pipelines.traces = [
            "store"
            "langfuse"
            "latitude"
          ];
          ingress = {
            host = "192.0.2.10";
            httpPort = 4318;
            grpcPort = null;
          };
        };

        secretFiles = {
          langfuseAuth = fixtureSecretFile;
          latitudeApiKey = fixtureSecretFile;
          latitudeProject = fixtureSecretFile;
        };
        secretKeys = {
          langfuseAuth = "fixture/langfuse-auth";
          latitudeApiKey = "fixture/latitude-api-key";
          latitudeProject = "fixture/latitude-project";
        };
      };

      # Destination-scoped exporter option: the pinned Latitude image rejects
      # gzipped OTLP protobuf, so its existing route exporter sends uncompressed.
      services.otel-collector.exporterExtra.latitude.compression = "none";

      services.opentelemetry-collector.settings = {
        processors = {
          "transform/output-view-lean" = {
            error_mode = "ignore";
            trace_statements = [
              {
                context = "span";
                statements = leanStatements;
              }
            ];
          };
          "filter/output-view-lean-events" = {
            error_mode = "ignore";
            trace_conditions = [ leanEventCondition ];
          };
          "transform/output-view-latitude" = {
            error_mode = "ignore";
            trace_statements = [
              {
                context = "spanevent";
                statements = latitudeStatements;
              }
            ];
          };
        };

        service.pipelines = {
          # The rich view stays the generated pipeline, minus the sibling
          # destinations: the later definition replaces its exporter list.
          "traces/route-${route}".exporters = lib.mkForce [
            "otlphttp/route-${route}-langfuse"
          ];

          "traces/route-${route}-lean" = {
            receivers = [ "otlp/route-${route}" ];
            processors = richProcessors ++ leanProcessors;
            exporters = [ "otlphttp/route-${route}-store" ];
          };

          "traces/route-${route}-latitude" = {
            receivers = [ "otlp/route-${route}" ];
            processors = richProcessors ++ latitudeProcessors;
            exporters = [ "otlphttp/route-${route}-latitude" ];
          };
        };
      };
    };
in
{
  inherit route defaultEndpoints moduleFor;

  # What the effective composition is expected to look like, as data: the
  # composition check compares these views against the rendered settings, and
  # against the destinations the route declaration materialized.
  views = {
    general = {
      pipeline = "traces";
      receiver = "otlp";
      instanceRoute = null;
      destinations = [ "general" ];
      exporterOptions = { };
      requiredProcessors = [ ];
      forbiddenProcessors = leanProcessors ++ latitudeProcessors;
    };
    rich = {
      pipeline = "traces/route-${route}";
      receiver = "otlp/route-${route}";
      instanceRoute = route;
      destinations = [ "langfuse" ];
      exporterOptions = { };
      requiredProcessors = [ ];
      forbiddenProcessors = leanProcessors ++ latitudeProcessors;
    };
    lean = {
      pipeline = "traces/route-${route}-lean";
      receiver = "otlp/route-${route}";
      instanceRoute = route;
      destinations = [ "store" ];
      exporterOptions = { };
      requiredProcessors = leanProcessors;
      forbiddenProcessors = latitudeProcessors;
    };
    latitude = {
      pipeline = "traces/route-${route}-latitude";
      receiver = "otlp/route-${route}";
      instanceRoute = route;
      destinations = [ "latitude" ];
      exporterOptions.compression = "none";
      requiredProcessors = latitudeProcessors;
      forbiddenProcessors = leanProcessors;
    };
  };
}
