# Exercises verify-cache.yml's verdict step: pass, miss, counts, and no credential.
{
  perSystem =
    { pkgs, ... }:
    {
      checks.ci-verify-cache =
        pkgs.runCommand "ci-verify-cache-check"
          {
            nativeBuildInputs = [
              (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
            ];
          }
          ''
            python3 ${../../tests/ci/verify_cache_check.py} ${../../.github/workflows/verify-cache.yml}
            touch $out
          '';
    };
}
