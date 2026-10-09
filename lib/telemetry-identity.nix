# Shared host/environment identity for locally collected telemetry.
#
# Pure vocabulary plus projection helpers: the canonical host name defaults to
# the machine's configured name, the optional environment stays null until a
# consumer binds it, and the projections below render them into each signal's
# native identity field. The helpers never start a lane; selection still
# composes signal aspects.
{ lib }:
rec {
  identityModule = _: {
    options.services.telemetry.identity = {
      hostName = lib.mkOption {
        type = lib.types.str;
        description = ''
          Canonical host identity for locally collected telemetry. In NixOS
          this defaults to `networking.hostName`; a bare vocabulary evaluation
          may leave it unset until a projection is requested. Empty values fail
          closed by name.
        '';
      };
      environment = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Optional deployment environment (for example `prod`). Null (the
          default) projects no environment identity. An explicit empty value
          fails closed by name.
        '';
      };
    };
  };

  # The effective host name: an explicit binding wins, otherwise the machine's
  # configured name. Takes the resolved contract config, so the contract's
  # assertions and every realization read the same value.
  hostOf = cfg: cfg.identity.hostName;

  # Null environment projects nothing; the renderers below omit the field.
  envOf = cfg: cfg.identity.environment;

  # Canonical OTLP resource attributes for host-local input. Rendered into
  # local pipelines only — general ingress and named routes keep the
  # originating resources, including a missing host.
  localResourceAttributes =
    cfg:
    {
      "host.name" = hostOf cfg;
    }
    // lib.optionalAttrs (envOf cfg != null) { "deployment.environment.name" = envOf cfg; };

  # Scrape-target defaults for locally owned producer jobs. Explicit
  # source-level labels win: they may describe a remote target, which is an
  # intentional origin override rather than a new global identity.
  localScrapeLabels =
    cfg:
    {
      host = hostOf cfg;
    }
    // lib.optionalAttrs (envOf cfg != null) { environment = envOf cfg; };

  # Journal record identity fields. Applied as trusted record fields the parsed
  # message payload cannot overwrite.
  localJournalFields =
    cfg:
    {
      host_name = hostOf cfg;
    }
    // lib.optionalAttrs (envOf cfg != null) { environment = envOf cfg; };

  # Canonical keys a consumer's explicit resource configuration must not
  # contradict. A matching value is harmless; anything else fails by name.
  canonicalResourceKeys = [
    "host.name"
    "deployment.environment.name"
  ];

  # Entries of `attrs` whose canonical key contradicts the local identity.
  resourceConflicts =
    cfg: attrs:
    let
      canonical = localResourceAttributes cfg;
    in
    lib.filterAttrs (key: value: canonical ? ${key} && value != canonical.${key}) (
      lib.filterAttrs (key: _: builtins.elem key canonicalResourceKeys) attrs
    );

  conflictsMessage =
    conflicts:
    lib.concatStringsSep ", " (lib.mapAttrsToList (key: value: "${key}='${value}'") conflicts);

  invalidIdentityValues =
    cfg:
    lib.optional (cfg.identity.hostName == "") "hostName"
    ++ lib.optional (cfg.identity.environment != null && cfg.identity.environment == "") "environment";
}
