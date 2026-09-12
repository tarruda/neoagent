#!/usr/bin/env python3
"""Collect and merge standard LuaCov counters from native CI hosts."""

import argparse
import hashlib
import json
from pathlib import Path, PureWindowsPath
import platform
import shutil


ROOT = Path(__file__).resolve().parent.parent
DIRECTORY = ROOT / ".coverage"


def sources():
    result = {}
    for directory in ("lua/applet", "lua/neoagent", "plugin"):
        for path in sorted((ROOT / directory).rglob("*.lua")):
            content = path.read_bytes().replace(b"\r\n", b"\n")
            result[path.relative_to(ROOT).as_posix()] = {
                "sha256": hashlib.sha256(content).hexdigest(),
                "lines": len(content.splitlines()),
            }
    return result


def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")


def start():
    if DIRECTORY.exists():
        shutil.rmtree(DIRECTORY)
    (DIRECTORY / "raw").mkdir(parents=True)
    write_json(DIRECTORY / "manifest.json", {
        "root": ROOT.as_posix(), "platform": platform.system(), "sources": sources(),
    })


def verify_sources(expected):
    current = sources()
    changed = sorted(path for path in current.keys() | expected.keys() if current.get(path) != expected.get(path))
    if changed:
        raise SystemExit("Coverage sources changed; run a fresh collection:\n" + "\n".join(changed))
    return current


def export():
    manifest = json.loads((DIRECTORY / "manifest.json").read_text(encoding="utf-8"))
    current = verify_sources(manifest["sources"])
    counts = {path: [0] * item["lines"] for path, item in current.items()}
    raw_files = sorted((DIRECTORY / "raw").glob("*.out"))
    if not raw_files:
        raise SystemExit("No LuaCov counters were collected.")
    for raw in raw_files:
        lines = iter(raw.read_text(encoding="utf-8").splitlines())
        for header in lines:
            maximum, separator, filename = header.partition(":")
            values = next(lines, "").split()
            if not separator or not maximum.isdecimal() or len(values) != int(maximum):
                raise SystemExit(f"Incomplete LuaCov statistics: {raw}")
            filename = filename.replace("\\", "/")
            prefix = manifest["root"].replace("\\", "/").rstrip("/") + "/"
            if manifest["platform"] == "Windows" and PureWindowsPath(filename).is_absolute():
                try:
                    filename = PureWindowsPath(filename).relative_to(PureWindowsPath(manifest["root"])).as_posix()
                except ValueError:
                    raise SystemExit(f"Unexpected source in LuaCov statistics: {filename}") from None
            elif filename.startswith(prefix):
                filename = filename[len(prefix):]
            elif filename.startswith("./"):
                filename = filename[2:]
            if filename not in counts:
                raise SystemExit(f"Unexpected source in LuaCov statistics: {filename}")
            for index, value in enumerate(values):
                if not value.isdecimal():
                    raise SystemExit(f"Invalid LuaCov counter: {raw}")
                count = int(value)
                if index >= len(counts[filename]):
                    if count:
                        raise SystemExit(f"LuaCov hit beyond the source: {filename}:{index + 1}")
                else:
                    counts[filename][index] += count
    write_json(DIRECTORY / "collection.json", {
        "platform": manifest["platform"], "sources": current, "counts": counts,
    })
    print(f"Collected LuaCov data from {len(raw_files)} processes on {manifest['platform']}.")


def merge(paths, require_platforms):
    current = sources()
    counts = {path: [0] * item["lines"] for path, item in current.items()}
    platforms = set()
    for path in paths:
        collection = json.loads(Path(path).read_text(encoding="utf-8"))
        verify_sources(collection["sources"])
        platforms.add(collection["platform"])
        if collection["counts"].keys() != current.keys():
            raise SystemExit(f"Incomplete shipped-file inventory: {path}")
        for filename, values in collection["counts"].items():
            if len(values) != len(counts[filename]) or any(type(value) is not int or value < 0 for value in values):
                raise SystemExit(f"Invalid coverage counters: {path}: {filename}")
            for index, value in enumerate(values):
                counts[filename][index] += value
    missing = set(require_platforms) - platforms
    if missing:
        raise SystemExit("Missing native coverage collections: " + ", ".join(sorted(missing)))
    DIRECTORY.mkdir(exist_ok=True)
    with (DIRECTORY / "luacov.stats.out").open("w", encoding="utf-8", newline="\n") as output:
        for filename, values in sorted(counts.items()):
            output.write(f"{len(values)}:{filename}\n")
            output.write("".join(f"{value} " for value in values) + "\n")
    print("Merged native LuaCov collections: " + ", ".join(sorted(platforms)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("start")
    commands.add_parser("export")
    merging = commands.add_parser("merge")
    merging.add_argument("collections", nargs="+")
    merging.add_argument("--require-platforms", nargs="*", default=[])
    args = parser.parse_args()
    if args.command == "start":
        start()
    elif args.command == "export":
        export()
    else:
        merge(args.collections, args.require_platforms)


if __name__ == "__main__":
    main()
