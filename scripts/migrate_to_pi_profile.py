#!/usr/bin/env python3
"""Migrate saved Neoagent profile IDs from neo to pi.

Dry run by default; close Neoagent before using --apply. Changed files are
backed up outside the workspace root before any replacements are published.
Existing Pi preferences win conflicts. The legacy default Model also becomes
the shared default when no shared selection exists.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
from typing import Any


DEFAULT_DIRECTORY = Path("~/.local/state/nvim/neoagent/workspaces").expanduser()
WORKSPACE_NAME = re.compile(r"^.+-[0-9a-f]{64}$")


class MigrationError(Exception):
    pass


@dataclass
class Change:
    path: Path
    original: bytes
    replacement: bytes
    info: os.stat_result


def require_directory(path: Path) -> None:
    if not stat.S_ISDIR(path.lstat().st_mode):
        raise MigrationError(f"Expected a directory, without symlinks: {path}")


def read_file(path: Path) -> tuple[bytes, os.stat_result]:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise MigrationError(f"Expected a regular file, without symlinks: {path}")
    return path.read_bytes(), info


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise MigrationError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_constant(value: str) -> None:
    raise MigrationError(f"Invalid JSON number: {value}")


def decode(data: bytes, path: Path) -> dict[str, Any]:
    try:
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
        )
    except (ValueError, MigrationError) as error:
        raise MigrationError(f"Invalid JSON in {path}: {error}") from error
    if not isinstance(value, dict):
        raise MigrationError(f"Expected a JSON object: {path}")
    return value


def encode(value: dict[str, Any]) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, allow_nan=False, separators=(",", ":")
    ).encode("utf-8")


def migrate_settings(value: dict[str, Any]) -> bool:
    agents = value.get("agents")
    if not isinstance(agents, dict) or "neo" not in agents:
        return False
    legacy = agents["neo"]
    current = agents.get("pi", {})
    if not isinstance(legacy, dict) or not isinstance(current, dict):
        raise MigrationError("Workspace settings for neo and pi must be objects")
    agents["pi"] = {**legacy, **current}
    del agents["neo"]
    if "default_model" not in value and "default_model" in legacy:
        value["default_model"] = legacy["default_model"]
    return True


def migrate_header(value: dict[str, Any]) -> bool:
    if value.get("type") != "session" or value.get("format") != "neoagent-session":
        raise MigrationError(
            "Expected a current-format Session; run migrate_workspaces.py first"
        )
    metadata = value.get("metadata")
    namespace = metadata.get("neoagent") if isinstance(metadata, dict) else None
    if not isinstance(namespace, dict):
        return False
    changed = False
    if namespace.get("profileId") == "neo":
        namespace["profileId"] = "pi"
        changed = True
    derivation = namespace.get("derivation")
    if isinstance(derivation, dict) and derivation.get("sourceProfileId") == "neo":
        derivation["sourceProfileId"] = "pi"
        changed = True
    return changed


def migrate_index(value: dict[str, Any]) -> bool:
    if value.get("format") != "neoagent-session-index" or not isinstance(
        value.get("sessions"), dict
    ):
        raise MigrationError("Expected a current-format Session index")
    changed = False
    for entry in value["sessions"].values():
        attributes = entry.get("attributes") if isinstance(entry, dict) else None
        if isinstance(attributes, dict) and attributes.get("profileId") == "neo":
            attributes["profileId"] = "pi"
            changed = True
    return changed


def plan(root: Path) -> list[Change]:
    require_directory(root)
    changes = []
    for workspace in sorted(root.iterdir()):
        if not WORKSPACE_NAME.fullmatch(workspace.name):
            continue
        require_directory(workspace)
        marker = workspace / "workspace.json"
        if decode(read_file(marker)[0], marker) != {"format": "neoagent-workspace"}:
            raise MigrationError(f"Unsupported workspace format: {workspace}")
        paths = [workspace / "settings.json", workspace / "session-index.json"]
        sessions = workspace / "sessions"
        if sessions.exists() or sessions.is_symlink():
            require_directory(sessions)
            paths.extend(sorted(sessions.glob("*.jsonl")))
        for path in paths:
            if not path.exists() and not path.is_symlink():
                continue
            original, info = read_file(path)
            if path.suffix == ".jsonl":
                header, newline, journal = original.partition(b"\n")
                if not newline:
                    raise MigrationError(f"Incomplete Session header: {path}")
                value = decode(header, path)
                changed = migrate_header(value)
                ending = b"\r\n" if header.endswith(b"\r") else b"\n"
                replacement = encode(value) + ending + journal if changed else original
            else:
                value = decode(original, path)
                migrate = (
                    migrate_settings if path.name == "settings.json" else migrate_index
                )
                changed = migrate(value)
                replacement = encode(value) + b"\n" if changed else original
            if changed:
                changes.append(Change(path, original, replacement, info))
    return changes


def check_source(change: Change) -> None:
    data, info = read_file(change.path)
    if data != change.original or (
        info.st_dev, info.st_ino, info.st_mtime_ns, info.st_ctime_ns
    ) != (
        change.info.st_dev, change.info.st_ino,
        change.info.st_mtime_ns, change.info.st_ctime_ns,
    ):
        raise MigrationError(f"File changed; close Neoagent and retry: {change.path}")


def write_file(
    descriptor: int, path: Path, data: bytes, info: os.stat_result
) -> None:
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)
        output.flush()
        os.chmod(path, stat.S_IMODE(info.st_mode))
        os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns))
        os.fsync(output.fileno())


def sync_directory(path: Path) -> None:
    if os.name == "nt":
        return
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def apply(changes: list[Change], root: Path, backup: Path) -> None:
    for change in changes:
        check_source(change)
    backup.mkdir(mode=0o700)
    directories = {backup, backup.parent}
    for change in changes:
        relative = change.path.relative_to(root)
        destination = backup / relative
        for parent in reversed(relative.parents):
            (backup / parent).mkdir(mode=0o700, exist_ok=True)
            directories.add(backup / parent)
        descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        write_file(descriptor, destination, change.original, change.info)
    for path in sorted(directories, key=lambda path: len(path.parts), reverse=True):
        sync_directory(path)
    for change in changes:
        check_source(change)
        descriptor, name = tempfile.mkstemp(
            prefix=".neo-profile-", dir=change.path.parent
        )
        temporary = Path(name)
        try:
            write_file(descriptor, temporary, change.replacement, change.info)
            os.replace(temporary, change.path)
            sync_directory(change.path.parent)
        finally:
            temporary.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "directory", nargs="?", type=Path, default=DEFAULT_DIRECTORY,
        help=f"workspace root (default: {DEFAULT_DIRECTORY})",
    )
    parser.add_argument(
        "--apply", action="store_true", help="back up originals and apply changes"
    )
    parser.add_argument(
        "--backup-directory", type=Path,
        help="backup location (default: <workspace-root>.neo-profile-backup)",
    )
    args = parser.parse_args(argv)
    root = Path(os.path.abspath(args.directory.expanduser()))
    backup = (
        Path(os.path.abspath(args.backup_directory.expanduser()))
        if args.backup_directory
        else root.with_name(root.name + ".neo-profile-backup")
    )
    if backup == root or root in backup.parents:
        raise MigrationError("Backup directory must be outside the workspace root")
    changes = plan(root)
    print(f"Found {len(changes)} file(s) to migrate from neo to pi.")
    for change in changes:
        print(f"  {change.path.relative_to(root)}")
    if not changes:
        return 0
    if not args.apply:
        print("Dry run only. Close Neoagent, then re-run with --apply.")
        return 0
    print(f"Backing up originals to {backup}", flush=True)
    apply(changes, root, backup)
    print("Migration complete.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (MigrationError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2) from None
