#!/usr/bin/env python3
"""Install the pinned development-only analyzer and external declarations."""

import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import platform
import shutil
import tarfile
import tempfile
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parent.parent
VERSION = "0.25.1"
RELEASE = "https://github.com/EmmyLuaLs/emmylua-analyzer-rust/releases/download"
# Upstream release asset SHA-256 digests; checker followed by language server.
BINARIES = {
    ("Linux", "x86_64"): ("linux-musl", (
        "eb6fda391d72395bc665bab0f5777e72feebfe3f7f513332baab7458ecdb66a1",
        "56c0c34494436817ba6aeb0964172d8e6522af6d1eea1c92e4c5bef55f03efc3")),
    ("Linux", "aarch64"): ("linux-aarch64-glibc.2.17", (
        "62a9a56d3ff5d0e108909332cb91582a0c1a4ebbfdce1a4422e7ae74d4a7f8b1",
        "210535be13c31ceefcdd0f8451eb4c0d3d430887fc2c382eaf82484a9187220d")),
    ("Darwin", "arm64"): ("darwin-arm64", (
        "eeaad59d173cb8d7cb0fe778936d7b584fe114a3eb46587ef3e4aec24b605af4",
        "335023043cbc9ad683a13b24eb79f709a370215daf53673276b9a9663df96504")),
    ("Darwin", "x86_64"): ("darwin-x64", (
        "e91fe82c361d8dece8e2ce9aeb2313b8809b4714f72bbbeab5a27e754d8de2c6",
        "abc9cbe2e8d28624e0d441fa55055b1196f73251b034356d717b0e58b562f182")),
    ("Windows", "AMD64"): ("win32-x64", (
        "577982e68d925972d8ae35f54b5f384ad77a84a2e31e340bd663d1efd2ef5983",
        "82efa133287f67be09e1a624d8efecd8063832ec2b9bf9279c37afc5f42118bd")),
}


def download(url, digest):
    print(f"Downloading {url}", flush=True)
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != digest:
        raise RuntimeError(f"SHA-256 mismatch: {url}")
    return data


def entries(data, zipped=False):
    """Yield regular files only; never extract archive links or special files."""
    if zipped:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for item in archive.infolist():
                if not item.is_dir():
                    yield PurePosixPath(item.filename), archive.read(item)
    else:
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            for item in archive:
                if item.isfile():
                    with archive.extractfile(item) as source:
                        yield PurePosixPath(item.name), source.read()


def install_binary(tool, target, digest, windows):
    directory = ROOT / ".deps/emmylua/bin"
    directory.mkdir(parents=True, exist_ok=True)
    name = tool + (".exe" if windows else "")
    destination = directory / name
    marker = directory / (name + ".sha256")
    if destination.is_file() and marker.is_file() and marker.read_text() == digest:
        return
    extension = "zip" if windows else "tar.gz"
    data = download(f"{RELEASE}/{VERSION}/{tool}-{target}.{extension}", digest)
    matches = [content for path, content in entries(data, windows) if path.name == name]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one {name} in the release archive")
    with tempfile.NamedTemporaryFile(dir=directory, delete=False) as temporary:
        temporary.write(matches[0])
    os.chmod(temporary.name, 0o755)
    os.replace(temporary.name, destination)
    marker.write_text(digest)


def install_types(name, url, digest, included):
    parent = ROOT / ".deps/typecheck"
    parent.mkdir(parents=True, exist_ok=True)
    destination = parent / name
    marker = destination / ".sha256"
    if marker.is_file() and marker.read_text() == digest:
        return
    data = download(url, digest)
    with tempfile.TemporaryDirectory(dir=parent) as temporary:
        staging = Path(temporary) / name
        staging.mkdir()
        for path, content in entries(data):
            relative = PurePosixPath(*path.parts[1:])
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError(f"Invalid archive path: {path}")
            if any(str(relative) == prefix or str(relative).startswith(prefix + "/")
                   for prefix in included):
                output = staging / relative
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(content)
        (staging / ".sha256").write_text(digest)
        if destination.exists():
            shutil.rmtree(destination)
        staging.rename(destination)


def main():
    host = (platform.system(), platform.machine())
    if host not in BINARIES:
        raise SystemExit(f"No pinned EmmyLua binary configured for {host}")
    target, digests = BINARIES[host]
    for tool, digest in zip(("emmylua_check", "emmylua_ls"), digests):
        install_binary(tool, target, digest, host[0] == "Windows")
    install_types("neovim",
        "https://codeload.github.com/neovim/neovim/tar.gz/refs/tags/v0.10.2",
        "546cb2da9fffbb7e913261344bbf4cf1622721f6c5a67aa77609e976e78b8e89",
        ("runtime/lua", "LICENSE.txt"))
    install_types("luv",
        "https://codeload.github.com/LuaCATS/luv/tar.gz/3615eb12c94a7cfa7184b8488cf908abb5e94c9c",
        "0631e73045be8fa37042df1eef6617d82e1f9786b8bd4191f1ed479fb738458f",
        ("library", "LICENSE"))
    print(f"EmmyLua {VERSION}, Neovim v0.10.2 and pinned libuv declarations ready.")


if __name__ == "__main__":
    main()
