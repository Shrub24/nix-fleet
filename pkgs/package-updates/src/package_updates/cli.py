"""Command-line entry point for the shared package-update batch."""

from __future__ import annotations

import argparse
import sys

from .check import check, render
from .runner import UpdateError, load_registry, select, update


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="update-packages",
        description="Update this repository's registered package outputs.",
    )
    parser.add_argument(
        "packages",
        nargs="*",
        metavar="PACKAGE",
        help="registered package outputs to update (default: all registered)",
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
        return update(names, registry.system, args.json_path, args.markdown_path)
    except UpdateError as error:
        print(f"package-updates: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())