#!/usr/bin/env python3
"""Refresh Bifrost's transport release and its coupled Go/UI dependencies."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.request import Request, urlopen


TAG = re.compile(r"transports/v([0-9]+\.[0-9]+\.[0-9]+)")


def select_release(tags, target=None):
    releases = [tag for tag in tags if TAG.fullmatch(tag["name"])]
    if target is not None:
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", target):
            raise ValueError("recorded target must be a stable transport version")
        releases = [tag for tag in releases if tag["name"] == f"transports/v{target}"]
    if not releases:
        raise ValueError("no matching stable transport release")
    release = max(releases, key=lambda tag: tuple(map(int, TAG.fullmatch(tag["name"])[1].split("."))))
    revision = release["commit"]["sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("transport release has no valid commit SHA")
    return TAG.fullmatch(release["name"])[1], revision


def fetch_tags():
    url = "https://api.github.com/repos/maximhq/bifrost/tags?per_page=100"
    tags = []
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "nix-fleet-bifrost-update"}
    if token := os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {token}"
    while url:
        with urlopen(Request(url, headers=headers), timeout=60) as response:
            tags.extend(json.load(response))
            next_page = re.search(r'<([^>]+)>;\s*rel="next"', response.headers.get("Link", ""))
            url = next_page[1] if next_page else None
    return tags


def replace_one(text, pattern, replacement):
    result, count = re.subn(pattern, lambda _: replacement, text, flags=re.MULTILINE)
    if count != 1:
        raise ValueError(f"expected one pin matching {pattern!r}, found {count}")
    return result


def main():
    version, revision = select_release(fetch_tags(), os.environ.get("BIFROST_UPDATE_VERSION"))
    filename = Path("pkgs/bifrost/default.nix")
    text = filename.read_text()
    print(f"bifrost-update: transports/v{version} -> {revision}", flush=True)
    url = f"https://github.com/maximhq/bifrost/archive/{revision}.tar.gz"
    source_hash = subprocess.run(
        ["nix-prefetch-url", "--unpack", url], check=True, capture_output=True, text=True
    ).stdout.strip()
    source_hash = subprocess.run(
        ["nix", "hash", "convert", "--hash-algo", "sha256", "--to", "sri", source_hash],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    text = replace_one(text, r'^  version = "[^"]+";', f'  version = "{version}";')
    text = replace_one(text, r'^    rev = "[^"]+";[^\n]*', f'    rev = "{revision}"; # tag transports/v{version}')
    text = replace_one(text, r'^    hash = "[^"]+";', f'    hash = "{source_hash}";')
    filename.write_text(text)
    # Sources are build-time subtrees, not fetchers. Refresh their dependency
    # hashes without asking nix-update to discover or replace those sources.
    subprocess.run(
        ["nix-update", "--flake", "--version=skip", "--no-src", "--subpackage", "ui", "bifrost"],
        check=True,
    )


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"bifrost-update: {error}", file=sys.stderr)
        sys.exit(1)
