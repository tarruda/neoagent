#!/usr/bin/env python3
"""Build LuaCov's official collector and executable-line filter."""

import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import platform
import shlex
import subprocess
import tarfile
import urllib.request


ROOT = Path(__file__).resolve().parent.parent / ".deps/coverage-native"
SOURCES = {
    "cluacov": (
        "lunarmodules/cluacov", "3a23d1ad5c6c25994aaa46ff5884e085bea8302a",
        "ac4392ad5b067d14042c97be95c00d74e9ea049bcdfe5ea89a354855c26f61e8",
    ),
    "luajit": (
        "LuaJIT/LuaJIT", "75e92777988017fe47c5eb290998021bbf972d1f",
        "0f69288190024d732c67645e40ed5b137d67aa950fedf0f44a9ad0f3dba6d5d2",
    ),
}


def install(name, repository, revision, digest):
    target = ROOT / name
    marker = target / ".sha256"
    if marker.is_file() and marker.read_text() == digest:
        return
    url = f"https://codeload.github.com/{repository}/tar.gz/{revision}"
    print(f"Downloading {url}", flush=True)
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != digest:
        raise RuntimeError(f"SHA-256 mismatch: {url}")
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for member in archive:
            if not member.isfile():
                continue
            relative = PurePosixPath(*PurePosixPath(member.name).parts[1:])
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError(f"Invalid archive path: {member.name}")
            output = target / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as source:
                output.write_bytes(source.read())
    marker.write_text(digest)


def main():
    if platform.system() not in ("Linux", "Darwin"):
        raise SystemExit("Generate the merged coverage report on Linux or macOS; collection is portable.")
    for name, values in SOURCES.items():
        install(name, *values)
    headers = ROOT / "luajit/src"
    make_environment = os.environ.copy()
    if platform.system() == "Darwin" and not make_environment.get("MACOSX_DEPLOYMENT_TARGET"):
        version = platform.mac_ver()[0].split(".")
        if not version[0]:
            raise RuntimeError("Could not determine the macOS deployment target")
        make_environment["MACOSX_DEPLOYMENT_TARGET"] = ".".join(version[:2])
    subprocess.run(["make", "-C", str(headers), "luajit.h"], check=True, env=make_environment)
    compiler = shlex.split(os.environ.get("CC", "cc"))
    flags = ["-bundle", "-undefined", "dynamic_lookup"] if platform.system() == "Darwin" else ["-shared"]
    for module in ("deepactivelines", "hook"):
        binary = ROOT / f"lib/cluacov/{module}.so"
        binary.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(compiler + flags + [
            "-fPIC", "-O2", "-I" + str(headers), "-o", str(binary),
            str(ROOT / f"cluacov/src/cluacov/{module}.c"),
        ], check=True)


if __name__ == "__main__":
    main()
