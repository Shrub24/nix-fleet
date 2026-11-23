# docs/reference/ci-options.md is rendered from the option declarations of
# flakeModules.ci: `nix run .#write-ci-reference` writes it, and the check fails
# when the committed file no longer matches.
{
  config,
  inputs,
  lib,
  ...
}:
let
  target = "docs/reference/ci-options.md";
  root = toString ../..;

  # flakeModules.ci alone, so the reference holds its options and nothing else.
  inherit
    (
      (inputs.flake-parts.lib.evalFlakeModule { inherit inputs; } {
        systems = [ ];
        imports = [ config.flake.flakeModules.ci ];
      })
    )
    options
    ;

  # Formatted as `nix fmt` formats markdown, so the committed file is both.
  reference =
    pkgs: prettier:
    let
      doc = pkgs.nixosOptionsDoc {
        options = { inherit (options) ci flake-file; };
        transformOptions =
          option:
          option
          // {
            # flake-file describes these; flakeModules.ci only adds `update` beneath them.
            visible = option.visible && option.name != "flake-file" && option.name != "flake-file.inputs";
            declarations = map (
              declaration:
              let
                file = lib.head (lib.splitString ", via option" (toString declaration));
                path = lib.removePrefix "${root}/" file;
              in
              {
                name = path;
                url = "../../${path}";
              }
            ) option.declarations;
          };
      };
    in
    pkgs.runCommand "ci-options.md" { } ''
      {
        printf '# `flakeModules.ci` options\n\n'
        printf 'Generated from the option declarations by `nix run .#write-ci-reference`; do not edit.\n\n'
        cat ${doc.optionsCommonMark}
      } > ci-options.md
      ${lib.getExe prettier} --parser markdown ci-options.md > "$out"
    '';
in
{
  perSystem =
    { config, pkgs, ... }:
    let
      rendered = reference pkgs config.treefmt.programs.prettier.package;
    in
    {
      apps.write-ci-reference = {
        type = "app";
        program = lib.getExe (
          pkgs.writeShellApplication {
            name = "write-ci-reference";
            text = ''
              root=$(git rev-parse --show-toplevel)
              mkdir -p "$root/${dirOf target}"
              install -m 644 ${rendered} "$root/${target}"
            '';
          }
        );
      };

      checks.ci-reference =
        pkgs.runCommand "ci-reference-check" { nativeBuildInputs = [ pkgs.diffutils ]; }
          ''
            diff -u ${../../${target}} ${rendered} || {
              echo "ci-reference: ${target} is stale; run nix run .#write-ci-reference" >&2
              exit 1
            }
            touch "$out"
          '';
    };
}
