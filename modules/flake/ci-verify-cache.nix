# The cache verifier is this repository's own claim that the cache serves what the
# fleet built, and its shell is not exercised by evaluating the workflow. One leaf
# states one invariant: the credential boundary plus the pass/fail verdict.
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
