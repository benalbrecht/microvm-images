#!/usr/bin/env python3
"""Apply language-ISO home-to-cache directory mappings before SSH starts."""

import json
import os
import pwd
import shutil
import stat
import sys
from pathlib import Path


class CacheMappingError(ValueError):
    """A cache mapping is unsafe or conflicts with existing guest state."""


def _parts(kind: str, value):
    if (
        not isinstance(value, str)
        or not value
        or value.startswith("/")
        or "\\" in value
        or "\0" in value
    ):
        raise CacheMappingError(f"Invalid {kind} cache path: {value!r}")
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise CacheMappingError(f"Invalid {kind} cache path: {value!r}")
    return parts


def validate_cache_map(caches):
    if not isinstance(caches, dict):
        raise CacheMappingError("cache map must be an object")
    validated = {}
    for home_path, cache_path in caches.items():
        _parts("home", home_path)
        _parts("cache", cache_path)
        validated[home_path] = cache_path
    home_paths = list(validated)
    for path in home_paths:
        if any(other.startswith(path + "/") for other in home_paths if other != path):
            raise CacheMappingError(f"Overlapping home cache paths below {path}")
    destinations = list(validated.values())
    if len(destinations) != len(set(destinations)):
        raise CacheMappingError("Cache destinations must be unique")
    return validated


def _ensure_directories(root: Path, relative: str, uid: int, gid: int):
    root = Path(root)
    try:
        root_stat = root.lstat()
    except FileNotFoundError as error:
        raise CacheMappingError(f"Required root does not exist: {root}") from error
    if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
        raise CacheMappingError(f"Required root is not a real directory: {root}")

    current = root
    for part in _parts("relative", relative):
        current = current / part
        try:
            current_stat = current.lstat()
        except FileNotFoundError:
            current.mkdir(mode=0o755)
            os.chown(current, uid, gid)
            continue
        if stat.S_ISLNK(current_stat.st_mode):
            raise CacheMappingError(f"Symlinked cache path component: {current}")
        if not stat.S_ISDIR(current_stat.st_mode):
            raise CacheMappingError(f"Cache path component is not a directory: {current}")
        os.chown(current, uid, gid)
    return current


def _validate_root(root: Path):
    try:
        root_stat = Path(root).lstat()
    except FileNotFoundError as error:
        raise CacheMappingError(f"Required root does not exist: {root}") from error
    if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
        raise CacheMappingError(f"Required root is not a real directory: {root}")


def _prepare_home_link(source: Path, destination: Path, uid: int, gid: int):
    try:
        source_stat = source.lstat()
    except FileNotFoundError:
        source.symlink_to(destination)
        os.lchown(source, uid, gid)
        return

    if stat.S_ISLNK(source_stat.st_mode):
        if source.resolve(strict=False) != destination.resolve(strict=False):
            raise CacheMappingError(f"Home cache symlink has unexpected target: {source}")
        return
    if not stat.S_ISDIR(source_stat.st_mode):
        raise CacheMappingError(f"Home cache path is not a directory: {source}")

    entries = list(source.iterdir())
    conflicts = [entry.name for entry in entries if (destination / entry.name).exists()
                 or (destination / entry.name).is_symlink()]
    if conflicts:
        raise CacheMappingError(
            f"Cache migration conflict for {source}: {', '.join(sorted(conflicts))}"
        )
    for entry in entries:
        shutil.move(str(entry), str(destination / entry.name))
    source.rmdir()
    source.symlink_to(destination)
    os.lchown(source, uid, gid)


def apply_cache_map(caches, home: Path, cache_root: Path, uid: int, gid: int):
    """Create cache destinations and safe home symlinks, preserving old data."""
    caches = validate_cache_map(caches)
    _validate_root(home)
    _validate_root(cache_root)
    for home_relative, cache_relative in sorted(caches.items()):
        destination = _ensure_directories(cache_root, cache_relative, uid, gid)
        source_parts = _parts("home", home_relative)
        source_parent = _ensure_directories(home, "/".join(source_parts[:-1]), uid, gid) \
            if len(source_parts) > 1 else Path(home)
        source = source_parent / source_parts[-1]
        _prepare_home_link(source, destination, uid, gid)


def main():
    mapping_file = Path("/opt/language/caches.json")
    if not mapping_file.is_file():
        return 0
    try:
        caches = json.loads(mapping_file.read_text())
        sandbox = pwd.getpwnam("sandbox")
        cache_root = Path("/mnt/cache")
        if caches and not os.path.ismount(cache_root):
            raise CacheMappingError("Package caches are configured but /mnt/cache is not mounted")
        apply_cache_map(caches, Path("/home/sandbox"), cache_root, sandbox.pw_uid, sandbox.pw_gid)
    except (CacheMappingError, OSError, ValueError) as error:
        print(f"orchestrator-cache-maps: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
