# flakeModules.ci: input version policy. Every flake input follows one policy,
# derived from its locked ref unless its declaration overrides it. The override
# sits on the input's flake-file declaration, beside its URL, and is never
# rendered into flake.nix: flake-file writes only the flake reference attributes.
_:
let
  module =
    {
      config,
      lib,
      options,
      self,
      ...
    }:
    let
      policy = lib.types.submodule {
        options = {
          version = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.enum [
                "stable"
                "unstable"
                "branch"
                "fixed"
              ]
            );
            default = null;
            description = ''
              How the scheduled update moves this input. `stable` follows the
              repository's latest release, else its highest release tag of the same
              prefix; `unstable` admits pre-releases; `branch` moves the lock to the
              ref's current head; `fixed` never moves on schedule. `null` derives
              the policy from the locked ref: a tag is `stable`, a branch or no ref
              is `branch`, a `rev` is `fixed`.
            '';
          };
          versionRegex = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "v(5\\..*)";
            description = ''
              Only tags this matches are candidates, and its one capture group is the
              version compared — nix-update's `--version-regex`. Holds a release
              line, or picks one product of a repository that tags several.
            '';
          };
          reason = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Why the input is `fixed`; required for `fixed`.";
          };
        };
      };

      root = "${builtins.unsafeDiscardStringContext self.outPath}/";
      # The one file in this repository that writes the input's URL, which is
      # where a moved tag is written back.
      declaringFile =
        name:
        let
          files = lib.unique (
            map (definition: definition.file) (
              lib.filter (
                definition: lib.hasAttrByPath [ name "url" ] definition.value
              ) options.flake-file.valueMeta.configuration.options.inputs.definitionsWithLocations
            )
          );
          local = lib.filter (lib.hasPrefix root) files;
        in
        if lib.length local == 1 then lib.removePrefix root (lib.head local) else null;

      render =
        name: input:
        let
          inherit (input.update) version versionRegex reason;
        in
        lib.throwIf (version == "fixed" && (reason == null || lib.trim reason == ""))
          "ci: input ${name} is fixed without a reason"
          {
            inherit version versionRegex reason;
            file = declaringFile name;
          };
    in
    {
      key = "nix-fleet#ci.inputs";

      # flake-file declares `flake-file` as one submodule option; declaring the
      # same submodule here merges `update` into its inputs, and stands alone
      # where flake-file is not imported.
      options.flake-file = lib.mkOption {
        type = lib.types.submodule {
          options.inputs = lib.mkOption {
            type = lib.types.lazyAttrsOf (
              lib.types.submodule {
                options.update = lib.mkOption {
                  type = policy;
                  default = { };
                  description = "How the scheduled update moves this input (`flakeModules.ci`).";
                };
              }
            );
          };
        };
      };

      options.ci.updates.inputPolicies = lib.mkOption {
        type = lib.types.attrsOf lib.types.raw;
        internal = true;
        readOnly = true;
        description = "Each input's policy and declaring file, as the runner reads them.";
      };

      config = {
        # A definition rather than a default: flake-file's declaration carries
        # the default, and an option may have only one.
        flake-file.inputs = { };
        ci.updates.inputPolicies = lib.mapAttrs render config.flake-file.inputs;
      };
    };
in
{
  imports = [ module ];
  flake.modules.flake.ci = module;
}
