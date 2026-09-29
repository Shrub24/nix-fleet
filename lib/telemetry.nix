# Pure ingest capability projection over fleet.services endpoint facts.
lib:
let
  serviceEndpoints = import ./service-endpoints.nix lib;
  protocols = [
    "otlp-grpc"
    "otlp-http"
    "prometheus-remote-write"
    "loki-push"
  ];
  signals = [
    "traces"
    "metrics"
    "logs"
  ];
  candidates =
    fleet: serviceIds:
    lib.concatMap (
      service:
      lib.concatMap (
        endpointName:
        let
          endpoint = fleet.services.${service}.endpoints.${endpointName};
          ingest = (endpoint.telemetry or { }).ingest or null;
        in
        lib.optionals (ingest != null) [
          { inherit service endpointName ingest; }
        ]
      ) (builtins.attrNames fleet.services.${service}.endpoints)
    ) serviceIds;
  describe =
    entries: lib.concatStringsSep ", " (map (entry: "${entry.service}.${entry.endpointName}") entries);
  select =
    fleet:
    {
      signal ? null,
      protocol ? null,
      collector ? null,
    }:
    let
      checked =
        if signal != null && !(builtins.elem signal signals) then
          throw "telemetry: unknown signal '${signal}' (expected traces, metrics, or logs)"
        else if protocol != null && !(builtins.elem protocol protocols) then
          throw "telemetry: unknown protocol '${protocol}' (expected ${lib.concatStringsSep ", " protocols})"
        else if collector != null && !(builtins.hasAttr collector fleet.services) then
          throw "telemetry: unknown collector '${collector}' (services: ${lib.concatStringsSep ", " (builtins.attrNames fleet.services)})"
        else
          true;
      entries = candidates fleet (
        if collector == null then builtins.attrNames fleet.services else [ collector ]
      );
      matching = builtins.filter (
        entry:
        (signal == null || builtins.elem signal entry.ingest.signals)
        && (protocol == null || entry.ingest.protocol == protocol)
      ) entries;
    in
    assert checked;
    {
      inherit entries matching;
    };
  toTarget =
    fleet: entry:
    let
      route = serviceEndpoints.resolveEndpoint fleet {
        inherit (entry) service;
        endpoint = entry.endpointName;
        via = "tailnet";
      };
    in
    {
      inherit (route) url hostname port;
      inherit (entry) service;
      inherit (entry.ingest) protocol signals;
    };
  ingestTargets =
    fleet:
    {
      signal ? null,
      protocol ? null,
    }:
    let
      selected = select fleet { inherit signal protocol; };
    in
    map (toTarget fleet) selected.matching;
  resolveIngest =
    fleet:
    {
      signal,
      protocol ? null,
      collector ? null,
    }:
    let
      selected = select fleet { inherit signal protocol collector; };
      query =
        "signal '${signal}'"
        + lib.optionalString (protocol != null) " protocol '${protocol}'"
        + lib.optionalString (collector != null) " collector '${collector}'";
      count = builtins.length selected.matching;
    in
    if signal == null then
      throw "telemetry: resolveIngest requires a signal"
    else if count == 0 then
      throw "telemetry: no ingest endpoint for ${query} (candidates: ${describe selected.entries})"
    else if count != 1 then
      throw "telemetry: ambiguous ingest endpoints for ${query} (candidates: ${describe selected.matching})"
    else
      toTarget fleet (builtins.head selected.matching);
  otlpEnv =
    {
      endpoint,
      service,
      hostId,
      extraAttributes ? { },
    }:
    let
      inherit (endpoint) protocol;
      attributes = {
        "service.name" = service;
        "host.name" = hostId;
      }
      // extraAttributes;
    in
    if
      !(builtins.elem protocol [
        "otlp-http"
        "otlp-grpc"
      ])
    then
      throw "telemetry: otlpEnv requires an OTLP endpoint, got '${protocol}'"
    else if
      builtins.hasAttr "service.name" extraAttributes || builtins.hasAttr "host.name" extraAttributes
    then
      throw "telemetry: otlpEnv extraAttributes cannot override service.name or host.name"
    else
      {
        OTEL_EXPORTER_OTLP_ENDPOINT = endpoint.url;
        OTEL_EXPORTER_OTLP_PROTOCOL = if protocol == "otlp-http" then "http/protobuf" else "grpc";
        OTEL_SERVICE_NAME = service;
        OTEL_RESOURCE_ATTRIBUTES = lib.concatStringsSep "," (
          lib.mapAttrsToList (key: value: "${key}=${value}") attributes
        );
      };
in
{
  inherit resolveIngest ingestTargets otlpEnv;
}
