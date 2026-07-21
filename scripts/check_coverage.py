#!/usr/bin/env python3
import re
import sys
from pathlib import Path


report = sys.argv[1]
threshold = float(sys.argv[2])
with open(report, "r", encoding="utf-8") as source:
    text = source.read()

matches = re.findall(r"^Total\s+\d+\s+\d+\s+([0-9.]+)%\s*$", text, re.MULTILINE)
if not matches:
    raise SystemExit(f"could not find total coverage in {report}")

coverage = float(matches[-1])
expected = {
    path.as_posix()
    for root in (Path("lua/neoagent"), Path("plugin"))
    for path in root.rglob("*.lua")
}
reported = set()
for filename in re.findall(r"^(.*?)\s+\d+\s+\d+\s+[0-9.]+%\s*$", text, re.MULTILINE):
    filename = filename.strip()
    if filename == "Total" or filename == "File":
        continue
    path = Path(filename)
    try:
        filename = path.resolve().relative_to(Path.cwd().resolve()).as_posix()
    except ValueError:
        filename = path.as_posix()
    reported.add(filename)
missing = sorted(expected - reported)
if missing:
    print("Coverage report is missing shipped Lua files:", file=sys.stderr)
    for filename in missing:
        print(f"  {filename}", file=sys.stderr)
    raise SystemExit(1)
print(f"Neoagent Lua line coverage: {coverage:.2f}% (required: > {threshold:.2f}%)")
if coverage <= threshold:
    raise SystemExit(1)
