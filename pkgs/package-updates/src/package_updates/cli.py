"""Command-line entry point for the shared package-update batch."""

from __future__ import annotations

import argparse
import sys

from .check import check, render
from .report import ABORTED
from .runner import EXIT_CODES, UpdateError, lock_refresh, load_registry, select, update
from .transaction import TransactionError


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="update-packages",
        description="Update this repository's registered package outputs, optionally refreshing flake inputs first.",
    )
    parser.add_argument(
        "packages",
        nargs="*",
        metavar="PACKAGE",
        help="registered package outputs to update (default: all registered)",
    )
    parser.add_argument(
        "--input",
        dest="inputs",
        action="append",
        default=[],
        metavar="INPUT",
        help="refresh this flake input before the packages (repeatable; overrides deferral)",
    )
    parser.add_argument(
        "--refresh-inputs",
        action="store_true",
        help="refresh every flake input not deferred before the packages (the producer run)",
    )
    parser.add_argument(
        "--json",
        dest="json_path",
        metavar="PATH",
        help="write the structured report to PATH",
    )
    parser.add_argument(
        "--markdown",
        dest="markdown_path",
        metavar="PATH",
        help="write the pull-request body to PATH",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="only report whether newer release tags exist; no prefetch, no edits",
    )
    args = parser.parse_args(argv)
    try:
        registry = load_registry()
        names = select(registry, args.packages)
        if args.check:
            print(render(check(names, registry.system)))
            return 0
        return update(
            names,
            registry.system,
            args.json_path,
            args.markdown_path,
            write_sets=registry.write_sets,
            package_paths=registry.package_paths,
            inputs=lock_refresh(args.inputs, args.refresh_inputs),
            deferred_inputs=registry.deferred_inputs,
        )
    except (UpdateError, TransactionError, OSError) as error:
        # Nothing was proposed and nothing can be. A run that completed with
        # failures is the runner's `partial` outcome instead, and an unexpected
        # error still traces back: an uncaught exception's exit 1 must not be
        # mistaken for that outcome, which is why callers read the report.
        print(f"package-updates: {error}", file=sys.stderr)
        return EXIT_CODES[ABORTED]


if __name__ == "__main__":
    sys.exit(main())
