# Canonical cross-repository service coordinates. Pure data, usable without
# evaluating any NixOS module; host IDs join against fleet.hosts at resolution.
{
  omniroute.endpoints.api.tailnet = {
    host = "home-forge";
    port = 20128;
  };
  hindsight.endpoints.api.tailnet = {
    host = "home-forge";
    port = 8888;
  };
  docs-mcp.endpoints.mcp.tailnet = {
    host = "home-forge";
    port = 6280;
    basePath = "/mcp";
  };
  ntfy.endpoints.api.tailnet = {
    host = "la-admin-1";
    port = 2586;
  };
  niks3-write.endpoints.api.tailnet = {
    host = "oci-melb-1";
    port = 5751;
  };
  bifrost.endpoints.embeddings.tailnet = {
    host = "oci-melb-1";
    port = 7411;
    basePath = "/v1";
  };
  # The trace gateway agents forward to (OTLP/HTTP, tailnet ingress).
  otel-collector.endpoints.otlp.tailnet = {
    host = "home-forge";
    port = 4318;
  };
  otel-collector.endpoints.ai-otlp.tailnet = {
    host = "home-forge";
    port = 4319;
  };
  # Store write routes: the full ingest path is the base path, so a consumer
  # resolves one URL per lane and appends nothing.
  victoriametrics.endpoints.remote-write.tailnet = {
    host = "home-forge";
    port = 8428;
    basePath = "/api/v1/write";
  };
  victorialogs.endpoints.jsonline.tailnet = {
    host = "home-forge";
    port = 9428;
    basePath = "/insert/jsonline";
  };
}
