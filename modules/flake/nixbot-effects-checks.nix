# The shipped effect scripts' decision paths, run against a probe consumer of
# flakeModules.nixbotEffects with niks3, nix, jj and git stubbed.
{ config, inputs, ... }:
let
  module = config.flake.flakeModules.nixbotEffects;
in
{
  perSystem =
    {
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
          nixbotEffects = {
            inherit system;
            nixPackage = pkgs.nix;
            cacheRetain = {
              enable = true;
              cacheUrl = "https://cache.example";
              writeEndpoint = "http://writer.example";
            };
            packageUpdates = {
              enable = true;
              when.dayOfWeek = [ "Mon" ];
            };
          };
          perSystem =
            { pkgs, ... }:
            {
              packages.alpha = pkgs.runCommand "alpha" { } "touch $out";
            };
        }).config.flake;
      primaryRepo = {
        owner = "owner";
        name = "probe";
        branch = "main";
        tag = null;
        remoteHttpUrl = "https://github.com/owner/probe";
      };
      ci = probe.herculesCI { inherit primaryRepo; };
      retain = ci.onPush.default.outputs.effects.cache-retain;
      update = ci.onSchedule.package-updates.outputs.effects.update;
      script =
        name: effect: pkgs.writeText name (builtins.unsafeDiscardStringContext effect.effectScript);
      root = s: builtins.unsafeDiscardStringContext (toString probe.packages.${s}.cache-root);
    in
    {
      checks.nixbot-cache-retain =
        pkgs.runCommandLocal "nixbot-cache-retain-check"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.python3
            ];
            effectScript = script "cache-retain" retain;
            x86Root = root "x86_64-linux";
            armRoot = root "aarch64-linux";
          }
          ''
            mkdir bin
            cat > bin/nix <<'SH'
            #!${pkgs.runtimeShell}
            set -euo pipefail
            printf 'verify %s\n' "$4" >> "$CALLS"
            [[ "$4" != "''${FAIL_VERIFY:-}" ]]
            SH
            cat > bin/niks3 <<'SH'
            #!${pkgs.runtimeShell}
            set -euo pipefail
            if [[ "$1" == push ]]; then
              printf 'push %s\n' "$4" >> "$CALLS"
              [[ "$4" != "''${FAIL_ROOT:-}" ]]
            else
              printf 'pin %s %s\n' "$5" "$6" >> "$CALLS"
            fi
            SH
            chmod +x bin/*
            export PATH="$PWD/bin:$PATH" CALLS="$PWD/calls"
            expect() {
              python3 -c 'import os,sys; got=open(os.environ["CALLS"]).read().split("\n")[:-1]; want=sys.argv[2:]; sys.exit(0 if got==want else f"{sys.argv[1]}: {got}")' "$@"
              : > "$CALLS"
            }
            x=$x86Root a=$armRoot

            if FAIL_ROOT=$a bash "$effectScript"; then
              echo 'cache-retain hid a failed push' >&2; exit 1
            fi
            expect 'a failed push must prevent its pin and stop the effect' \
              "push $x" "pin probe-main-x86_64-linux $x" "verify $x" "push $a"

            bash "$effectScript"
            expect 'a repair run must publish, pin and verify every root' \
              "push $x" "pin probe-main-x86_64-linux $x" "verify $x" \
              "push $a" "pin probe-main-aarch64-linux $a" "verify $a"

            if FAIL_VERIFY=$x bash "$effectScript"; then
              echo 'cache-retain hid an unsubstitutable root' >&2; exit 1
            fi
            touch "$out"
          '';

      checks.nixbot-package-updates =
        pkgs.runCommandLocal "nixbot-package-updates-check"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.jq
            ];
            effectScript = script "package-updates" update;
          }
          ''
            mkdir -p bin checkout
            cat > bin/nix <<'SH'
            #!${pkgs.runtimeShell}
            set -euo pipefail
            [[ -z "''${HERCULES_CI_SECRETS_JSON:-}" ]] || { echo 'the batch inherited the secret file' >&2; exit 7; }
            printf 'batch\n' >> "$CALLS"
            while [[ $# -gt 0 ]]; do
              case "$1" in
                --json) cp "$REPORT_SRC" "$2"; shift 2 ;;
                --markdown) : > "$2"; shift 2 ;;
                *) shift ;;
              esac
            done
            exit "''${BATCH_EXIT:-0}"
            SH
            cat > bin/jj <<'SH'
            #!${pkgs.runtimeShell}
            printf 'jj %s\n' "$*" >> "$CALLS"
            SH
            cat > bin/git <<'SH'
            #!${pkgs.runtimeShell}
            :
            SH
            chmod +x bin/*
            export PATH="$PWD/bin:$PATH" CALLS="$PWD/calls"
            export NIXBOT_EFFECT_CHECKOUT="$PWD/checkout"
            export HERCULES_CI_SECRETS_JSON="$PWD/secrets.json"
            printf '{"token":{"data":{"token":"fixture"}}}' > "$HERCULES_CI_SECRETS_JSON"
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
            touch "$out"
          '';

      checks.nixbot-update-publish =
        pkgs.runCommandLocal "nixbot-update-publish-check"
          {
            nativeBuildInputs = [ pkgs.python3 ];
            PUBLISH_SCRIPT = ../../pkgs/nixbot-update-publish/publish.py;
          }
          ''
            python3 ${../../tests/nixbot-effects/test_publish.py} -v
            touch "$out"
          '';
    };
}
