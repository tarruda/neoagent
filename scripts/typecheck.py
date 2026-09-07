#!/usr/bin/env python3
"""Run full analysis, enforcing diagnostics outside the temporary adoption list."""

import argparse
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checker", default=str(ROOT / ".deps/emmylua/bin/emmylua_check"))
    args = parser.parse_args()
    for dependency in ("neovim/runtime/lua/vim/_meta/api.lua", "luv/library/uv.lua"):
        if not (ROOT / ".deps/typecheck" / dependency).is_file():
            raise SystemExit("Missing type definitions; run make typecheck-deps.")
    try:
        subprocess.run([args.checker, "--version"], check=True, cwd=ROOT)
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Cannot run checker; run make typecheck-deps: {error}") from error

    sources = set(subprocess.check_output([
        "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "*.lua"
    ], cwd=ROOT).decode().rstrip("\0").split("\0")) - {""}
    pending_path = ROOT / ".typecheck-pending"
    pending = set()
    if pending_path.exists():
        for line in pending_path.read_text().splitlines():
            if line and not line.startswith("#"):
                if line in pending or line not in sources:
                    raise SystemExit(f"Duplicate or stale pending file: {line}")
                pending.add(line)

    report = ROOT / ".test-data/typecheck/diagnostics.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    if report.exists():
        report.unlink()
    process = subprocess.run([
        args.checker, ".", "-c", ".emmyrc.json", "--severity", "warn",
        "--warnings-as-errors", "-f", "json", "--output", str(report),
    ], cwd=ROOT, capture_output=True, text=True)
    if process.returncode not in (0, 1) or not report.is_file() or "ERROR:" in process.stderr:
        sys.stderr.write(process.stdout + process.stderr)
        raise SystemExit("EmmyLua could not complete analysis.")
    results = json.loads(report.read_text())
    diagnosed = set()
    failures = 0
    deferred = 0
    for result in sorted(results, key=lambda item: item["file"]):
        path = Path(result["file"]).resolve().relative_to(ROOT).as_posix()
        diagnosed.add(path)
        for diagnostic in result["diagnostics"]:
            if path in pending:
                deferred += 1
                continue
            failures += 1
            start = diagnostic["range"]["start"]
            print(f"{path}:{start['line'] + 1}:{start['character'] + 1}: "
                  f"{diagnostic['code']}: {diagnostic['message']}")
    missing = sources - diagnosed
    if missing:
        raise SystemExit("Lua files missing from analysis:\n" + "\n".join(sorted(missing)))
    if process.returncode and not any(item["diagnostics"] for item in results):
        sys.stderr.write(process.stderr)
        raise SystemExit("Checker failed without diagnostics.")
    print(f"Typing: {len(sources - pending)}/{len(sources)} Lua files enforced; "
          f"{len(pending)} pending ({deferred} deferred diagnostics); {failures} failures.")
    raise SystemExit(1 if failures else 0)


if __name__ == "__main__":
    main()
