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
        prog="update-all",
        description="Update this repository's registered package outputs, optionally refreshing flake inputs first.",
    )
    parser.add_argument(
        "packages",
        nargs="*",
        metavar="PACKAGE",
        help="registered packages or commands to update (default: all registered)",
    )
    parser.add_argument(
        "--input",
        dest="inputs",
        action="append",
        default=[],
        metavar="INPUT",
        help="move this flake input before the packages (repeatable; moves a fixed input too)",
    )
    parser.add_argument(
        "--refresh-inputs",
        action="store_true",
        help="move every flake input by its version policy before the packages (the scheduled run)",
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
        names = select(registry, args.packages, args.refresh_inputs or bool(args.inputs))
        if args.check:
            packages = [name for name in names if name not in registry.commands]
            print(render(check(packages, registry.system)))
            return 0
        return update(
            names,
            registry.system,
            args.json_path,
            args.markdown_path,
            write_sets=registry.write_sets,
            package_paths=registry.package_paths,
            inputs=lock_refresh(args.inputs, args.refresh_inputs),
            input_overrides=registry.input_overrides,
            commands=registry.commands,
            write_flake=registry.write_flake,
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
