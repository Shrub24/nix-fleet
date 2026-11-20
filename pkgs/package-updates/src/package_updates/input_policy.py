"""Flake input version policy: decide how each input moves, and move tags.

A ``branch`` input refreshes its lock entry. A ``stable`` or ``unstable`` input
is pinned to a release tag: flake-edit chooses the new tag on a scratch copy of
``flake.nix``, the new reference is written to the one file in this repository
that declares the input, and ``flake.nix`` is regenerated where flake-file
renders it. A ``fixed`` input moves only on an explicit request.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from .flake_update import LOCK, FlakeUpdateError, apply

STABLE = "stable"
UNSTABLE = "unstable"
BRANCH = "branch"
FIXED = "fixed"
POLICIES = (STABLE, UNSTABLE, BRANCH, FIXED)


class PolicyError(Exception):
    """A named refusal of the registry's input policy. Nothing has run."""


@dataclass(frozen=True)
class Override:
    """An input's declared policy, as the module renders it."""

    version: str | None = None
    version_regex: str | None = None
    reason: str | None = None
    file: str | None = None


@dataclass(frozen=True)
class TagMove:
    """A tag-pinned input moved to a newer release."""

    name: str
    before: str
    after: str
    github: tuple[str, str] | None

    @property
    def compare(self) -> str | None:
        if self.github is None:
            return None
        owner, repo = self.github
        return f"https://github.com/{owner}/{repo}/compare/{self.before}...{self.after}"

    @property
    def release(self) -> str | None:
        if self.github is None:
            return None
        owner, repo = self.github
        return f"https://github.com/{owner}/{repo}/releases/tag/{self.after}"


def load_overrides(data: dict) -> dict[str, Override]:
    """Read the registry's ``inputs``, refusing invalid policy by name."""
    overrides = {}
    for name, entry in data.items():
        override = Override(
            version=entry.get("version"),
            version_regex=entry.get("versionRegex"),
            reason=entry.get("reason"),
            file=entry.get("file"),
        )
        if override.version is not None and override.version not in POLICIES:
            raise PolicyError(f"input '{name}' has unknown version policy '{override.version}'")
        if override.version == FIXED and not (override.reason or "").strip():
            raise PolicyError(f"input '{name}' is fixed without a reason")
        if override.version_regex is not None:
            try:
                groups = re.compile(override.version_regex).groups
            except re.error as error:
                raise PolicyError(f"input '{name}' has an invalid versionRegex: {error}") from error
            if groups != 1:
                raise PolicyError(f"input '{name}' versionRegex needs exactly one capture group")
        overrides[name] = override
    return overrides


def _original(lock: dict, node: str) -> dict:
    return lock["nodes"].get(node, {}).get("original", {})


def remote(original: dict) -> str | None:
    """The git remote an input's reference names, or None for other kinds."""
    kind = original.get("type")
    if kind == "github":
        return f"https://github.com/{original['owner']}/{original['repo']}"
    if kind == "git":
        return original.get("url")
    return None


def _is_tag(url: str, ref: str, runner=subprocess.run) -> bool:
    result = runner(
        ["git", "ls-remote", "--exit-code", "--tags", url, f"refs/tags/{ref}"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return True
    if result.returncode == 2:
        return False
    raise PolicyError(f"cannot list tags of {url}: {result.stderr.strip()}")


def derive(original: dict, runner=subprocess.run) -> str:
    """The policy an input's locked reference implies.

    A ``rev`` is a deliberate pin. A ref that is a version-shaped tag on its
    remote is a release pin; anything else (a branch, no ref, a tag that is not
    a version) is refreshed in place. ``nixos-25.11`` looks like a version and is
    a branch, which is why the remote is asked rather than the name read.
    """
    if original.get("rev"):
        return FIXED
    ref = original.get("ref")
    url = remote(original)
    if not ref or url is None or not any(c.isdigit() for c in ref):
        return BRANCH
    return STABLE if _is_tag(url, ref, runner) else BRANCH


def classify(
    lock: dict,
    nodes: dict[str, str],
    overrides: dict[str, Override],
    requested: list[str],
    runner=subprocess.run,
) -> dict[str, str]:
    """Return each input to move and its policy, or refuse by name.

    An explicit request moves the named inputs by their derived policy, a
    ``fixed`` override included: that is how a held input is moved once its
    upstream is fixed. A policy for an input the lock does not have is stale
    configuration and is refused rather than ignored.
    """
    stale = sorted(set(overrides) - set(nodes))
    if stale:
        raise PolicyError(f"input policy names no flake input: {', '.join(stale)}")
    if requested:
        unknown = sorted(set(requested) - set(nodes))
        if unknown:
            raise PolicyError(f"not a flake input: {', '.join(unknown)}")
        return {name: derive(_original(lock, nodes[name]), runner) for name in sorted(set(requested))}
    policies = {}
    for name in sorted(nodes):
        declared = overrides.get(name, Override()).version
        policy = declared or derive(_original(lock, nodes[name]), runner)
        if policy != FIXED:
            policies[name] = policy
    return policies


def declared_urls(flake: Path) -> dict[str, str]:
    """Each input's URL as ``flake.nix`` writes it."""
    expression = (
        "builtins.mapAttrs (_: input: if builtins.isString input then input else input.url or null) "
        f"(import {json.dumps(str(flake))}).inputs"
    )
    result = subprocess.run(
        ["nix", "eval", "--impure", "--json", "--expr", expression],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise PolicyError(f"cannot read the inputs of {flake}: {result.stderr.strip()}")
    return json.loads(result.stdout)


def _ref(url: str) -> str:
    """The ref a ``github:owner/repo/<ref>`` or ``?ref=`` URL carries."""
    match = re.search(r"[?&]ref=([^&]+)", url)
    if match:
        return match.group(1)
    return url.split("?", 1)[0].rstrip("/").split("/")[-1]


def _config(overrides: dict[str, Override], policies: dict[str, str]) -> str:
    """flake-edit's per-input selection, as TOML; JSON strings are TOML strings."""
    rows = []
    for name, policy in sorted(policies.items()):
        override = overrides.get(name, Override())
        rows.append(f"[update.inputs.{json.dumps(name)}]")
        if override.version_regex is not None:
            rows.append(f"version_regex = {json.dumps(override.version_regex)}")
        rows.append(f"prerelease = {'true' if policy == UNSTABLE else 'false'}")
    return "\n".join(rows) + "\n"


def resolve(
    root: Path,
    overrides: dict[str, Override],
    policies: dict[str, str],
) -> tuple[dict[str, str], dict[str, str]]:
    """Choose each tag input's new URL with flake-edit, on a scratch copy.

    Returns ``(moved, failed)``: input name to new URL, and to the reason no
    version was chosen. flake-edit reports an unchanged input on stdout and
    logs a failed lookup without failing, so an input with neither a status
    line nor a new URL has failed.
    """
    tagged = {name: policy for name, policy in policies.items() if policy in (STABLE, UNSTABLE)}
    if not tagged:
        return {}, {}
    executable = shutil.which("flake-edit")
    if executable is None:
        return {}, {name: "flake-edit not found on PATH" for name in tagged}
    moved, failed = {}, {}
    with tempfile.TemporaryDirectory(prefix="update-tags-") as scratch:
        flake = Path(scratch) / "flake.nix"
        shutil.copyfile(root / "flake.nix", flake)
        config = Path(scratch) / "flake-edit.toml"
        config.write_text(_config(overrides, tagged), encoding="utf-8")
        before = declared_urls(flake)
        for name in sorted(tagged):
            result = subprocess.run(
                [
                    executable,
                    "--flake",
                    str(flake),
                    "--config",
                    str(config),
                    "--no-lock",
                    "--no-cache",
                    "--non-interactive",
                    "update",
                    name,
                ],
                capture_output=True,
                text=True,
            )
            after = declared_urls(flake).get(name)
            if result.returncode == 0 and after and after != before.get(name):
                moved[name] = after
            elif result.returncode == 0 and f"{name} is already on the latest version" in result.stdout:
                continue
            else:
                reason = (result.stderr or result.stdout).strip().splitlines()
                failed[name] = reason[-1] if reason else "flake-edit chose no version"
    return moved, failed


def write_back(
    root: Path,
    name: str,
    old: str,
    new: str,
    override: Override,
    write_flake: str | None,
) -> dict[Path, str]:
    """Write a moved input's new URL where it is declared, or refuse by name.

    Returns the original contents of every file written, for the caller to
    restore if the move cannot be locked; a refusal has already restored them.
    """
    target = override.file or (None if write_flake else "flake.nix")
    if target is None:
        raise PolicyError(f"input '{name}' is not declared in a file of this repository")
    path = root / target
    flake = root / "flake.nix"
    originals = {path: path.read_text(encoding="utf-8"), flake: flake.read_text(encoding="utf-8")}
    literal = json.dumps(old)
    count = originals[path].count(literal)
    if count != 1:
        raise PolicyError(f"input '{name}': {literal} occurs {count} times in {target}, not once")
    path.write_text(originals[path].replace(literal, json.dumps(new)), encoding="utf-8")
    if write_flake is None:
        return originals
    result = subprocess.run([write_flake], cwd=root, capture_output=True, text=True)
    if result.returncode == 0 and declared_urls(flake).get(name) == new:
        return originals
    restore(originals)
    reason = result.stderr.strip() or f"the regenerated flake.nix does not declare {new}"
    raise PolicyError(f"input '{name}': write-flake did not carry the move: {reason}")


def restore(originals: dict[Path, str]) -> None:
    for path, text in originals.items():
        path.write_text(text, encoding="utf-8")


def move_tags(
    root: Path,
    overrides: dict[str, Override],
    policies: dict[str, str],
    lock: dict,
    nodes: dict[str, str],
    write_flake: str | None,
) -> tuple[list[TagMove], dict[str, str]]:
    """Move every tag input that has a newer release; return moves and failures.

    Each move is written and relocked on its own, so an input whose new release
    cannot be locked is restored without holding back the others.
    """
    if not any(policy in (STABLE, UNSTABLE) for policy in policies.values()):
        return [], {}
    old = declared_urls(root / "flake.nix")
    chosen, failed = resolve(root, overrides, policies)
    moves = []
    for name in sorted(chosen):
        lockfile = root / LOCK
        locked = lockfile.read_text(encoding="utf-8")
        try:
            originals = write_back(
                root, name, old[name], chosen[name], overrides.get(name, Override()), write_flake
            )
        except (PolicyError, OSError) as error:
            failed[name] = str(error)
            continue
        try:
            apply([name], root)
        except FlakeUpdateError as error:
            restore({**originals, lockfile: locked})
            failed[name] = f"the new release does not lock: {error}"
            continue
        original = _original(lock, nodes[name])
        github = (original["owner"], original["repo"]) if original.get("type") == "github" else None
        moves.append(TagMove(name, _ref(old[name]), _ref(chosen[name]), github))
    return moves, failed
