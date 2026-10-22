# The evaluation gate: writable priming, verdict from stock flake check.
{
  perSystem =
    { pkgs, ... }:
    {
      checks.ci-validate-flake =
        pkgs.runCommand "ci-validate-flake-check"
          {
            nativeBuildInputs = [
              (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
              pkgs.bash
              pkgs.jq
            ];
          }
          ''
            cp -r ${../../.github} ./.github
            python3 ${../../tests/ci/validate_flake_check.py}
            touch $out
          '';
    };
}
