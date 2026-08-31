#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from image_harness import executable, terminal_command
from image_smoke import write_source


ROOT = Path(__file__).resolve().parents[2]


def diagnostics(log, nvim_log, state):
    log.flush()
    parts = [Path(log.name).read_text(
        encoding="utf-8", errors="replace")[-8000:]]
    for path in (nvim_log, state):
        if path.is_file():
            parts.append(path.read_text(
                encoding="utf-8", errors="replace")[-8000:])
    return "\n".join(parts)


def wait_for(path, process, timeout, description, log, nvim_log, state,
             predicate=lambda value: True):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(
                f"terminal exited while waiting for {description}\n"
                + diagnostics(log, nvim_log, state))
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            if value.get("phase") == "error":
                raise RuntimeError(
                    f"{description} harness failed: {value.get('error')}")
            if predicate(value):
                return value
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.01)
    raise RuntimeError(
        f"timed out waiting for {description}\n"
        + diagnostics(log, nvim_log, state))


def image_pixels(image_tool, screenshot):
    pixels = subprocess.check_output([
        image_tool, str(screenshot), "-crop", "1024x768+0+0",
        "-alpha", "off", "-depth", "8", "rgb:-",
    ], cwd=ROOT, timeout=15)
    count = 0
    for offset in range(0, len(pixels) - 2, 3):
        red, green, blue = pixels[offset:offset + 3]
        if red >= 180 and green <= 100 and blue >= 180:
            count += 1
    return count


def settled_image_pixels(importer, image_tool, screenshot, timeout=3):
    deadline = time.monotonic() + timeout
    previous = None
    stable_since = None
    while time.monotonic() < deadline:
        subprocess.run([
            importer, "-window", "root", str(screenshot),
        ], cwd=ROOT, check=True, timeout=10)
        count = image_pixels(image_tool, screenshot)
        now = time.monotonic()
        if count == previous:
            stable_since = stable_since or now
            if now - stable_since >= 0.25:
                return count
        else:
            previous = count
            stable_since = now
        time.sleep(0.01)
    raise RuntimeError(
        f"terminal image pixels did not settle: last count={previous}")


def run_case(kind, terminal, nvim, importer, image_tool):
    name = f"resume-{kind}"
    artifact = ROOT / ".test-data" / f"terminal-{name}-failure.png"
    artifact.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(
            prefix=f"neoagent-image-{name}-") as temporary:
        directory = Path(temporary)
        workspace = directory / "workspace"
        persistence = directory / "state"
        workspace.mkdir()
        persistence.mkdir()
        source = directory / "source.png"
        ready = directory / "ready.json"
        state = directory / "state.json"
        done = directory / "done.json"
        stop = directory / "stop"
        socket = directory / "nvim.sock"
        screenshot = directory / "screen.png"
        terminal_log = directory / "terminal.log"
        nvim_log = directory / "nvim.log"
        write_source(source, True)
        environment = os.environ.copy()
        environment.update({
            "NEOAGENT_IMAGE_RESUME_ROOT": str(ROOT),
            "NEOAGENT_IMAGE_RESUME_READY": str(ready),
            "NEOAGENT_IMAGE_RESUME_STATE": str(state),
            "NEOAGENT_IMAGE_RESUME_DONE": str(done),
            "NEOAGENT_IMAGE_RESUME_STOP": str(stop),
            "NEOAGENT_IMAGE_RESUME_SOURCE": str(source),
            "NEOAGENT_IMAGE_RESUME_PERSISTENCE": str(persistence),
            "NEOAGENT_IMAGE_RESUME_WORKSPACE": str(workspace),
        })
        child = [
            nvim, "-u", "NONE", "-i", "NONE", "-n",
            "--listen", str(socket),
            "-V1" + str(nvim_log),
            "-c", "luafile " + str(ROOT / "tests/terminal/image_resume.lua"),
        ]
        command = terminal_command(kind, terminal, child, directory)
        with terminal_log.open("wb") as log:
            process = subprocess.Popen(
                command, cwd=workspace, env=environment,
                stdout=log, stderr=log)
            try:
                def send(keys):
                    subprocess.run([
                        nvim, "--server", str(socket),
                        "--remote-send", keys,
                    ], cwd=ROOT, check=True, timeout=5)

                draft = wait_for(
                    state, process, 15, f"{name} open draft",
                    log, nvim_log, state,
                    lambda value: value.get("phase") == "draft"
                    and value.get("current_window")
                    == value.get("input_window"))
                if draft.get("image") is not None:
                    raise RuntimeError(
                        f"{name} draft unexpectedly contained an image: "
                        f"{draft}")
                send("<M-r>")
                wait_for(
                    state, process, 15, f"{name} resume picker",
                    log, nvim_log, state,
                    lambda value: value.get("presentation_window") is not None
                    and value.get("current_window")
                    == value.get("presentation_window"))
                send("<CR>")
                resumed = wait_for(
                    ready, process, 15, f"{name} resumed transcript",
                    log, nvim_log, state)
                if resumed.get("current_window") != resumed.get("input_window"):
                    raise RuntimeError(
                        f"{name} did not resume with composer focus: {resumed}")
                send("<M-k>")
                navigated = wait_for(
                    done, process, 15, f"{name} Alt+K navigation",
                    log, nvim_log, state)
                if navigated.get("current_window") \
                        != navigated.get("transcript_window"):
                    raise RuntimeError(
                        f"{name} Alt+K did not focus transcript: {navigated}")
                position = navigated.get("image_position") or {}
                if position.get("row") != 0:
                    raise RuntimeError(
                        f"{name} fixture image is semantically visible: "
                        f"{navigated}")
                count = settled_image_pixels(
                    importer, image_tool, screenshot)
                placements = navigated.get("placements") or []
                if placements or count >= 1000:
                    artifact.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(screenshot, artifact)
                    raise RuntimeError(
                        f"{name} placed an off-screen transcript image over "
                        f"the selected card: pixels={count}, "
                        f"placements={placements}; capture: {artifact}")
                stop.write_text("stop\n", encoding="utf-8")
                process.wait(timeout=5)
                if process.returncode != 0:
                    raise RuntimeError(
                        f"{name} Neovim failed\n"
                        + diagnostics(log, nvim_log, state))
                print(f"PASS {name}: Alt+K retained no off-screen image pixels")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=2)


def main():
    if os.environ.get("NEOAGENT_IMAGE_RESUME_XVFB") != "1":
        xvfb = executable(os.environ.get("XVFB_RUN", "xvfb-run"))
        if not xvfb:
            print("SKIP resumed terminal images: xvfb-run is unavailable")
            return 0
        environment = os.environ.copy()
        environment["NEOAGENT_IMAGE_RESUME_XVFB"] = "1"
        return subprocess.run([
            xvfb, "-a", "--server-args=-screen 0 1024x768x24",
            sys.executable, str(Path(__file__).resolve()),
        ], cwd=ROOT, env=environment).returncode

    nvim = executable(os.environ.get("NEOAGENT_NVIM", "nvim"))
    importer = executable(os.environ.get("IMPORT", "import"))
    image_tool = executable(os.environ.get("MAGICK", "convert"))
    missing = [name for name, value in (
        ("nvim", nvim), ("import", importer),
        ("ImageMagick", image_tool),
    ) if not value]
    if missing:
        print("SKIP resumed terminal images: unavailable "
              + ", ".join(missing))
        return 0

    ran = 0
    kitty = executable(os.environ.get("KITTY", "kitty"))
    if kitty:
        run_case("kitty", kitty, nvim, importer, image_tool)
        ran += 1
    else:
        print("SKIP resumed Kitty image: Kitty is unavailable")
    konsole = executable(os.environ.get("KONSOLE", "konsole"))
    if konsole:
        run_case("konsole", konsole, nvim, importer, image_tool)
        ran += 1
    else:
        print("SKIP resumed Konsole image: Konsole is unavailable")
    if not ran:
        print("SKIP resumed terminal images: no supported terminal is installed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"FAIL resumed terminal images: {error}", file=sys.stderr)
        raise SystemExit(1)
