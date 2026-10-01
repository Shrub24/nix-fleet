# Implementation packages for the mechanisms this repository owns. Owning the
# mechanism means owning its code; consumers place it, bind policy, and never
# reach into another repository for a package.
_: {
  perSystem =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      derivedTemplate = pkgs.writeText "derived.yaml.j2" ''
        {% set password = secrets.token_hex(16) %}
        password: "{{ password }}"
        password_sha256: "{{ hashlib.sha256(password.encode()).hexdigest() }}"
      '';

      # Comments in a template must be Jinja comments: trim_blocks eats the
      # newline after a {% %} tag, so one sharing a line with content joins it
      # to the next line.
      commentedTemplate = pkgs.writeText "commented.yaml.j2" ''
        {# bootstrap marker #}
        {% set password = secrets.token_hex(16) %}
        password: "{{ password }}"
      '';

      literalTemplate = pkgs.writeText "literal.yaml" ''
        url: https://y
      '';

      # The notify daemon's Alertmanager webhook route is a wire contract: what
      # Alertmanager posts, and what one webhook group becomes. Both halves are
      # proven offline — the payload mapping directly, and the route end to end
      # through the real handler on loopback with an ntfy stub recording what
      # dispatch delivered (so the topic and severity choices are observed, not
      # re-derived from the mapping function).
      notifySrc = lib.cleanSource ../../pkgs/notify;
      notifyPython = pkgs.python3.withPackages (ps: [ ps.apprise ]);
    in
    {
      packages = {
        notify = pkgs.callPackage ../../pkgs/notify { };
        sops-bootstrap = pkgs.callPackage ../../pkgs/sops-bootstrap { };
      };

      checks.notify-alertmanager =
        pkgs.runCommand "notify-alertmanager-check"
          {
            nativeBuildInputs = [ notifyPython ];
          }
          ''
            set -euo pipefail
            export PYTHONPATH=${notifySrc}/src
            cd $TMPDIR
            ${notifyPython.interpreter} -m unittest discover -s ${notifySrc}/tests -v
            touch $out
          '';

      # sops-bootstrap drives real sops + age, both offline, so the whole flow
      # is provable here: encrypt to a generated age key, decrypt back, and
      # check every refusal path.
      checks.sops-bootstrap =
        pkgs.runCommand "sops-bootstrap-check"
          {
            nativeBuildInputs = [
              config.packages.sops-bootstrap
              pkgs.age
              pkgs.gnugrep
              pkgs.sops
            ];
          }
          ''
            set -euo pipefail
            export HOME=$TMPDIR
            export SOPS_AGE_KEY_FILE=$TMPDIR/age.key

            work=$TMPDIR/work
            mkdir -p "$work/secrets/.templates/services"
            cd "$work"

            age-keygen -o "$SOPS_AGE_KEY_FILE" 2>/dev/null
            recipient=$(sed -n 's/^# public key: //p' "$SOPS_AGE_KEY_FILE")
            cat > .sops.yaml <<EOF
            creation_rules:
              - path_regex: secrets/.*
                age: $recipient
            EOF

            # Refusals run first: each must fail with its named message and
            # leave no target behind.
            expect_refusal() {
              description=$1
              expected=$2
              shift 2
              if "$@" > $TMPDIR/last.out 2>&1; then
                echo "sops-bootstrap-check: $description was not refused"
                cat $TMPDIR/last.out
                exit 1
              fi
              grep -q "$expected" $TMPDIR/last.out || {
                echo "sops-bootstrap-check: $description refused without '$expected'"
                cat $TMPDIR/last.out
                exit 1
              }
            }

            printf 'password: "<value>"\n' > secrets/.templates/services/placeholder.yaml
            expect_refusal "a placeholder document" "still holds placeholders" \
              sops-bootstrap secrets/services/placeholder.yaml
            test ! -e secrets/services/placeholder.yaml

            printf 'url: https://x\n' > secrets/.templates/services/both.yaml
            cp ${literalTemplate} secrets/.templates/services/both.yaml.j2
            expect_refusal "two template forms" "two template forms exist" \
              sops-bootstrap secrets/services/both.yaml

            printf 'a: [1,\n' > secrets/.templates/services/broken.yaml
            expect_refusal "a document that renders invalid YAML" "invalid YAML" \
              sops-bootstrap secrets/services/broken.yaml

            expect_refusal "a target outside the secrets dir" "outside" \
              sops-bootstrap secrets/../escape.yaml
            expect_refusal "a target outside the secrets dir (absolute)" "outside" \
              sops-bootstrap $TMPDIR/elsewhere.yaml

            cp ${derivedTemplate} secrets/.templates/services/derived.yaml.j2

            # --check renders, validates and reports, and writes nothing.
            sops-bootstrap --check secrets/services/derived.yaml | grep -q 'recipients: age:'
            test ! -e secrets/services/derived.yaml

            sops-bootstrap secrets/services/derived.yaml
            sops -d secrets/services/derived.yaml > $TMPDIR/plain.yaml
            password=$(sed -n 's/^password: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' $TMPDIR/plain.yaml)
            echo "$password" | grep -Eq '^[0-9a-f]{32}$' || {
              echo "sops-bootstrap-check: password is not 16 CSPRNG bytes in hex: $password"
              exit 1
            }
            # Derivation sees the same value the document carries.
            derive=$(sed -n 's/^password_sha256: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' $TMPDIR/plain.yaml)
            expected=$(printf '%s' "$password" | sha256sum | cut -d' ' -f1)
            test "$derive" = "$expected" || {
              echo "sops-bootstrap-check: sha256 of the rendered password does not match"
              exit 1
            }

            expect_refusal "an existing target" "already exists" \
              sops-bootstrap secrets/services/derived.yaml

            # --force replaces it, and a fresh render means a new value.
            sops-bootstrap --force secrets/services/derived.yaml
            sops -d secrets/services/derived.yaml > $TMPDIR/replaced.yaml
            grep -qv "$password" $TMPDIR/replaced.yaml || {
              echo "sops-bootstrap-check: --force re-encrypted the previous value"
              exit 1
            }

            # A {# #} comment is inert: block tags inside a '#' comment line
            # absorb the next newline (trim_blocks) and would swallow a key.
            cp ${commentedTemplate} secrets/.templates/services/commented.yaml.j2
            sops-bootstrap secrets/services/commented.yaml
            sops -d secrets/services/commented.yaml > $TMPDIR/commented.yaml
            grep -q '^password:' $TMPDIR/commented.yaml || {
              echo "sops-bootstrap-check: a {# #} comment swallowed the next line"
              cat $TMPDIR/commented.yaml
              exit 1
            }

            # environ is the seam for a value that cannot be generated: the
            # template names the variable, an unset one fails the render, and an
            # exported one reaches the document.
            printf 'token: "{{ environ.BOOTSTRAP_CHECK_TOKEN }}"\n' > secrets/.templates/services/env.yaml.j2
            expect_refusal "a template naming an unset variable" "BOOTSTRAP_CHECK_TOKEN" \
              sops-bootstrap secrets/services/env.yaml
            test ! -e secrets/services/env.yaml

            BOOTSTRAP_CHECK_TOKEN=from-the-environment \
              sops-bootstrap secrets/services/env.yaml
            sops -d secrets/services/env.yaml | grep -qE 'token: "?from-the-environment"?'

            touch $out
          '';
    };
}
