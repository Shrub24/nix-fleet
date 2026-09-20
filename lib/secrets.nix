{
  lib,
}:
{
  mkSecretFileOption =
    name:
    lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to SOPS-encrypted file for ${name} secrets.";
    };

  mkSecretKeyOption =
    defaultKey:
    lib.mkOption {
      type = lib.types.str;
      default = defaultKey;
      description = "SOPS YAML key path for this secret.";
    };

  mkRequiredSecretAssertion =
    {
      enable,
      file,
      feature,
      label,
    }:
    {
      assertion = !enable || file != null;
      message = "${feature}.enable is true but ${feature}.${label} is not set.";
    };

  mkSecretsFromMap =
    sopsFile: map:
    builtins.mapAttrs (_name: spec: {
      inherit sopsFile;
      inherit (spec) key path;
      owner = spec.owner or "root";
      group = spec.group or "root";
      mode = spec.mode or "0400";
    }) map;
}
