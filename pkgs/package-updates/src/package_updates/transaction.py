"""Isolate each package updater in a disposable jj workspace."""

from __future__ import annotations

from pathlib import Path, PurePosixPath
import os
import shutil
import subprocess
import tempfile


class TransactionError(Exception):
    """A package result could not be safely staged or adopted."""


def _jj(*args: str, cwd: Path | None = None, check: bool = True) -> str:
    executable = shutil.which("jj")
    if executable is None:
        raise TransactionError("jj is required to stage package updates")
    result = subprocess.run(
        [executable, *args],
        cwd=cwd,
        capture_output=True,
        text=True,
    )
    if check and result.returncode != 0:
        raise TransactionError(result.stderr.strip() or result.stdout.strip())
    return result.stdout.strip()


def repository_root() -> Path:
    directory = Path.cwd().resolve()
    for candidate in (directory, *directory.parents):
        if (candidate / ".jj").exists():
            return candidate
    raise TransactionError("not inside a jj workspace")


def valid_write_set(paths: tuple[str, ...]) -> tuple[PurePosixPath, ...]:
    if not paths:
        raise TransactionError("write set is empty")
    normalized = []
    for value in paths:
        path = PurePosixPath(value)
        if path.is_absolute() or ".." in path.parts or value in {".", ""}:
            raise TransactionError(f"invalid repository-relative write path: {value}")
        normalized.append(path)
    return tuple(normalized)


def allowed(path: str, write_set: tuple[str | PurePosixPath, ...]) -> bool:
    candidate = PurePosixPath(path)
    roots = (PurePosixPath(value) for value in write_set)
    return any(candidate == root or root in candidate.parents for root in roots)


def _workspace_name(root: Path) -> str:
    output = _jj(
        "workspace",
        "list",
        "-T",
        'name ++ "\\t" ++ self.root() ++ "\\n"',
        cwd=root,
    )
    for line in output.splitlines():
        name, separator, path = line.partition("\t")
        if separator and Path(path).resolve() == root.resolve():
            return name
    raise TransactionError(f"cannot identify jj workspace at {root}: {output!r}")


def _diff_paths(root: Path) -> tuple[str, ...]:
    _jj("status", cwd=root)
    output = _jj("diff", "--name-only", cwd=root)
    paths = []
    for value in output.splitlines():
        path = Path(value)
        if path.is_absolute():
            try:
                value = path.relative_to(root).as_posix()
            except ValueError as error:
                raise TransactionError(f"jj reported path outside workspace: {value}") from error
        paths.append(PurePosixPath(value).as_posix())
    return tuple(paths)


def _adopt(root: Path, workspace: Path, paths: tuple[str, ...]) -> None:
    for relative in paths:
        source = workspace / relative
        destination = root / relative
        if not source.exists() and not source.is_symlink():
            destination.unlink(missing_ok=True)
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(destination.name + ".package-update-tmp")
        temporary.unlink(missing_ok=True)
        if source.is_symlink():
            temporary.symlink_to(os.readlink(source))
        elif source.is_file():
            shutil.copy2(source, temporary)
        elif source.is_dir():
            shutil.copytree(source, temporary, symlinks=True)
        elif not source.exists():
            temporary.unlink(missing_ok=True)
        if temporary.exists() or temporary.is_symlink():
            if destination.is_dir() and not destination.is_symlink():
                shutil.rmtree(destination)
            else:
                destination.unlink(missing_ok=True)
            os.replace(temporary, destination)
        else:
            destination.unlink(missing_ok=True)


def staged_package(root: Path, package: str, write_set: tuple[str, ...], execute):
    """Run one updater in an isolated jj workspace; adopt its delta on success."""
    allowed_paths = valid_write_set(write_set)
    root = root.resolve()
    workspace_name = f"package-update-{package}"
    _jj("status", cwd=root)
    with tempfile.TemporaryDirectory(prefix=f"package-update-{package}-") as temporary:
        workspace = Path(temporary) / package
        _jj("workspace", "add", "--name", workspace_name, str(workspace), cwd=root)
        try:
            destination_workspace = _workspace_name(root)
            _jj("new", f"{destination_workspace}@", cwd=workspace)
            result = execute(workspace)
            changes = _diff_paths(workspace)
            escaped = sorted(path for path in changes if not allowed(path, allowed_paths))
            if escaped:
                raise TransactionError(
                    f"writes outside declared paths: {', '.join(escaped)}"
                )
            if result.returncode == 0:
                _adopt(root, workspace, changes)
            return result, changes
        finally:
            _jj("workspace", "forget", workspace_name, cwd=root, check=False)
