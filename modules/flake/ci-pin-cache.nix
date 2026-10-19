# Exercises pin-cache.yml's pin step: one pin per system, and the credential boundary.
{
  perSystem =
    { pkgs, ... }:
    {
      checks.ci-pin-cache =
        pkgs.runCommand "ci-pin-cache-check"
          {
            nativeBuildInputs = [
              (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
            ];
          }
          ''
            python3 ${../../tests/ci/pin_cache_check.py} ${../../.github/workflows/pin-cache.yml}
            touch $out
          '';
    };
}
