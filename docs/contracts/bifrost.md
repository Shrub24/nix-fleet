# Bifrost

Select `flake.modules.nixos.bifrost` to deploy the native gateway. There is no
`services.bifrost.enable`: import is deployment. Fleet owns the package, service
account, startup configuration and failure registration. The consumer owns
providers, credentials, exposure, backups and telemetry policy.

```nix
{
  imports = [ inputs.nix-fleet.modules.nixos.bifrost ];

  services.bifrost = {
    port = 8080;
    environmentFile = config.sops.templates."bifrost.environment".path;
    settings = builtins.fromJSON (builtins.readFile ./bifrost.json);
    plugins.voyage-normalizer = {
      path = "${inputs.nix-fleet.packages.${pkgs.stdenv.hostPlatform.system}.bifrost-voyage-plugin}/lib/bifrost/voyage.so";
    };
  };
}
```

Remove any `plugins` member from the imported JSON: `plugins.*` is its sole owner.
Move built-in registrations there too (omit `path` for a built-in). Each entry has
`enabled` (default `true`), `placement` (default `post_builtin`), `order` (default
`0`), and a JSON `config` object. Entries render in ascending order, with names
breaking ties. Bifrost's placement/order support depends on its runtime mode;
these fields are passed through, not a new fleet plugin scheduler.

## Configuration and secrets

`settings` is mergeable JSON-shaped configuration, not a second model of Bifrost's
provider schema. `renderedConfig` and `renderedConfigFile` expose the effective
startup document as data and a store file. The config store defaults to enabled:
Bifrost needs it for governance, CEL routing and dashboard authentication.
The default backend is SQLite at `<dataDir>/config.db`; consumers can override
`settings.config_store.type` and its `config` object for an existing store.
`source_of_truth` defaults to `"config.json"` and other values are refused. This
makes sections present in the Nix document authoritative during startup
reconciliation; omitted sections leave database rows untouched. Use explicit
empty collections when removing declaratively managed entities.

The module restores the Nix document to `<dataDir>/config.json` before every
start, with mode `0400`, and restarts the service when the rendered document
changes. This is startup authority, not a read-only management API: runtime
UI/API changes may be accepted and persist in the store until the next startup
reconciles a declared section. Do not mistake the enabled store for permission
to make the database the configuration authority. The runtime check boots with
the governance plugin and a declared CEL routing rule, verifies their routes,
and tests restart restoration.

Never put credentials in `settings` or `environment`: both enter the Nix store.
Bind `environmentFile` to a runtime file (normally a consumer-rendered SOPS
template) and use Bifrost's `env.VARIABLE` references in fields that support them.
The module does not require credentials for a credential-free deployment and
does not invent per-provider secret options. The consumer owns SOPS declarations
and secret-rotation restart wiring, because rewriting a file at the same runtime
path does not change a systemd unit or its environment.

Fresh production state uses upstream catalog feeds. An offline deployment must
bind `settings.framework.pricing.{pricing_url,model_parameters_url,mcp_library_url}`
to accessible files or feeds; package checks use local fixture feeds without
changing production defaults. Keep authentication and remote-access policy
explicit in the consumer; the module does not bootstrap an administrator account.

From Bifrost 2.2.6, the management API is locked when dashboard authentication
is not active. For initial setup, bind `BIFROST_SETUP_TOKEN` through
`environmentFile` and supply it in `X-Bifrost-Setup-Token` (or exchange it for a
setup session in the dashboard). With active dashboard authentication, use the
normal admin session instead; the setup token no longer authenticates requests.
Without either, management routes are refused, even on loopback.

Fresh 2.2.6 deployments also require inference credentials by default. Bind
caller virtual keys and provider grants explicitly; disabling
`settings.client_config.enforce_auth_on_inference` is a consumer policy choice,
not a fleet default. MCP OAuth deployments must bind
`settings.oauth2_server_config.issuer_url` before adopting 2.2.6. Review the
[pinned upstream migration notes](https://github.com/maximhq/bifrost/blob/8b4fce4f1709d66f9208d02f50552da522535f9e/transports/changelog.md)
when updating an existing deployment.

## Service and state

Defaults: `host = "127.0.0.1"`, `port = 8080`, `dataDir = "/var/lib/bifrost"`,
`logLevel = "info"`. `dataDir` is the application directory itself, not a parent
of an `app/` directory. It is created with mode `0700`, owned by the dedicated
`bifrost` account. State and provider data can be sensitive. The unit writes only
there, runs unprivileged, restarts on failure and registers `bifrost.failure` with
the notify contract. Delivery requires co-selecting the notify aspect.

There is no firewall opening, ingress proxy, backup registration or ownership
migration from old deployments. Consumers choosing an existing directory must
migrate its ownership before starting the service. Standard
`systemd.services.bifrost.*` options remain the service escape hatch.

## Native plugins

`package` defaults to the fleet package. Native `.so` files must come from that
package's `mkPlugin`, using the same Go toolchain and shared dependency graph.
Overriding only the gateway package can invalidate the plugin ABI. The shipped
Voyage normalizer strips `encoding_format = "float"`, translates `dimensions` to
`output_dimension`, and preserves an explicit native value. It does not replace
ordinary provider `extra_headers` configuration.

The package/plugin checks prove actual loading and outgoing request bodies. The
module check uses the generated startup script and command to boot a fresh
application directory with governance and CEL routing, and restart with the Nix
configuration restored. Fixture mutations verify the named source-of-truth and
plugin-ownership assertions; evaluation does not read generated files.

## Homelab migration

Replace the local native service mechanism with the fleet import. Keep its
provider JSON as `settings`, move plugin entries to `plugins.*`, and retain the
SOPS-rendered environment file. Bind the existing application directory directly
(e.g. `dataDir = "/srv/data/bifrost/app"`). Keep the consumer's host bind, canonical
port, source-scoped firewall rules and backups. Remove its account declarations,
config-render unit, lifecycle unit and duplicate notify registration. Existing
secret-rotation restarts remain consumer-owned.
