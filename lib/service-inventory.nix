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
}
