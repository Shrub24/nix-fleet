"""Command-line entry point for the shared package-update batch."""

from __future__ import annotations

import argparse
import sys

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
    args = parser.parse_args(argv)
    try:
        registry = load_registry()
        names = select(registry, args.packages)
        return update(names, registry.system)
    except UpdateError as error:
        print(f"package-updates: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())