# Cross-fleet service endpoints

`flakeModules.fleet` publishes the typed `fleet.services.<service>.endpoints.<endpoint>`
catalog. These are **coordinates**, not exposure or deployment policy: consumers
choose a service, named endpoint, and access route explicitly. No route is
inferred, and no tailnet URL falls back to a public URL. The canonical records
live in the pure data file `lib/service-inventory.nix`, imported by
`modules/fleet/inventory.nix`. `lib.serviceEndpoints.canonicalServices` exports
that same raw attrset for flake-level policy files and scripts that need
host IDs and ports without a NixOS evaluation. Consumers can add local
services and public URLs downstream without restating canonical facts.

Each endpoint has at least one of:

- `tailnet = { host; scheme = "http"; port; basePath = "/"; }`, where `host`
  is a **canonical `fleet.hosts` ID**. `scheme` is `http` or `https`; `port`
  is 1–65535; `basePath` starts with `/` and is preserved verbatim, including
  a trailing slash if supplied. A root base path (`/`) yields the bare origin
  (`http://host:port`, no trailing slash) so callers can append paths without
  a double slash. The dial hostname comes from
  `fleet.hosts.<id>.tailscale.hostname`, never from a copied service hostname.
- `publicUrl = "https://..."`, an explicit URL. No public route is declared
  for the canonical services here (notably ntfy): ingress, auth, and public
  exposure remain consumer-owned.

```nix
let
  endpoint = inputs.nix-fleet.lib.serviceEndpoints.resolveEndpoint config.fleet {
    service = "docs-mcp";
    endpoint = "mcp";
    via = "tailnet";
  };
in {
  # endpoint = { url = "http://home-forge:6280/mcp";
  #              host = "home-forge"; hostname = "home-forge"; port = 6280; }
  # A provider can use endpoint.port directly rather than parsing a URL.
}
```

`lib.serviceEndpoints.url config.fleet { service = "..."; endpoint = "...";
via = "tailnet"; }` returns only the URL. `via = "public"` selects only an
explicit `publicUrl`; its resolved record has `host`, `hostname`, and `port`
set to null. Unknown service, endpoint, fleet host, access route, or a missing
selected route throws a named `fleet: service ...` error. An endpoint with no
route, invalid host reference, empty public URL, or non-absolute base path
fails fleet validation during `nix flake check`.

| Service         | Endpoint     | Tailnet host | Port  | Base path          |
| --------------- | ------------ | ------------ | ----- | ------------------ |
| omniroute       | api          | home-forge   | 20128 | `/`                |
| hindsight       | api          | home-forge   | 8888  | `/`                |
| docs-mcp        | mcp          | home-forge   | 6280  | `/mcp`             |
| ntfy            | api          | la-admin-1   | 2586  | `/`                |
| niks3-write     | api          | oci-melb-1   | 5751  | `/`                |
| bifrost         | embeddings   | oci-melb-1   | 7411  | `/v1`              |
| otel-collector  | otlp         | home-forge   | 4318  | `/`                |
| otel-collector  | ai-otlp      | home-forge   | 4319  | `/`                |
| victoriametrics | remote-write | home-forge   | 8428  | `/api/v1/write`    |
| victorialogs    | jsonline     | home-forge   | 9428  | `/insert/jsonline` |

The `otel-collector` endpoints are distinct audience inputs: `otlp` is the
general OTLP/HTTP ingress and `ai-otlp` is the explicitly selected AI ingress.
Resolve the latter with `lib.serviceEndpoints.url config.fleet {
  service = "otel-collector";
  endpoint = "ai-otlp";
  via = "tailnet";
}`. Backend fan-out is gateway policy; selecting either endpoint authenticates
no producer.
`docs-mcp` is the remote instance. A dotfiles-local localhost instance is
consumer-local; docs-mcp may call bifrost's cross-host embeddings endpoint.
No credentials, Tailscale enablement probes, or NixOS/system-manager
realization are part of this contract.
