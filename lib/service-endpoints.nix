# Pure service endpoint projection. Selection is explicit: a caller names the
# service, endpoint, and access route; no public or tailnet fallback is made.
lib:
let
  resolveEndpoint =
    fleet:
    {
      service,
      endpoint,
      via,
    }:
    let
      serviceRecord = fleet.services.${service} or (throw "fleet: service '${service}' does not exist");
      endpointRecord =
        serviceRecord.endpoints.${endpoint}
          or (throw "fleet: service '${service}' endpoint '${endpoint}' does not exist");
      tailnet = endpointRecord.tailnet or null;
      publicUrl = endpointRecord.publicUrl or null;
      routeName = "fleet: service '${service}' endpoint '${endpoint}'";
    in
    if via == "tailnet" then
      if tailnet == null then
        throw "${routeName} has no tailnet route"
      else
        let
          host =
            fleet.hosts.${tailnet.host}
              or (throw "${routeName} references unknown fleet host '${tailnet.host}'");
          path = tailnet.basePath or "/";
        in
        if !lib.hasPrefix "/" path then
          throw "${routeName} tailnet basePath '${path}' must start with /"
        else
          let
            origin = "${tailnet.scheme or "http"}://${host.tailscale.hostname}:${toString tailnet.port}";
          in
          {
            # A root base path yields the bare origin so consumers can append
            # paths (`\${url}/v1`) without producing a double slash; any other
            # path is preserved verbatim.
            url = if path == "/" then origin else origin + path;
            inherit (tailnet) host;
            hostname = host.tailscale.hostname;
            inherit (tailnet) port;
          }
    else if via == "public" then
      if publicUrl == null || publicUrl == "" then
        throw "${routeName} has no public route"
      else
        {
          url = publicUrl;
          host = null;
          hostname = null;
          port = null;
        }
    else
      throw "${routeName} has unknown access route '${via}' (expected tailnet or public)";
in
{
  inherit resolveEndpoint;
  canonicalServices = import ./service-inventory.nix;
  url = fleet: selection: (resolveEndpoint fleet selection).url;

  # The fleet write cache's API base URL, resolved from the canonical
  # `niks3-write` record the same way a consumer would. The build-push-cache
  # workflow defaults its `cache_api_url` input here, so the coordinate is not
  # restated in every repository; a consumer that declares its own record still
  # wins, because this reads the merged contract.
  cacheApiUrl =
    fleet:
    (resolveEndpoint fleet {
      service = "niks3-write";
      endpoint = "api";
      via = "tailnet";
    }).url;
}
