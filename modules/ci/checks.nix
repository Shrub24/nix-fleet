# The shipped effect scripts' decision paths, run against a probe consumer of
# flakeModules.ci with niks3, nix, jj and git stubbed.
{ config, inputs, ... }:
let
  module = config.flake.flakeModules.ci;
in
{
  perSystem =
    {
      lib,
      pkgs,
      system,
      ...
    }:
    let
      probe =
        (inputs.flake-parts.lib.evalFlakeModule { inherit inputs; } {
          systems = [
            "x86_64-linux"
            "aarch64-linux"
          ];
          imports = [ module ];
          ci = {
            instance = {
              inherit system;
              cacheUrl = "https://cache.example";
              writeEndpoint = "http://writer.example";
              nixbotUrl = "https://bot.example";
              appId = 1;
            };
            retention.generations = 2;
          };
          perSystem =
            { pkgs, ... }:
            {
              packages.alpha = pkgs.runCommand "alpha" { } "touch $out";
              # The batch is the runner's own contract; the effect is checked around it.
              apps.update-all.program = lib.mkForce (toString batchStub);
            };
        }).config.flake;
      repo = {
        owner = "owner";
        name = "probe";
        remoteHttpUrl = "https://github.com/owner/probe";
      };
      onPush =
        primaryRepo:
        (probe.herculesCI { primaryRepo = repo // primaryRepo; }).onPush.default.outputs.effects;
      main = onPush {
        branch = "main";
        tag = null;
      };
      tagged = onPush {
        branch = null;
        tag = "v1/2";
      };
      update =
        (probe.herculesCI {
          primaryRepo = repo // {
            branch = "main";
          };
        }).onSchedule.package-updates.outputs.effects.update;
      script =
        name: effect: pkgs.writeText name (builtins.unsafeDiscardStringContext effect.effectScript);
      root = s: builtins.unsafeDiscardStringContext (toString probe.packages.${s}.cache-root);
      batchStub = pkgs.writeShellScript "update-all" ''
        set -euo pipefail
        [[ -z "''${HERCULES_CI_SECRETS_JSON:-}" ]] || { echo 'the batch inherited the secret file' >&2; exit 7; }
        # The batch gets the read-only token, for its updaters and for nix, and never the push token.
        [[ "''${GITHUB_TOKEN:-}" == read-only && "''${NIX_CONFIG:-}" == *"access-tokens = github.com=read-only"* ]] || { echo 'the batch got no read-only token' >&2; exit 8; }
        env | grep -q push-token && { echo 'the batch saw the push token' >&2; exit 9; }
        printf 'batch\n' >> "$CALLS"
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --json) cp "$REPORT_SRC" "$2"; shift 2 ;;
            --markdown) : > "$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        exit "''${BATCH_EXIT:-0}"
      '';
      niks3Stub = pkgs.writeShellScript "niks3" ''
        set -euo pipefail
        case "$1 $2" in
          "pins list") printf '%s' "''${PINS_JSON:-[]}"; exit 0 ;;
          "pins create") printf 'pin %s %s\n' "$5" "$6" >> "$CALLS"; exit 0 ;;
        esac
        printf 'push %s\n' "$4" >> "$CALLS"
        [[ "$4" != "''${FAIL_ROOT:-}" ]]
      '';
      # Like the effect sandbox's Nix: the new CLI refuses unless the invocation enables it.
      nixStub = pkgs.writeShellScript "nix" ''
        set -euo pipefail
        [[ "$1 $2" == "--extra-experimental-features nix-command" ]] \
          || { echo "error: experimental Nix feature 'nix-command' is disabled" >&2; exit 1; }
        root=''${*: -1}
        printf 'verify %s\n' "$root" >> "$CALLS"
        [[ "$root" != "''${FAIL_VERIFY:-}" ]]
      '';
    in
    assert lib.assertMsg (
      builtins.attrNames main == [ "cache-retain" ] && builtins.attrNames tagged == [ "cache-release" ]
    ) "a branch push must retain and a tag push must release, never both";
    {
      checks.ci-retention =
        pkgs.runCommandLocal "ci-retention-check"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.jq
              pkgs.python3
            ];
            retainScript = script "cache-retain" main.cache-retain;
            releaseScript = script "cache-release" tagged.cache-release;
            x86Root = root "x86_64-linux";
            armRoot = root "aarch64-linux";
          }
          ''
            mkdir bin
            cp ${niks3Stub} bin/niks3
            cp ${nixStub} bin/nix
            export PATH="$PWD/bin:$PATH" CALLS="$PWD/calls"
            expect() {
              python3 -c 'import os,sys; got=open(os.environ["CALLS"]).read().split("\n")[:-1]; want=sys.argv[2:]; sys.exit(0 if got==want else f"{sys.argv[1]}: {got}")' "$@"
              : > "$CALLS"
            }
            x=$x86Root a=$armRoot
            p=probe-main-x86_64-linux q=probe-main-aarch64-linux

            if FAIL_ROOT=$a bash "$retainScript"; then
              echo 'cache-retain hid a failed push' >&2; exit 1
            fi
            expect 'a failed push must prevent its pin and stop the effect' \
              "push $x" "pin $p $x" "verify $x" "push $a"

            bash "$retainScript"
            expect 'a repair run must publish, pin and verify every root' \
              "push $x" "pin $p $x" "verify $x" "push $a" "pin $q $a" "verify $a"

            if FAIL_VERIFY=$x bash "$retainScript"; then
              echo 'cache-retain hid an unsubstitutable root' >&2; exit 1
            fi
            : > "$CALLS"

            PINS_JSON=$(jq -nc --arg x "$x" --arg a "$a" \
              '[{name:"'$p'",store_path:"/old"},{name:"'$p'-1",store_path:"/older"},{name:"'$q'",store_path:$a}]') \
              bash "$retainScript"
            expect 'a moved root must shift earlier generations down; an unmoved one must not' \
              "push $x" "pin $p-2 /older" "pin $p-1 /old" "pin $p $x" "verify $x" \
              "push $a" "pin $q $a" "verify $a"

            bash "$releaseScript"
            expect 'a tag must pin its roots under the release namespace' \
              "push $x" "pin probe-release-v1-2-x86_64-linux $x" "verify $x" \
              "push $a" "pin probe-release-v1-2-aarch64-linux $a" "verify $a"
            touch "$out"
          '';

      checks.ci-updates =
        pkgs.runCommandLocal "ci-updates-check"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.jq
            ];
            effectScript = script "package-updates" update;
            inherit batchStub; # the script's reference to it lost its context
          }
          ''
            mkdir -p bin checkout
            cat > bin/jj <<'SH'
            #!${pkgs.runtimeShell}
            # Like jj in the effect sandbox: with no author in the environment
            # it will not create commits or push them.
            [[ -n "''${JJ_USER:-}" && -n "''${JJ_EMAIL:-}" ]] \
              || { echo "jj: no author identity in the environment" >&2; exit 1; }
            printf 'jj %s\n' "$*" >> "$CALLS"
            # Like jj over a fresh clone: an existing remote branch stays
            # untracked, and pushing over an untracked one is refused.
            case "$1 $2" in
              "bookmark track") touch "$PWD/tracked" ;;
              "git push")
                [[ -z "''${STALE_BRANCH:-}" || -e "$PWD/tracked" ]] \
                  || { echo "Error: Non-tracking remote bookmark exists" >&2; exit 1; }
                echo pushed >> "$CALLS" ;;
            esac
            SH
            cat > bin/git <<'SH'
            #!${pkgs.runtimeShell}
            [[ "$*" != "status --porcelain" || -z "''${DIRTY:-}" ]] || echo ' M flake.lock'
            SH
            chmod +x bin/*
            export PATH="$PWD/bin:$PATH" CALLS="$PWD/calls"
            export NIXBOT_EFFECT_CHECKOUT="$PWD/checkout"
            export HERCULES_CI_SECRETS_JSON="$PWD/secrets.json"
            printf '{"token":{"data":{"token":"push-token"}},"forge":{"data":{"token":"read-only"}}}' > "$HERCULES_CI_SECRETS_JSON"
            printf '{"outcome":"aborted"}' > aborted.json
            printf '{"outcome":"complete"}' > complete.json

            if BATCH_EXIT=2 REPORT_SRC=$PWD/aborted.json bash "$effectScript" 2>/dev/null; then
              echo 'the updater published an aborted batch' >&2; exit 1
            fi

            : > "$CALLS"
            REPORT_SRC=$PWD/complete.json bash "$effectScript"
            grep -qx batch "$CALLS" || { echo 'the batch did not run' >&2; exit 1; }
            if grep -q push "$CALLS"; then
              echo 'an unchanged tree must leave the branch alone' >&2; exit 1
            fi

            # The previous proposal's branch is still open: publishing must replace it.
            : > "$CALLS"
            DIRTY=1 STALE_BRANCH=1 REPORT_SRC=$PWD/complete.json bash "$effectScript" 2>/dev/null || true
            grep -qx pushed "$CALLS" || { echo 'an existing update branch blocked the push' >&2; exit 1; }
            touch "$out"
          '';

      checks.ci-update-publish =
        pkgs.runCommandLocal "ci-update-publish-check"
          {
            nativeBuildInputs = [ pkgs.python3 ];
            PUBLISH_SCRIPT = ../../pkgs/nixbot-update-publish/publish.py;
          }
          ''
            python3 ${../../tests/ci/test_update_publish.py} -v
            touch "$out"
          '';
    };
}
