#!/usr/bin/env python3
import re
import sys
from pathlib import Path


report = sys.argv[1]
plugin_threshold = float(sys.argv[2])
with open(report, "r", encoding="utf-8") as source:
    text = source.read()

expected = {
    path.as_posix()
    for root in (Path("lua/applet"), Path("lua/neoagent"), Path("plugin"))
    for path in root.rglob("*.lua")
}
reported = {}
rows = re.findall(
    r"^(.*?)\s+(\d+)\s+(\d+)\s+[0-9.]+%\s*$",
    text,
    re.MULTILINE,
)
for filename, hits, missed in rows:
    filename = filename.strip()
    if filename == "Total" or filename == "File":
        continue
    path = Path(filename)
    try:
        filename = path.resolve().relative_to(Path.cwd().resolve()).as_posix()
    except ValueError:
        filename = path.as_posix()
    reported[filename] = (int(hits), int(missed))
missing = sorted(expected - reported.keys())
if missing:
    print("Coverage report is missing shipped Lua files:", file=sys.stderr)
    for filename in missing:
        print(f"  {filename}", file=sys.stderr)
    raise SystemExit(1)


def coverage(paths):
    hits = sum(reported[path][0] for path in paths)
    missed = sum(reported[path][1] for path in paths)
    return hits, missed, 100 * hits / (hits + missed)


applet_paths = {
    path for path in expected if path.startswith("lua/applet/")
}
_, applet_missed, applet_coverage = coverage(applet_paths)
print(
    f"Applet Lua line coverage: {applet_coverage:.2f}% "
    "(required: 100.00%)"
)
if applet_missed != 0:
    raise SystemExit(1)

_, _, plugin_coverage = coverage(expected)
print(
    f"Shipped-plugin Lua line coverage: {plugin_coverage:.2f}% "
    f"(required: > {plugin_threshold:.2f}%)"
)
if plugin_coverage <= plugin_threshold:
    raise SystemExit(1)
