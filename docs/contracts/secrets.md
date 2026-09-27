# Secret bootstrapping

One command turns a checked-in template into one SOPS-encrypted file, so a new
secret starts from a reviewable document instead of an empty one.

```bash
sops-bootstrap [--secrets-dir DIR] [--force] [--check] secrets/services/example.yaml
```

The package is nix-fleet's (`packages.<system>.sops-bootstrap`); the template
tree, the creation rules in `.sops.yaml`, and who may read a file stay
consumer-local. It is an **operator tool**: run it by hand in a repository
checkout, never from CI or a deploy path.

## Template convention

Templates live beside the encrypted files, in `<secrets-dir>/.templates/`,
mirroring the target path:

| Target                    | Template                                        |
| ------------------------- | ----------------------------------------------- |
| `secrets/services/a.yaml` | `secrets/.templates/services/a.yaml` (literal)  |
| `secrets/services/a.yaml` | `secrets/.templates/services/a.yaml.j2` (Jinja) |

A literal template is YAML or JSON encrypted verbatim — the right form when
every value will be pasted in. A `.j2` template renders first and the rendered
text is the document. Exactly one form may exist; both is an error.

```jinja
{# degoog settings password: unlocks the UI #}
{% set password = secrets.token_hex(32) %}
settings_password: "{{ password }}"
settings_sha256: "{{ hashlib.sha256(password.encode()).hexdigest() }}"
```

Jinja globals: `secrets` (the stdlib CSPRNG — `token_hex`, `token_urlsafe`,
`token_bytes`, `choice`), `hashlib`, `base64`, `uuid`. `random` is deliberately
not exposed: it is seeded predictably, and a secret generated from it would look
fine. Undefined names are errors, so a typo fails the render instead of emitting
nothing.

Two Jinja details worth knowing before writing a template:

- Block tags (`{% %}`) absorb the following newline (`trim_blocks`). A block tag
  on a line with other content therefore joins that line to the next one — put
  `{% set %}` on its own line.
- Comments must be Jinja comments (`{# ... #}`). A YAML `#` comment line that
  contains a block tag is the same trap as above.

## What it guarantees

- **One-shot.** An existing target is refused; `--force` is the deliberate
  overwrite, and the report names the recipients it was encrypted to.
- **No placeholders ship.** A rendered document still holding `<value>`,
  `<manual>`, or `<token>` — any `<lowercase-token>` — is refused, with the line
  numbers.
- **Validated before encryption.** An invalid YAML/JSON render fails with the
  parser's position instead of sops' generic error.
- **Plaintext stays in the process.** The rendered document is piped to sops and
  written as ciphertext via a `0600` temp file in the target's directory, so the
  replacement is atomic. Nothing is printed but the document's top-level keys.
- **Recipients without a key.** `sops --filename-override` resolves the creation
  rule for a path that does not exist yet, so bootstrapping needs no private key
  and the report lists what the file is encrypted to.
- **Contained.** Targets outside `--secrets-dir` are refused, including `..` and
  absolute paths.

`--check` runs everything except the write: render, validate, encrypt in a temp
directory, report keys and recipients, write nothing.

## Consumer wiring

The just recipe is three lines and stays consumer-side, because the layout and
the recipe name are local choices:

```just
# Create one SOPS file from its template; refuses an existing target.
bootstrap target *flags:
  @sops-bootstrap {{flags}} {{target}}
```

Provide the package from this flake in the devShell (or `nix run`) instead of
carrying a copy of the script, and drop any `jinja2`/`pyyaml` from the devShell —
the package brings both.

## Migrating from an in-repo script

nix-homelab carried this as `scripts/secrets-bootstrap.py` (plus a `jinja2` entry
in its devShell). Adopting the package means deleting the script, deleting the
devShell dependency, and passing `--secrets-dir` if the tree is not `secrets/`.
The CLI is otherwise compatible: same template lookup, same one-shot refusal,
same `<placeholder>` check.
