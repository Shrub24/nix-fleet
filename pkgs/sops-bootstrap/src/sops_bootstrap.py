#!/usr/bin/env python3
"""Create one SOPS-encrypted secret file from a template.

Template lookup: `<secrets-dir>/.templates/<rest>` where `<rest>` is the target
path relative to `<secrets-dir>`. Two forms, never both:

  <rest>      literal YAML or JSON, encrypted verbatim
  <rest>.j2   a Jinja2 template; the rendered text is the document

              settings_password: "{{ secrets.token_hex(32) }}"

Randomness comes from the stdlib CSPRNG (`secrets`), derivation from `hashlib`,
`base64`, and `uuid`; all four are Jinja globals. `random` is deliberately not
exposed and undefined names are an error, so a typo fails the render instead of
emitting nothing.

One-shot by design: the target is never overwritten without --force, the
template is never modified, and a document that still holds a `<placeholder>`
is refused. Plaintext exists only inside this process — every file written
holds ciphertext.

Operator-local: never call it from CI or a deploy path.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined

PROG = "sops-bootstrap"
TEMPLATE_DIR_NAME = ".templates"
DOCUMENT_TYPES = {".yaml": "yaml", ".yml": "yaml", ".json": "json"}
PLACEHOLDER = re.compile(r"<[a-z][a-z0-9_.:-]*>")
RECIPIENT_KEYS = {
    "age": "recipient",
    "pgp": "fp",
    "kms": "arn",
    "gcp_kms": "resource_id",
    "azure_kv": "vault_url",
    "hc_vault": "vault_address",
}


def fail(message: str, *details: str) -> int:
    print(f"{PROG}: {message}", file=sys.stderr)
    for detail in details:
        print(f"  {detail}", file=sys.stderr)
    return 1


class TemplateError(Exception):
    def __init__(self, message: str, details: list[str] | None = None) -> None:
        super().__init__(message)
        self.details = details or []


def display(path: Path) -> str:
    try:
        return str(path.relative_to(Path.cwd()))
    except ValueError:
        return str(path)


def parse_document(text: str, document_type: str) -> object:
    return json.loads(text) if document_type == "json" else yaml.safe_load(text)


def describe_recipients(text: str, document_type: str) -> list[str]:
    """Recipients from the plaintext `sops` metadata of an encrypted file.

    The metadata is not encrypted, so this needs no key — which matters, since
    a file bootstrapped for another host is one the operator cannot decrypt.
    """
    try:
        metadata = (parse_document(text, document_type) or {}).get("sops", {})
    except Exception:  # noqa: BLE001 - reporting must never mask the real work
        return []
    listed = []
    for key, field in RECIPIENT_KEYS.items():
        for entry in metadata.get(key) or []:
            listed.append(f"{key}:{entry.get(field, '?')}")
    return listed


def render_document(templates: Path, rest: str) -> tuple[str, str]:
    """Render `<templates>/<rest>` — from a `.j2` sibling, or literally."""
    literal = templates / rest
    templated = templates / f"{rest}.j2"

    if literal.is_file() and templated.is_file():
        raise TemplateError(
            f"two template forms exist for {rest}, cannot choose",
            [display(literal), display(templated)],
        )

    if templated.is_file():
        environment = Environment(
            loader=FileSystemLoader(templates),
            undefined=StrictUndefined,
            keep_trailing_newline=True,
            trim_blocks=True,
            lstrip_blocks=True,
        )
        environment.globals.update(
            secrets=secrets, hashlib=hashlib, base64=base64, uuid=uuid
        )
        try:
            return environment.get_template(f"{rest}.j2").render(), "jinja2"
        except Exception as error:  # noqa: BLE001 - surface the render failure verbatim
            raise TemplateError(f"rendering {display(templated)} failed", [str(error)]) from error

    if literal.is_file():
        return literal.read_text(encoding="utf-8"), "literal"

    raise TemplateError(
        f"no template for {rest}",
        [f"expected {display(literal)} or {display(templated)}"],
    )


def encrypt(
    document: str, document_type: str, target: str, directory: Path | None
) -> Path:
    """Encrypt to a temp file — beside the target when replacing it atomically,
    in the system temp directory when the result is thrown away (--check)."""
    handle, temporary = tempfile.mkstemp(prefix=".bootstrap.", dir=directory)
    os.close(handle)
    path = Path(temporary)
    try:
        with path.open("wb") as out:
            result = subprocess.run(
                [
                    "sops",
                    "--encrypt",
                    "--input-type",
                    document_type,
                    "--output-type",
                    document_type,
                    "--filename-override",
                    target,
                    "/dev/stdin",
                ],
                input=document.encode(),
                stdout=out,
                stderr=subprocess.PIPE,
                check=False,
            )
        if result.returncode != 0:
            sys.stderr.write(result.stderr.decode())
            raise TemplateError(
                f"sops refused to encrypt {target}",
                [f"check that a creation rule in .sops.yaml matches '{target}'"],
            )
        return path
    except BaseException:
        path.unlink(missing_ok=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(
        prog=PROG, description="Create one SOPS-encrypted secret file from its template."
    )
    parser.add_argument(
        "--secrets-dir",
        default="secrets",
        help="directory holding the encrypted files and their .templates/ (default: secrets)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="bootstrap over an existing target, discarding the values it holds",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="render and validate, report, write nothing",
    )
    parser.add_argument("target", help="path of the file to create, inside --secrets-dir")
    args = parser.parse_args()

    secrets_dir = Path(args.secrets_dir).resolve()
    target = Path(args.target).resolve()
    templates = secrets_dir / TEMPLATE_DIR_NAME

    if not templates.is_dir():
        return fail(
            f"no template directory at {display(templates)}",
            "create it, or point --secrets-dir at the tree that holds .templates/",
        )

    document_type = DOCUMENT_TYPES.get(target.suffix)
    if document_type is None:
        return fail(
            f"unsupported target extension: {target.name}",
            f"expected one of: {', '.join(sorted(DOCUMENT_TYPES))}",
        )

    try:
        rest = str(target.relative_to(secrets_dir))
    except ValueError:
        return fail(
            f"target is outside {display(secrets_dir)}: {display(target)}",
            "bootstrap writes only inside --secrets-dir (default: secrets)",
        )

    if target.exists() and not args.force:
        return fail(
            f"{display(target)} already exists — overwriting it would discard the values it holds",
            f"edit it with 'sops {display(target)}', or re-bootstrap deliberately with --force",
        )

    if not args.check:
        target.parent.mkdir(parents=True, exist_ok=True)

    try:
        document, template_kind = render_document(templates, rest)
    except TemplateError as error:
        return fail(str(error), *error.details)

    if not document.strip():
        return fail(f"template {display(templates / rest)} rendered nothing")

    outstanding = [
        f"line {number}: {match.group(0)}"
        for number, line in enumerate(document.splitlines(), start=1)
        if (match := PLACEHOLDER.search(line))
    ]
    if outstanding:
        return fail(
            f"{display(target)} still holds placeholders",
            *outstanding[:5],
            f"fill them in {display(templates / rest)} — every value must be concrete"
            " before the file is encrypted",
        )

    try:
        parsed = parse_document(document, document_type)
    except Exception as error:  # noqa: BLE001 - the parser's message is the diagnosis
        position = str(error).splitlines()
        return fail(
            f"template {display(templates / rest)} rendered invalid {document_type.upper()}",
            *position[:4],
        )

    keys = ", ".join(parsed) if isinstance(parsed, dict) else "<document>"
    replaced = (
        describe_recipients(target.read_text(encoding="utf-8"), document_type)
        if target.exists()
        else []
    )

    try:
        temporary = encrypt(
            document,
            document_type,
            display(target),
            None if args.check else target.parent,
        )
    except TemplateError as error:
        return fail(str(error), *error.details)
    except OSError as error:
        return fail(f"could not stage the encrypted file for {display(target)}", str(error))

    recipients = describe_recipients(temporary.read_text(encoding="utf-8"), document_type)

    if args.check:
        temporary.unlink(missing_ok=True)
    else:
        os.replace(temporary, target)

    verb = "check ok for" if args.check else "wrote"
    print(f"{PROG}: {verb} {display(target)}")
    chosen = templates / f"{rest}{'.j2' if template_kind == 'jinja2' else ''}"
    print(f"  template:   {display(chosen)} ({template_kind})")
    print(f"  document:   {document_type}, top-level keys: {keys}")
    print(f"  recipients: {', '.join(recipients) if recipients else 'none declared'}")
    if replaced:
        print(f"  replaced:   {', '.join(replaced)}")
    if not args.check:
        print(f"  review:     sops -d {display(target)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
