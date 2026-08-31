#!/usr/bin/env python3
import binascii
import json
import os
from pathlib import Path
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib


ROOT = Path(__file__).resolve().parents[2]


def executable(value):
    path = Path(value).expanduser()
    if path.parent != Path("."):
        return str(path) if path.is_file() and os.access(path, os.X_OK) else None
    return shutil.which(value)


def png_chunk(kind, data):
    return (struct.pack(">I", len(data)) + kind + data
            + struct.pack(">I", binascii.crc32(kind + data) & 0xFFFFFFFF))


def write_source(path, high_color):
    width, height = 640, 384
    rows = []
    if high_color:
        state = 0x5EED1234
        for _ in range(height):
            row = bytearray(b"\0")
            for _ in range(width):
                state = (1664525 * state + 1013904223) & 0xFFFFFFFF
                row.extend((180 + state % 76,
                            (state >> 8) % 101,
                            180 + (state >> 16) % 76))
            rows.append(row)
    else:
        row = b"\0" + bytes((255, 0, 255)) * width
        rows = [row] * height
    data = (b"\x89PNG\r\n\x1a\n"
            + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height,
                                                   8, 2, 0, 0, 0))
            + png_chunk(b"IDAT", zlib.compress(b"".join(rows)))
            + png_chunk(b"IEND", b""))
    path.write_bytes(data)


def output(log):
    log.flush()
    return Path(log.name).read_text(encoding="utf-8", errors="replace")[-8000:]


def diagnostics(log, nvim_log):
    parts = [output(log)]
    if nvim_log.is_file():
        parts.append(nvim_log.read_text(
            encoding="utf-8", errors="replace")[-8000:])
    return "\n".join(parts)


def read_json(path, timeout=1):
    deadline = time.monotonic() + timeout
    while True:
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.01)


def screen_metrics(image_tool, screenshot):
    command = [image_tool, str(screenshot), "-crop", "900x600+0+0",
               "-alpha", "off", "-depth", "8", "rgb:-"]
    pixels = subprocess.check_output(command, cwd=ROOT)
    row_width = 900
    row_counts = []
    row_spans = []
    green = 0
    for row in range(600):
        start = row * row_width * 3
        finish = start + row_width * 3
        columns = []
        for offset in range(start, min(finish, len(pixels) - 2), 3):
            red, value, blue = pixels[offset:offset + 3]
            if red >= 180 and value <= 100 and blue >= 180:
                columns.append((offset - start) // 3)
            if red <= 80 and value >= 180 and blue <= 80:
                green += 1
        row_counts.append(len(columns))
        row_spans.append(columns[-1] - columns[0] + 1 if columns else 0)
    colored_rows = [row for row, count in enumerate(row_counts) if count >= 100]
    gaps = 0
    if colored_rows:
        gaps = sum(1 for row in range(colored_rows[0], colored_rows[-1] + 1)
                   if row_counts[row] < 100)
    result = {
        "pixels": sum(row_counts),
        "row_gaps": gaps,
        "colored_rows": len(colored_rows),
        "maximum_span": max((row_spans[row] for row in colored_rows),
                            default=0),
        "green_pixels": green,
    }
    return result


def capture_frame(importer, image_tool, path):
    subprocess.run([importer, "-window", "root", str(path)],
                   cwd=ROOT, check=True, timeout=10)
    return screen_metrics(image_tool, path)


def run_backend(backend, terminal_kind, terminal, nvim, importer, image_tool,
                tmux=None):
    name = backend + "-" + terminal_kind + ("-tmux" if tmux else "")
    artifact = ROOT / ".test-data" / f"terminal-{name}-failure.png"
    artifact.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix=f"neoagent-{backend}-") as temporary:
        directory = Path(temporary)
        source = directory / "source.png"
        ready = directory / "ready"
        stop = directory / "stop"
        state = directory / "state.json"
        screenshot = directory / "screen.png"
        terminal_log = directory / "terminal.log"
        nvim_log = directory / "nvim.log"
        write_source(source, True)
        environment = os.environ.copy()
        environment.update({
            "NEOAGENT_IMAGE_SMOKE_BACKEND": backend,
            "NEOAGENT_IMAGE_SMOKE_SOURCE": str(source),
            "NEOAGENT_IMAGE_SMOKE_READY": str(ready),
            "NEOAGENT_IMAGE_SMOKE_STOP": str(stop),
            "NEOAGENT_IMAGE_SMOKE_STATE": str(state),
        })
        nvim_command = [nvim, "-u", "NONE", "-i", "NONE", "-n",
                        "-V1" + str(nvim_log),
                        "-c", "luafile tests/terminal/image_smoke.lua"]
        if tmux:
            config = directory / "tmux.conf"
            config.write_text("set -g allow-passthrough all\n"
                              "set -g default-terminal tmux-256color\n"
                              "set -g status off\n", encoding="utf-8")
            environment["TMUX_TMPDIR"] = str(directory)
            nvim_command = [tmux, "-L", "image-smoke", "-f", str(config),
                            "new-session", shlex.join(nvim_command)]
        if terminal_kind == "kitty":
            command = [terminal, "--config", "NONE",
                       "--debug-rendering",
                       "--override", "remember_window_size=no",
                       "--override", "initial_window_width=900",
                       "--override", "initial_window_height=600",
                       *nvim_command]
        elif terminal_kind == "konsole":
            command = [terminal, "--qwindowgeometry", "900x600+0+0",
                       "--separate", "--nofork",
                       "--hide-menubar", "--hide-tabbar",
                       "--notransparency", "--builtin-profile",
                       "-p", "TerminalMargin=0",
                       "-p", "ScrollBarPosition=2",
                       "-e", *nvim_command]
            dbus = executable(os.environ.get(
                "DBUS_RUN_SESSION", "dbus-run-session"))
            if dbus:
                command = [dbus, "--", *command]
        else:
            raise RuntimeError(f"unsupported terminal kind: {terminal_kind}")
        with terminal_log.open("wb") as log:
            process = subprocess.Popen(command, cwd=ROOT, env=environment,
                                       stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 15
                while not ready.is_file() and process.poll() is None:
                    if time.monotonic() >= deadline:
                        artifact.parent.mkdir(parents=True, exist_ok=True)
                        subprocess.run([importer, "-window", "root",
                                        str(artifact)], cwd=ROOT,
                                       check=False, timeout=10)
                        process.terminate()
                        process.wait(timeout=2)
                        raise RuntimeError(f"{name} did not become ready\n"
                                           + (state.read_text(
                                               encoding="utf-8",
                                               errors="replace")
                                              if state.is_file()
                                              else "missing state")
                                           + f"\ncapture: {artifact}\n"
                                           + diagnostics(log, nvim_log))
                    time.sleep(0.02)
                if process.poll() is not None:
                    raise RuntimeError(f"{name} exited before capture\n"
                                       + diagnostics(log, nvim_log))
                read_json(ready)
                renders_images = True
                deadline = time.monotonic() + 5
                frames = []
                while True:
                    time.sleep(0.1)
                    metrics = capture_frame(importer, image_tool, screenshot)
                    frames.append(("settled", screenshot, metrics))
                    if not renders_images or (metrics["pixels"] >= 3000
                                               and metrics["row_gaps"] == 0):
                        break
                    if time.monotonic() >= deadline:
                        break
                metrics = frames[-1][2]
                count, row_gaps = metrics["pixels"], metrics["row_gaps"]
                if renders_images and (count < 3000 or row_gaps > 0):
                    artifact.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(frames[-1][1], artifact)
                    raise RuntimeError(
                        f"{name} rendered {count} image-colored pixels with "
                        f"{row_gaps} interrupted image rows; "
                        f"frames: {[(label, value) for label, _, value in frames]}; "
                        f"capture: {artifact}\n"
                        + ready.read_text(encoding="utf-8", errors="replace")
                        + "\n" + (state.read_text(encoding="utf-8", errors="replace")
                                  if state.is_file() else "missing final state")
                        + "\n"
                        + diagnostics(log, nvim_log))
                stop.write_text("stop\n", encoding="utf-8")
                process.wait(timeout=5)
                messages = diagnostics(log, nvim_log)
                if process.returncode != 0:
                    raise RuntimeError(f"{name} Neovim failed\n" + messages)
                malformed = (
                    "Invalid character in CSI",
                    "Unknown char after ESC",
                    "VTE_DCS escape code too long",
                )
                if any(value in messages for value in malformed):
                    raise RuntimeError(
                        f"{name} produced malformed terminal output\n"
                        + messages)
                if "[PARSE ERROR]" in messages:
                    raise RuntimeError(f"{name} produced terminal parse errors\n"
                                       + messages)
                print(f"PASS {name}: captured {count} image-colored pixels")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=2)
                if tmux:
                    subprocess.run([tmux, "-L", "image-smoke", "kill-server"],
                                   cwd=ROOT, env=environment,
                                   stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, timeout=2)


def main():
    if os.environ.get("NEOAGENT_IMAGE_SMOKE_XVFB") != "1":
        xvfb = executable(os.environ.get("XVFB_RUN", "xvfb-run"))
        if not xvfb:
            print("SKIP terminal images: xvfb-run is unavailable")
            return 0
        environment = os.environ.copy()
        environment["NEOAGENT_IMAGE_SMOKE_XVFB"] = "1"
        command = [xvfb, "-a", "--server-args=-screen 0 1024x768x24",
                   sys.executable, str(Path(__file__).resolve())]
        return subprocess.run(command, cwd=ROOT, env=environment).returncode

    nvim = executable(os.environ.get("NEOAGENT_NVIM", "nvim"))
    importer = executable(os.environ.get("IMPORT", "import"))
    image_tool = executable(os.environ.get("MAGICK", "convert"))
    missing = [name for name, value in (
        ("nvim", nvim), ("import", importer), ("ImageMagick", image_tool)
    ) if not value]
    if missing:
        print("SKIP terminal images: unavailable " + ", ".join(missing))
        return 0

    ran = 0
    tmux = executable(os.environ.get("TMUX_BIN", "tmux"))
    kitty = executable(os.environ.get("KITTY", "kitty"))
    if kitty:
        run_backend("kitty", "kitty", kitty, nvim, importer, image_tool)
        if tmux:
            run_backend("kitty", "kitty", kitty, nvim, importer, image_tool,
                        tmux)
        ran += 1
    else:
        print("SKIP kitty image: kitty is unavailable")

    konsole = executable(os.environ.get("KONSOLE", "konsole"))
    if konsole:
        run_backend("kitty", "konsole", konsole, nvim, importer, image_tool)
        ran += 1
    else:
        print("SKIP Kitty Konsole image: Konsole is unavailable")
    if not ran:
        print("SKIP terminal images: no supported terminal backend is installed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"FAIL terminal images: {error}", file=sys.stderr)
        raise SystemExit(1)
