#!/usr/bin/env python3
"""Migrate Neoagent master-branch workspaces to the current storage format.

The command is a dry run unless --apply is supplied. During an applied
migration, each original workspace is moved intact to a sibling backup
directory before its converted replacement is published.
"""

from __future__ import annotations

import argparse
import base64
import binascii
from dataclasses import dataclass, field
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
from typing import Any


DEFAULT_DIRECTORY = Path("~/.local/state/nvim/neoagent/workspaces").expanduser()
WORKSPACE_NAME = re.compile(r"^.+-[0-9a-f]{64}$")
OLD_SESSION_NAME = re.compile(r"^\d{8}T\d{6}_([0-9a-f]{24})\.jsonl$")
SESSION_ID = re.compile(r"^[0-9a-f]{24}$")
UTC_TIMESTAMP = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?Z$"
)
WORKSPACE_MARKER = {"format": "neoagent-workspace"}
SESSION_FORMAT = "neoagent-session"
INDEX_FORMAT = "neoagent-session-index"
OLD_WORKSPACE_FILES = {
    "input-history.jsonl",
    "input-history.jsonl.lock",
    "recordings",
    "settings.json",
    "settings.json.lock",
    "session-index.json",
    "session-index.json.lock",
    "sessions",
    "workspace.json",
}
ENTRY_FIELDS = {
    "message": {"type", "id", "parentId", "timestamp", "message", "request"},
    "compaction": {
        "type",
        "id",
        "parentId",
        "timestamp",
        "summary",
        "firstKeptEntryId",
        "tokensBefore",
        "details",
        "usage",
        "fromHook",
    },
    "leaf": {"type", "id", "parentId", "timestamp", "targetId"},
}
LEGACY_STATE_FIELDS = {
    "model_change": {"type", "id", "parentId", "timestamp", "provider", "modelId"},
    "thinking_level_change": {
        "type",
        "id",
        "parentId",
        "timestamp",
        "thinkingLevel",
    },
    "active_tools_change": {
        "type",
        "id",
        "parentId",
        "timestamp",
        "activeToolNames",
    },
}


class MigrationError(Exception):
    """An input cannot be migrated without risking data loss."""


@dataclass
class SourceSession:
    path: Path
    header: dict[str, Any]
    records: list[dict[str, Any]]
    identity: tuple[int, int, int, int]
    ignored_tail: bool = False


@dataclass
class PreservedFile:
    source: Path
    relative: Path
    identity: tuple[int, int, int, int]


@dataclass
class WorkspaceSource:
    path: Path
    sessions: list[SourceSession]
    old_index: dict[str, Any]
    settings: bytes | None
    input_history: bytes | None
    recording_directories: list[Path]
    recording_files: list[PreservedFile]
    warnings: list[str]
    index_warning: str | None = None


@dataclass
class SessionPlan:
    source: SourceSession
    filename: str
    session_id: str
    parent_session: str | None
    records: list[dict[str, Any]]


@dataclass
class WorkspacePlan:
    source: WorkspaceSource
    sessions: list[SessionPlan]
    blobs: dict[str, bytes]
    index: dict[str, Any]
    image_count: int
    warnings: list[str] = field(default_factory=list)


def fail(message: str) -> None:
    raise MigrationError(message)


def regular_file(path: Path, label: str) -> os.stat_result:
    try:
        result = path.lstat()
    except OSError as error:
        fail(f"{label}: could not inspect {path}: {error}")
    if not stat.S_ISREG(result.st_mode):
        fail(f"{label}: expected a regular file: {path}")
    return result


def path_exists(path: Path) -> bool:
    try:
        path.lstat()
        return True
    except FileNotFoundError:
        return False
    except OSError as error:
        fail(f"Could not inspect {path}: {error}")


def directory(path: Path, label: str) -> os.stat_result:
    try:
        result = path.lstat()
    except OSError as error:
        fail(f"{label}: could not inspect {path}: {error}")
    if not stat.S_ISDIR(result.st_mode):
        fail(f"{label}: expected a directory: {path}")
    return result


def reject_constant(value: str) -> None:
    fail(f"non-finite JSON number is not supported: {value}")


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def decode_utf8(data: bytes, label: str, warnings: list[str] | None = None) -> str:
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        if warnings is None:
            fail(f"{label}: invalid UTF-8: {error}")
    decoded = data.decode("utf-8", errors="surrogateescape")
    repaired: list[str] = []
    invalid_bytes = 0
    for character in decoded:
        codepoint = ord(character)
        if 0xDC80 <= codepoint <= 0xDCFF:
            repaired.append(chr(codepoint - 0xDC00))
            invalid_bytes += 1
        else:
            repaired.append(character)
    assert warnings is not None
    suffix = "" if invalid_bytes == 1 else "s"
    warnings.append(
        f"{label}: mapped {invalid_bytes} invalid UTF-8 byte{suffix} "
        "to matching Unicode code points"
    )
    return "".join(repaired)


def repair_utf8(data: bytes, label: str, warnings: list[str]) -> bytes:
    return decode_utf8(data, label, warnings).encode("utf-8")


def decode_json(data: bytes, label: str, warnings: list[str] | None = None) -> Any:
    text = decode_utf8(data, label, warnings)
    try:
        return json.loads(
            text,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_constant,
        )
    except (json.JSONDecodeError, MigrationError) as error:
        fail(f"{label}: invalid JSON: {error}")


def read_bytes(path: Path, label: str) -> bytes:
    regular_file(path, label)
    try:
        return path.read_bytes()
    except OSError as error:
        fail(f"{label}: could not read {path}: {error}")


def encode_json(value: Any) -> bytes:
    try:
        encoded = json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        )
    except (TypeError, ValueError) as error:
        fail(f"could not encode migrated JSON: {error}")
    return (encoded + "\n").encode("utf-8")


def is_nonnegative_integer(value: Any) -> bool:
    return type(value) is int and value >= 0


def safe_text(value: Any) -> bool:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 512:
        return False
    return not any(ord(character) < 32 or ord(character) == 127 for character in value)


def timestamp_ms(value: Any, label: str) -> int:
    if not isinstance(value, str):
        fail(f"{label}: timestamp must be a UTC ISO 8601 string")
    matched = UTC_TIMESTAMP.fullmatch(value)
    if not matched:
        fail(f"{label}: timestamp must be a UTC ISO 8601 string")
    year, month, day, hour, minute, second = (
        int(part) for part in matched.groups()[:6]
    )
    if year < 1970 or not 1 <= month <= 12 or hour > 23 or minute > 59 or second > 59:
        fail(f"{label}: timestamp is outside the supported UTC calendar")
    leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
    month_days = [31, 29 if leap else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    if day < 1 or day > month_days[month - 1]:
        fail(f"{label}: timestamp has an invalid calendar date")
    previous_year = year - 1
    days = (
        previous_year * 365
        + previous_year // 4
        - previous_year // 100
        + previous_year // 400
        - 719162
        + day
        - 1
        + sum(month_days[: month - 1])
    )
    fraction = matched.group(7) or ""
    millis = int((fraction + "000")[:3])
    return ((days * 24 + hour) * 60 * 60 + minute * 60 + second) * 1000 + millis


def load_session(path: Path, warnings: list[str]) -> SourceSession:
    source_stat = regular_file(path, "Session")
    try:
        data = path.read_bytes()
    except OSError as error:
        fail(f"Session: could not read {path}: {error}")
    ignored_tail = False
    if data and not data.endswith(b"\n"):
        boundary = data.rfind(b"\n")
        if boundary < 0:
            fail(f"Session has no complete JSONL record: {path}")
        data = data[: boundary + 1]
        ignored_tail = True
    records: list[dict[str, Any]] = []
    for line_number, line in enumerate(data.splitlines(), 1):
        if not line.strip():
            continue
        value = decode_json(line, f"{path}:{line_number}", warnings)
        if not isinstance(value, dict):
            fail(f"{path}:{line_number}: Session record must be an object")
        records.append(value)
    if not records:
        fail(f"Session is empty: {path}")
    header = records.pop(0)
    accepted = {
        "type",
        "version",
        "id",
        "timestamp",
        "cwd",
        "parentSession",
        "metadata",
    }
    if set(header) - accepted:
        fail(
            f"Session header has unsupported fields in {path}: {sorted(set(header) - accepted)}"
        )
    if (
        header.get("type") != "session"
        or type(header.get("version")) is not int
        or header["version"] != 3
        or not isinstance(header.get("id"), str)
        or not header["id"]
        or not isinstance(header.get("cwd"), str)
        or not header["cwd"]
    ):
        fail(f"Expected a Neoagent version 3 Session header: {path}")
    timestamp_ms(header.get("timestamp"), f"{path}:1")
    parent = header.get("parentSession")
    if parent is not None and not isinstance(parent, str):
        fail(f"Session parentSession must be a string: {path}")
    metadata = header.get("metadata")
    if metadata is not None and not isinstance(metadata, dict):
        fail(f"Session metadata must be an object: {path}")
    return SourceSession(
        path=path,
        header=header,
        records=records,
        identity=(
            source_stat.st_dev,
            source_stat.st_ino,
            source_stat.st_size,
            source_stat.st_mtime_ns,
        ),
        ignored_tail=ignored_tail,
    )


def load_old_index(
    path: Path, warnings: list[str]
) -> tuple[dict[str, Any], str | None]:
    if not path_exists(path):
        return {}, None
    data = read_bytes(path, "Session index")
    try:
        value = decode_json(data, str(path), warnings)
    except MigrationError as error:
        return (
            {},
            f"ignored the invalid version 3 Session index and rebuilt it ({error})",
        )
    if (
        not isinstance(value, dict)
        or type(value.get("version")) is not int
        or value.get("version") != 3
        or not isinstance(value.get("sessions"), dict)
    ):
        return {}, "ignored an invalid version 3 Session index and rebuilt it"
    selected: dict[str, Any] = {}
    for filename, entry in value["sessions"].items():
        if (
            isinstance(filename, str)
            and filename
            and "/" not in filename
            and "\\" not in filename
            and filename.endswith(".jsonl")
            and isinstance(entry, dict)
            and isinstance(entry.get("text"), str)
            and entry["text"]
            and (
                entry.get("parent_session") is None
                or isinstance(entry.get("parent_session"), str)
            )
            and ("attributes" not in entry or isinstance(entry["attributes"], dict))
        ):
            selected[filename] = entry
    return selected, None


def validate_input_history(path: Path, warnings: list[str]) -> bytes:
    data = repair_utf8(read_bytes(path, "Input history"), str(path), warnings)
    for line_number, line in enumerate(data.splitlines(), 1):
        if not line:
            continue
        value = decode_json(line, f"{path}:{line_number}")
        if not isinstance(value, str):
            fail(f"{path}:{line_number}: input history entry must be a string")
    return data


def inspect_preserved_tree(root: Path) -> tuple[list[Path], list[PreservedFile]]:
    directories = [Path(".")]
    files: list[PreservedFile] = []
    pending = [root]
    while pending:
        parent = pending.pop()
        try:
            entries = sorted(os.scandir(parent), key=lambda entry: entry.name)
        except OSError as error:
            fail(f"Could not inspect recording directory {parent}: {error}")
        for entry in entries:
            path = Path(entry.path)
            relative = path.relative_to(root)
            result = entry.stat(follow_symlinks=False)
            if stat.S_ISDIR(result.st_mode):
                directories.append(relative)
                pending.append(path)
            elif stat.S_ISREG(result.st_mode):
                files.append(
                    PreservedFile(
                        source=path,
                        relative=relative,
                        identity=(
                            result.st_dev,
                            result.st_ino,
                            result.st_size,
                            result.st_mtime_ns,
                        ),
                    )
                )
            else:
                fail(f"Recordings contain a non-regular filesystem entry: {path}")
    return sorted(directories), sorted(files, key=lambda item: item.relative.as_posix())


def inspect_workspace(path: Path) -> WorkspaceSource:
    directory(path, "Workspace")
    if not WORKSPACE_NAME.fullmatch(path.name):
        fail(f"Unexpected directory in the workspace root: {path}")
    try:
        names = {entry.name for entry in os.scandir(path)}
    except OSError as error:
        fail(f"Could not inspect workspace {path}: {error}")
    unsupported = sorted(names - OLD_WORKSPACE_FILES)
    if unsupported:
        fail(f"Unsupported files in master-format workspace {path}: {unsupported}")
    for name in (
        "input-history.jsonl.lock",
        "settings.json.lock",
        "session-index.json.lock",
    ):
        lock = path / name
        if path_exists(lock):
            regular_file(lock, "Workspace lock")
    warnings: list[str] = []
    settings_path = path / "settings.json"
    settings = None
    if path_exists(settings_path):
        settings = repair_utf8(
            read_bytes(settings_path, "Workspace settings"),
            str(settings_path),
            warnings,
        )
        value = decode_json(settings, str(settings_path))
        if not isinstance(value, dict):
            fail(f"Workspace settings must be an object: {settings_path}")
    input_history_path = path / "input-history.jsonl"
    input_history = (
        validate_input_history(input_history_path, warnings)
        if path_exists(input_history_path)
        else None
    )
    recordings_path = path / "recordings"
    recording_directories: list[Path] = []
    recording_files: list[PreservedFile] = []
    if path_exists(recordings_path):
        directory(recordings_path, "Recording directory")
        recording_directories, recording_files = inspect_preserved_tree(recordings_path)
    sessions_directory = path / "sessions"
    sessions: list[SourceSession] = []
    if path_exists(sessions_directory):
        directory(sessions_directory, "Session directory")
        try:
            entries = sorted(
                os.scandir(sessions_directory), key=lambda entry: entry.name
            )
        except OSError as error:
            fail(f"Could not inspect Session directory {sessions_directory}: {error}")
        for entry in entries:
            child = Path(entry.path)
            if entry.name.endswith(".jsonl.lock"):
                regular_file(child, "Session lock")
                continue
            if not entry.name.endswith(".jsonl"):
                fail(f"Unexpected file in Session directory: {child}")
            sessions.append(load_session(child, warnings))
    old_index, index_warning = load_old_index(path / "session-index.json", warnings)
    return WorkspaceSource(
        path=path,
        sessions=sessions,
        old_index=old_index,
        settings=settings,
        input_history=input_history,
        recording_directories=recording_directories,
        recording_files=recording_files,
        warnings=warnings,
        index_warning=index_warning,
    )


def inspect_root(root: Path) -> tuple[list[WorkspaceSource], list[Path]]:
    directory(root, "Workspace root")
    sources: list[WorkspaceSource] = []
    current: list[Path] = []
    try:
        entries = sorted(os.scandir(root), key=lambda entry: entry.name)
    except OSError as error:
        fail(f"Could not inspect workspace root {root}: {error}")
    for entry in entries:
        path = Path(entry.path)
        if not entry.is_dir(follow_symlinks=False):
            fail(f"Unexpected non-directory in workspace root: {path}")
        marker = path / "workspace.json"
        marker_warnings: list[str] = []
        if path_exists(marker):
            value = decode_json(
                read_bytes(marker, "Workspace marker"), str(marker), marker_warnings
            )
            if value == WORKSPACE_MARKER:
                current.append(path)
                continue
            if not (
                isinstance(value, dict)
                and set(value) == {"version", "root"}
                and type(value["version"]) is int
                and value["version"] == 1
                and isinstance(value["root"], str)
                and value["root"]
            ):
                fail(f"Unsupported workspace marker: {marker}")
        source = inspect_workspace(path)
        source.warnings[0:0] = marker_warnings
        sources.append(source)
    return sources, current


def parent_session_id(
    value: str | None, session_paths: dict[str, str]
) -> tuple[str | None, bool]:
    if value is None:
        return None, False
    expanded = os.path.abspath(os.path.expanduser(value))
    if expanded in session_paths:
        return session_paths[expanded], False
    basename = os.path.basename(value)
    matched = OLD_SESSION_NAME.fullmatch(basename)
    if matched:
        return matched.group(1), False
    if SESSION_ID.fullmatch(value):
        return value, False
    return value, True


def decode_image(block: dict[str, Any], label: str) -> tuple[dict[str, Any], bytes]:
    accepted = {"type", "data", "mimeType", "id", "revision"}
    if set(block) - accepted:
        fail(f"{label}: image has unsupported fields: {sorted(set(block) - accepted)}")
    data = block.get("data")
    mime_type = block.get("mimeType")
    if not isinstance(data, str) or not data:
        fail(f"{label}: image data must be non-empty base64 text")
    if not isinstance(mime_type, str) or not mime_type:
        fail(f"{label}: image mimeType is required")
    if not re.fullmatch(r"image/[^/\s]+", mime_type, re.IGNORECASE):
        fail(f"{label}: image mimeType must be an image media type")
    padding = "=" * ((-len(data)) % 4)
    try:
        decoded = base64.b64decode(data + padding, validate=True)
    except (ValueError, binascii.Error) as error:
        fail(f"{label}: image data is not valid base64: {error}")
    if not decoded:
        fail(f"{label}: image data decodes to an empty attachment")
    digest = hashlib.sha256(decoded).hexdigest()
    return {
        "type": "image",
        "file_id": digest,
        "mime_type": mime_type.lower(),
        "bytes": len(decoded),
    }, decoded


def convert_message(
    message: Any,
    label: str,
    blobs: dict[str, bytes],
) -> tuple[dict[str, Any], int]:
    if not isinstance(message, dict):
        fail(f"{label}: message must be an object")
    result = dict(message)
    content = result.get("content")
    if isinstance(content, str):
        return result, 0
    if not isinstance(content, list):
        fail(f"{label}: message content must be text or a block list")
    converted: list[Any] = []
    image_count = 0
    for block_number, block in enumerate(content, 1):
        if not isinstance(block, dict):
            fail(f"{label}: content block {block_number} must be an object")
        if block.get("type") == "image":
            image, data = decode_image(block, f"{label}: content block {block_number}")
            existing = blobs.get(image["file_id"])
            if existing is not None and existing != data:
                fail(f"{label}: SHA-256 collision while migrating an image")
            blobs[image["file_id"]] = data
            converted.append(image)
            image_count += 1
        else:
            converted.append(dict(block))
    result["content"] = converted
    return result, image_count


def copy_selection_state(state: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    if "model" in state:
        result["model"] = dict(state["model"])
    if "thinking_level" in state:
        result["thinking_level"] = state["thinking_level"]
    return result


def apply_request_state(state: dict[str, Any], request: Any, label: str) -> None:
    if request is None:
        return
    if not isinstance(request, dict):
        fail(f"{label}: message request must be an object")
    unsupported = set(request) - {"model", "thinkingLevel"}
    if unsupported:
        fail(f"{label}: message request has unsupported fields: {sorted(unsupported)}")
    model = request.get("model")
    if model is not None:
        if (
            not isinstance(model, dict)
            or set(model) != {"provider", "model"}
            or not safe_text(model.get("provider"))
            or not safe_text(model.get("model"))
        ):
            fail(f"{label}: message request model requires provider and model")
        state["model"] = dict(model)
    if "thinkingLevel" in request:
        level = request["thinkingLevel"]
        if level is not None and not safe_text(level):
            fail(f"{label}: message request thinkingLevel must be safe text or null")
        state["thinking_level"] = level


def request_from_state(state: dict[str, Any]) -> dict[str, Any]:
    request: dict[str, Any] = {}
    if "model" in state:
        request["model"] = dict(state["model"])
    if "thinking_level" in state:
        request["thinkingLevel"] = state["thinking_level"]
    return request


def normalize_legacy_entries(
    source: SourceSession, warnings: list[str]
) -> list[tuple[int, dict[str, Any]]]:
    legacy_by_id: dict[str, dict[str, Any]] = {}
    current_id_by_legacy_id: dict[str, str | None] = {}
    state_by_id: dict[str, dict[str, Any]] = {}
    converted: list[tuple[int, dict[str, Any]]] = []
    selection_entries = 0
    active_tools_entries = 0
    for line_number, entry in enumerate(source.records, 2):
        label = f"{source.path}:{line_number}"
        entry_type = entry.get("type")
        accepted = ENTRY_FIELDS.get(entry_type) or LEGACY_STATE_FIELDS.get(entry_type)
        if accepted is None:
            fail(f"{label}: unsupported entry type: {entry_type}")
        if set(entry) - accepted:
            fail(
                f"{label}: unsupported {entry_type} fields: "
                f"{sorted(set(entry) - accepted)}"
            )
        entry_id = entry.get("id")
        if not safe_text(entry_id):
            fail(f"{label}: entry id cannot be represented by the current format")
        if entry_id in legacy_by_id:
            fail(f"{label}: duplicate entry id: {entry_id}")
        parent = entry.get("parentId")
        if parent is not None and (not safe_text(parent) or parent not in legacy_by_id):
            fail(f"{label}: parentId does not reference a prior safe entry")
        timestamp_ms(entry.get("timestamp"), label)
        state = copy_selection_state(state_by_id.get(parent, {}))
        current_parent = current_id_by_legacy_id[parent] if parent is not None else None

        if entry_type == "model_change":
            provider = entry.get("provider")
            model = entry.get("modelId")
            if not safe_text(provider) or not safe_text(model):
                fail(f"{label}: model changes require safe provider and modelId")
            state["model"] = {"provider": provider, "model": model}
            current_id_by_legacy_id[entry_id] = current_parent
            selection_entries += 1
        elif entry_type == "thinking_level_change":
            level = entry.get("thinkingLevel")
            if not safe_text(level):
                fail(f"{label}: thinking level changes require safe thinkingLevel")
            state["thinking_level"] = level
            current_id_by_legacy_id[entry_id] = current_parent
            selection_entries += 1
        elif entry_type == "active_tools_change":
            names = entry.get("activeToolNames")
            if not isinstance(names, list) or not all(
                isinstance(name, str) for name in names
            ):
                fail(f"{label}: active tool changes require an array of tool names")
            current_id_by_legacy_id[entry_id] = current_parent
            active_tools_entries += 1
        else:
            candidate = dict(entry)
            candidate["parentId"] = current_parent
            if entry_type == "message":
                apply_request_state(state, entry.get("request"), label)
                message = entry.get("message")
                if isinstance(message, dict) and message.get("role") == "assistant":
                    provider = message.get("provider")
                    model = message.get("model")
                    if safe_text(provider) and safe_text(model):
                        state["model"] = {"provider": provider, "model": model}
                request = request_from_state(state)
                if request or "request" in entry:
                    candidate["request"] = request
            elif entry_type == "leaf":
                target = entry.get("targetId")
                if target is not None:
                    if not safe_text(target) or target not in legacy_by_id:
                        fail(f"{label}: leaf targetId does not reference a prior entry")
                    candidate["targetId"] = current_id_by_legacy_id[target]
                    state = copy_selection_state(state_by_id[target])
            elif entry_type == "compaction":
                kept = entry.get("firstKeptEntryId")
                if not safe_text(kept) or kept not in legacy_by_id:
                    fail(
                        f"{label}: compaction firstKeptEntryId does not reference "
                        "a prior entry"
                    )
                candidate["firstKeptEntryId"] = current_id_by_legacy_id[kept]
            converted.append((line_number, candidate))
            current_id_by_legacy_id[entry_id] = entry_id

        legacy_by_id[entry_id] = entry
        state_by_id[entry_id] = state

    if selection_entries:
        noun = "entry" if selection_entries == 1 else "entries"
        warnings.append(
            f"{source.path.name}: folded {selection_entries} legacy selection "
            f"{noun} into message request state"
        )
    if active_tools_entries:
        noun = "entry" if active_tools_entries == 1 else "entries"
        warnings.append(
            f"{source.path.name}: discarded {active_tools_entries} legacy "
            f"active-tools {noun}; current Sessions do not own tool selection"
        )
    return converted


def convert_entry(
    entry: dict[str, Any],
    line_number: int,
    source: SourceSession,
    blobs: dict[str, bytes],
    by_id: dict[str, dict[str, Any]],
) -> tuple[dict[str, Any], int]:
    label = f"{source.path}:{line_number}"
    entry_type = entry.get("type")
    accepted = ENTRY_FIELDS.get(entry_type)
    if accepted is None:
        fail(f"{label}: unsupported entry type: {entry_type}")
    if set(entry) - accepted:
        fail(
            f"{label}: unsupported {entry_type} fields: {sorted(set(entry) - accepted)}"
        )
    entry_id = entry.get("id")
    if not safe_text(entry_id):
        fail(f"{label}: entry id cannot be represented by the current format")
    if entry_id in by_id:
        fail(f"{label}: duplicate entry id: {entry_id}")
    parent = entry.get("parentId")
    if parent is not None and (not safe_text(parent) or parent not in by_id):
        fail(f"{label}: parentId does not reference a prior safe entry")
    result: dict[str, Any] = {
        "type": entry_type,
        "id": entry_id,
        "parent_id": parent,
        "created_at": timestamp_ms(entry.get("timestamp"), label),
    }
    image_count = 0
    if entry_type == "message":
        result["message"], image_count = convert_message(
            entry.get("message"), label, blobs
        )
        request = entry.get("request")
        if request is not None:
            if not isinstance(request, dict):
                fail(f"{label}: message request must be an object")
            unsupported = set(request) - {"model", "thinkingLevel"}
            if unsupported:
                fail(
                    f"{label}: message request has unsupported fields: {sorted(unsupported)}"
                )
            converted_request = dict(request)
            if "thinkingLevel" in converted_request:
                converted_request["thinking_level"] = converted_request.pop(
                    "thinkingLevel"
                )
            result["request"] = converted_request
    elif entry_type == "compaction":
        summary = entry.get("summary")
        kept = entry.get("firstKeptEntryId")
        tokens = entry.get("tokensBefore")
        if (
            not isinstance(summary, str)
            or not summary
            or not safe_text(kept)
            or not is_nonnegative_integer(tokens)
        ):
            fail(f"{label}: invalid compaction entry")
        if kept not in by_id:
            fail(f"{label}: compaction firstKeptEntryId does not exist")
        current = by_id.get(parent) if parent is not None else None
        while current is not None and current["id"] != kept:
            ancestor = current.get("parent_id")
            current = by_id.get(ancestor) if ancestor is not None else None
        if current is None:
            fail(f"{label}: compaction firstKeptEntryId is not on the active path")
        result.update(
            summary=summary,
            first_kept_entry_id=kept,
            tokens_before=tokens,
        )
    else:
        target = entry.get("targetId")
        if target is not None and (not safe_text(target) or target not in by_id):
            fail(f"{label}: leaf targetId does not reference a prior safe entry")
        result["target_id"] = target
    by_id[entry_id] = result
    return result, image_count


def picker_text(records: list[dict[str, Any]]) -> str:
    by_id = {record["id"]: record for record in records}
    leaf: str | None = None
    for record in records:
        leaf = record.get("target_id") if record["type"] == "leaf" else record["id"]
    path: list[dict[str, Any]] = []
    while leaf is not None:
        record = by_id[leaf]
        path.append(record)
        leaf = record.get("parent_id")
    for record in reversed(path):
        if record["type"] != "message" or record["message"].get("role") != "user":
            continue
        content = record["message"].get("content")
        if isinstance(content, str):
            text = content
        else:
            text = "".join(
                block.get("text", "")
                for block in content or []
                if isinstance(block, dict) and block.get("type") == "text"
            )
        if text:
            return re.sub(r"[\s\x00-\x1f\x7f]+", " ", text).strip() or "(no messages)"
    return "(no messages)"


def build_plan(source: WorkspaceSource, session_paths: dict[str, str]) -> WorkspacePlan:
    blobs: dict[str, bytes] = {}
    sessions: list[SessionPlan] = []
    warnings = list(source.warnings)
    if source.index_warning:
        warnings.append(source.index_warning)
    filenames: set[str] = set()
    image_count = 0
    index_sessions: dict[str, Any] = {}
    for session in source.sessions:
        header = session.header
        session_id = header["id"]
        if not safe_text(session_id) or "/" in session_id or "\\" in session_id:
            fail(f"Session id cannot be used by the current format: {session.path}")
        filename = session_id + ".jsonl"
        if filename in filenames:
            fail(f"Duplicate Session id in workspace {source.path}: {session_id}")
        filenames.add(filename)
        parent, unresolved_parent = parent_session_id(
            header.get("parentSession"), session_paths
        )
        if unresolved_parent:
            warnings.append(
                f"kept unresolved parent Session value in {session.path.name}: {parent}"
            )
        converted_header: dict[str, Any] = {
            "type": "session",
            "format": SESSION_FORMAT,
            "id": session_id,
            "created_at": timestamp_ms(header["timestamp"], f"{session.path}:1"),
            "cwd": header["cwd"],
        }
        if parent is not None:
            converted_header["parent_session"] = parent
        if header.get("metadata") is not None:
            converted_header["metadata"] = header["metadata"]
        converted_records = [converted_header]
        by_id: dict[str, dict[str, Any]] = {}
        legacy_entries = normalize_legacy_entries(session, warnings)
        for line_number, entry in legacy_entries:
            converted, images = convert_entry(entry, line_number, session, blobs, by_id)
            converted_records.append(converted)
            image_count += images
        if session.ignored_tail:
            warnings.append(
                f"ignored the incomplete final JSONL record in {session.path.name}"
            )
        sessions.append(
            SessionPlan(
                source=session,
                filename=filename,
                session_id=session_id,
                parent_session=parent,
                records=converted_records,
            )
        )
        indexed: dict[str, Any] = {
            "id": session_id,
            "text": picker_text(converted_records[1:]),
        }
        if parent is not None:
            indexed["parent_session"] = parent
        old_entry = source.old_index.get(session.path.name)
        if isinstance(old_entry, dict) and isinstance(
            old_entry.get("attributes"), dict
        ):
            indexed["attributes"] = old_entry["attributes"]
        index_sessions[filename] = indexed
    return WorkspacePlan(
        source=source,
        sessions=sessions,
        blobs=blobs,
        index={"format": INDEX_FORMAT, "sessions": index_sessions},
        image_count=image_count,
        warnings=warnings,
    )


def write_file(path: Path, data: bytes, mode: int = 0o600) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, mode)
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
    except OSError as error:
        fail(f"Could not publish {path}: {error}")


def make_directory(path: Path) -> None:
    try:
        path.mkdir(mode=0o700)
    except OSError as error:
        fail(f"Could not create directory {path}: {error}")


def sync_directory(path: Path) -> None:
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    try:
        descriptor = os.open(path, flags)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except OSError as error:
        fail(f"Could not synchronize directory {path}: {error}")


def write_staging(plan: WorkspacePlan, staging: Path) -> None:
    write_file(staging / "workspace.json", encode_json(WORKSPACE_MARKER))
    if plan.source.settings is not None:
        write_file(staging / "settings.json", plan.source.settings)
    if plan.source.input_history is not None:
        write_file(staging / "input-history.jsonl", plan.source.input_history)
    sessions_directory = staging / "sessions"
    if plan.sessions:
        make_directory(sessions_directory)
        for session in plan.sessions:
            source_stat = regular_file(session.source.path, "Session")
            identity = (
                source_stat.st_dev,
                source_stat.st_ino,
                source_stat.st_size,
                source_stat.st_mtime_ns,
            )
            if identity != session.source.identity:
                fail(
                    f"Session changed after validation; close Neoagent and retry: {session.source.path}"
                )
            content = b"".join(encode_json(record) for record in session.records)
            destination = sessions_directory / session.filename
            write_file(destination, content)
            os.utime(destination, ns=(source_stat.st_atime_ns, source_stat.st_mtime_ns))
        sync_directory(sessions_directory)
    if plan.blobs:
        files_directory = staging / "files"
        make_directory(files_directory)
        for digest, data in sorted(plan.blobs.items()):
            attachment_directory = files_directory / digest
            make_directory(attachment_directory)
            write_file(attachment_directory / "content", data)
            sync_directory(attachment_directory)
        sync_directory(files_directory)
    if plan.source.recording_directories:
        recordings_directory = staging / "recordings"
        make_directory(recordings_directory)
        for relative in plan.source.recording_directories:
            if relative != Path("."):
                make_directory(recordings_directory / relative)
        for item in plan.source.recording_files:
            source_stat = regular_file(item.source, "Recording")
            identity = (
                source_stat.st_dev,
                source_stat.st_ino,
                source_stat.st_size,
                source_stat.st_mtime_ns,
            )
            if identity != item.identity:
                fail(
                    f"Recording changed after validation; close Neoagent and retry: {item.source}"
                )
            write_file(
                recordings_directory / item.relative,
                read_bytes(item.source, "Recording"),
            )
        for relative in reversed(plan.source.recording_directories):
            sync_directory(
                recordings_directory
                if relative == Path(".")
                else recordings_directory / relative
            )
    write_file(staging / "session-index.json", encode_json(plan.index))
    sync_directory(staging)


def apply_plan(plan: WorkspacePlan, root: Path, backup_root: Path) -> Path:
    source = plan.source.path
    backup = backup_root / source.name
    if path_exists(backup):
        fail(f"Backup already exists; refusing to overwrite it: {backup}")
    staging = Path(
        tempfile.mkdtemp(prefix=f".{source.name}.neoagent-migrate-", dir=root)
    )
    os.chmod(staging, 0o700)
    moved = False
    try:
        write_staging(plan, staging)
        os.rename(source, backup)
        moved = True
        try:
            os.rename(staging, source)
        except OSError:
            os.rename(backup, source)
            moved = False
            raise
        sync_directory(root)
        sync_directory(backup_root)
    except Exception:
        if path_exists(staging):
            shutil.rmtree(staging)
        if moved and not path_exists(source) and path_exists(backup):
            os.rename(backup, source)
        raise
    return backup


def migration_summary(plans: list[WorkspacePlan]) -> tuple[int, int, int]:
    sessions = sum(len(plan.sessions) for plan in plans)
    images = sum(plan.image_count for plan in plans)
    bytes_count = sum(sum(len(data) for data in plan.blobs.values()) for plan in plans)
    return sessions, images, bytes_count


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "directory",
        nargs="?",
        type=Path,
        default=DEFAULT_DIRECTORY,
        help=f"workspace root (default: {DEFAULT_DIRECTORY})",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="publish converted workspaces; without this flag, only validate and report",
    )
    parser.add_argument(
        "--backup-directory",
        type=Path,
        help="directory for original workspaces (default: <workspace-root>.master-v3-backup)",
    )
    args = parser.parse_args(argv)
    root = Path(os.path.abspath(args.directory.expanduser()))
    backup_root = (
        Path(os.path.abspath(args.backup_directory.expanduser()))
        if args.backup_directory
        else root.with_name(root.name + ".master-v3-backup")
    )
    if backup_root == root or root in backup_root.parents:
        fail("Backup directory must be outside the workspace root")

    sources, current = inspect_root(root)
    session_paths = {
        os.path.abspath(str(session.path)): session.header["id"]
        for source in sources
        for session in source.sessions
    }
    plans = [build_plan(source, session_paths) for source in sources]
    sessions, images, bytes_count = migration_summary(plans)
    print(
        f"Validated {len(plans)} master-format workspace(s): "
        f"{sessions} Session(s), {images} inline image(s), "
        f"{bytes_count} unique attachment byte(s)."
    )
    if current:
        print(f"Skipped {len(current)} workspace(s) already in the current format.")
    for plan in plans:
        print(
            f"  {plan.source.path.name}: {len(plan.sessions)} Session(s), "
            f"{len(plan.blobs)} unique attachment(s)"
        )
        for warning in plan.warnings:
            print(f"    warning: {warning}")
    if not plans:
        print("Nothing to migrate.")
        return 0
    if not args.apply:
        print(
            "Dry run only; no files were changed. Re-run with --apply after closing Neoagent."
        )
        return 0

    if path_exists(backup_root):
        directory(backup_root, "Backup directory")
    else:
        make_directory(backup_root)
        sync_directory(backup_root.parent)
    for plan in plans:
        backup = backup_root / plan.source.path.name
        if path_exists(backup):
            fail(f"Backup already exists; refusing to overwrite it: {backup}")
    for plan in plans:
        backup = apply_plan(plan, root, backup_root)
        print(f"Migrated {plan.source.path.name}; original saved at {backup}")
    print(f"Migration complete. Originals remain under {backup_root}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (MigrationError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2) from None
