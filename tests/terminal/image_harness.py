#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import zlib


ROOT = Path(__file__).resolve().parents[2]
SCREEN_WIDTH = 1024
SCREEN_HEIGHT = 768
PIXEL_SETTLE_SECONDS = 0.5
PIXEL_CAPTURE_TIMEOUT_SECONDS = 15


def executable(value):
    path = Path(value).expanduser()
    if path.parent != Path("."):
        return str(path) if path.is_file() and os.access(path, os.X_OK) else None
    return shutil.which(value)


def output(log):
    log.flush()
    return Path(log.name).read_text(encoding="utf-8", errors="replace")[-8000:]


def diagnostics(log, nvim_log, state):
    parts = [output(log)]
    for path in (nvim_log, state):
        if path.is_file():
            parts.append(path.read_text(
                encoding="utf-8", errors="replace")[-8000:])
    return "\n".join(parts)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def wait_for(path, predicate, process, timeout, describe, log, nvim_log,
             state_path):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(
                f"terminal exited while waiting for {describe}\n"
                + diagnostics(log, nvim_log, state_path))
        try:
            value = read_json(path)
            if predicate(value):
                return value
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.01)
    raise RuntimeError(
        f"timed out waiting for {describe}\n"
        + diagnostics(log, nvim_log, state_path))


def capture(importer, image_tool, path):
    subprocess.run([importer, "-window", "root", str(path)], cwd=ROOT,
                   check=True, timeout=10)
    pixels = subprocess.check_output([
        image_tool, str(path), "-crop",
        f"{SCREEN_WIDTH}x{SCREEN_HEIGHT}+0+0", "-alpha", "off",
        "-depth", "8", "rgb:-",
    ], cwd=ROOT, timeout=15)
    expected = SCREEN_WIDTH * SCREEN_HEIGHT * 3
    if len(pixels) != expected:
        raise RuntimeError(
            f"captured {len(pixels)} RGB bytes, expected {expected}")
    return pixels


def fixture_pixel(red, green, blue):
    maximum = max(red, green, blue)
    minimum = min(red, green, blue)
    terminal_border = green >= 145 and red <= 90 and blue <= 135
    return maximum >= 95 and maximum - minimum >= 42 and not terminal_border


def green_pixel(red, green, blue):
    return green >= 145 and red <= 90 and blue <= 135


def bounds_for(pixels, predicate):
    left, top = SCREEN_WIDTH, SCREEN_HEIGHT
    right = bottom = -1
    count = 0
    unique = set()
    for row in range(SCREEN_HEIGHT):
        start = row * SCREEN_WIDTH * 3
        for column in range(SCREEN_WIDTH):
            offset = start + column * 3
            color = tuple(pixels[offset:offset + 3])
            if predicate(*color):
                left = min(left, column)
                top = min(top, row)
                right = max(right, column)
                bottom = max(bottom, row)
                count += 1
                unique.add(color)
    return {
        "bounds": None if right < left else (left, top, right + 1, bottom + 1),
        "count": count,
        "colors": len(unique),
    }


def crop_pixels(pixels, bounds):
    left, top, right, bottom = bounds
    rows = []
    for row in range(top, bottom):
        start = (row * SCREEN_WIDTH + left) * 3
        rows.append(pixels[start:start + (right - left) * 3])
    return b"".join(rows)


def color_count(pixels):
    return len({tuple(pixels[offset:offset + 3])
                for offset in range(0, len(pixels), 3)})


def terminal_grid_origin(pixels):
    for row in range(SCREEN_HEIGHT):
        first = row * SCREEN_WIDTH * 3
        last = first + SCREEN_WIDTH * 3
        dark = sum(max(pixels[offset:offset + 3]) <= 24
                   for offset in range(first, last, 3))
        if dark >= SCREEN_WIDTH * 0.8:
            for column in range(SCREEN_WIDTH):
                offset = first + column * 3
                if max(pixels[offset:offset + 3]) <= 24:
                    return column, row
    raise RuntimeError("terminal pixel grid was not found in the capture")


def image_bounds(layer, cells, origin=(0, 0)):
    geometry = layer["geometry"]
    left = round(origin[0]
                 + (geometry["screen_col"] - 1) * cells["width"])
    top = round(origin[1]
                + (geometry["screen_row"] - 1) * cells["height"])
    width = round(geometry["columns"] * cells["width"])
    height = round(geometry["rows"] * cells["height"])
    return left, top, left + width, top + height


def difference(left, right, threshold=8, row_width=None, ignored=()):
    if len(left) != len(right):
        return {"mean": float("inf"), "changed": max(len(left), len(right))}
    total = 0
    changed = 0
    compared = 0
    for offset in range(0, len(left), 3):
        if ignored:
            pixel = offset // 3
            row, column = divmod(pixel, row_width)
            if any(x <= column < x + width and y <= row < y + height
                   for x, y, width, height in ignored):
                continue
        compared += 1
        delta = sum(abs(left[offset + channel] - right[offset + channel])
                    for channel in range(3))
        total += delta
        if delta > threshold * 3:
            changed += 1
    return {"mean": total / max(1, compared) / 3, "changed": changed}


def axis_error(left, right, width):
    if len(left) != len(right) or len(left) % (width * 3) != 0:
        return {"row": float("inf"), "column": float("inf")}
    height = len(left) // width // 3
    rows = []
    for row in range(height):
        first = row * width * 3
        last = first + width * 3
        rows.append(sum(abs(left[index] - right[index])
                        for index in range(first, last)) / width / 3)
    columns = []
    for column in range(width):
        total = 0
        for row in range(height):
            offset = (row * width + column) * 3
            total += sum(abs(left[offset + channel]
                             - right[offset + channel])
                         for channel in range(3))
        columns.append(total / height / 3)
    interior_rows = rows[8:-8] or rows
    interior_columns = columns[5:-5] or columns
    return {
        "row": max(interior_rows, default=0),
        "column": max(interior_columns, default=0),
    }


def normalized_rgb(image_tool, source, width=120, height=64):
    return subprocess.check_output([
        image_tool, str(source), "-alpha", "off", "-resize",
        f"{width}x{height}!", "-depth", "8", "rgb:-",
    ], cwd=ROOT, timeout=15)


def normalized_capture(image_tool, screenshot, bounds, width=120, height=64):
    left, top, right, bottom = bounds
    return subprocess.check_output([
        image_tool, str(screenshot), "-crop",
        f"{right - left}x{bottom - top}+{left}+{top}", "+repage",
        "-alpha", "off", "-resize", f"{width}x{height}!",
        "-depth", "8", "rgb:-",
    ], cwd=ROOT, timeout=15)


def terminal_command(kind, terminal, child, directory):
    if kind == "kitty":
        return [
            terminal, "--config", "NONE", "--debug-rendering",
            "--dump-bytes", str(directory / "terminal.bytes"),
            "--override", "remember_window_size=no",
            "--override", "initial_window_width=900",
            "--override", "initial_window_height=600",
            "--override", "cursor_blink_interval=0", *child,
        ]
    command = [
        terminal, "--qwindowgeometry", "900x600+0+0", "--separate",
        "--nofork", "--hide-menubar", "--hide-tabbar",
        "--notransparency", "--builtin-profile", "-p",
        "TerminalMargin=0", "-p", "ScrollBarPosition=2", "-e", *child,
    ]
    dbus = executable(os.environ.get("DBUS_RUN_SESSION", "dbus-run-session"))
    return [dbus, "--", *command] if dbus else command


def assert_visible(label, metrics):
    if metrics["bounds"] is None or metrics["count"] < 1000:
        raise RuntimeError(
            f"{label} has no coherent visible fixture: {metrics}")


def run_case(backend, terminal_kind, terminal, nvim, importer, image_tool,
             layout_mode="native", tmux=None):
    suffix = "-tmux" if tmux else ""
    name = (f"harness-{backend}-{terminal_kind}-{layout_mode}"
            f"{suffix}")
    artifact = ROOT / ".test-data" / f"terminal-{name}-failure.png"
    initial_artifact = (ROOT / ".test-data"
                        / f"terminal-{name}-failure-initial.png")
    terminal_log_artifact = (ROOT / ".test-data"
                             / f"terminal-{name}-failure-terminal.log")
    nvim_log_artifact = (ROOT / ".test-data"
                         / f"terminal-{name}-failure-nvim.log")
    lifecycle_artifact = (ROOT / ".test-data"
                          / f"terminal-{name}-failure-lifecycle.log")
    bytes_artifact = (ROOT / ".test-data"
                      / f"terminal-{name}-failure.tty")
    for path in (
            artifact, initial_artifact, terminal_log_artifact,
            nvim_log_artifact, lifecycle_artifact, bytes_artifact):
        path.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix=f"neoagent-{name}-") as temporary:
        directory = Path(temporary)
        ready_path = directory / "ready.json"
        state_path = directory / "state.json"
        source_path = directory / "source.png"
        frame_dir = directory / "frames"
        stop_path = directory / "stop"
        action_path = directory / "action.json"
        terminal_log = directory / "terminal.log"
        nvim_log = directory / "nvim.log"
        lifecycle_log = directory / "lifecycle.log"
        terminal_bytes = directory / "terminal.bytes"
        environment = os.environ.copy()
        environment.update({
            "NEOAGENT_IMAGE_HARNESS_BACKEND": backend,
            "NEOAGENT_IMAGE_HARNESS_LAYOUT": layout_mode,
            "NEOAGENT_IMAGE_HARNESS_READY": str(ready_path),
            "NEOAGENT_IMAGE_HARNESS_STATE": str(state_path),
            "NEOAGENT_IMAGE_HARNESS_SOURCE": str(source_path),
            "NEOAGENT_IMAGE_HARNESS_FRAME_DIR": str(frame_dir),
            "NEOAGENT_IMAGE_HARNESS_STOP": str(stop_path),
            "NEOAGENT_IMAGE_HARNESS_ACTION": str(action_path),
            "NEOAGENT_IMAGE_HARNESS_LIFECYCLE": str(lifecycle_log),
        })
        child = [
            nvim, "-u", "NONE", "-i", "NONE", "-n",
            "-V1" + str(nvim_log),
            "-c", "luafile tests/terminal/image_harness.lua",
        ]
        socket = f"image-harness-{os.getpid()}"
        if tmux:
            config = directory / "tmux.conf"
            config.write_text(
                "set -g allow-passthrough all\n"
                "set -g default-terminal tmux-256color\n"
                "set -g status off\n", encoding="utf-8")
            environment["TMUX_TMPDIR"] = str(directory)
            child = [
                tmux, "-L", socket, "-f", str(config), "new-session",
                shlex.join(child),
            ]
        command = terminal_command(terminal_kind, terminal, child, directory)
        action_id = 0
        screenshots = []
        with terminal_log.open("wb") as log:
            process = subprocess.Popen(
                command, cwd=ROOT, env=environment, stdout=log, stderr=log)
            try:
                ready = wait_for(
                    ready_path,
                    lambda value: value.get("centered")
                    and value.get("settled") and value.get("visible"),
                    process, 20, f"{name} initial settled frame", log,
                    nvim_log, state_path)
                def settled_capture(label, expected_visible=None,
                                    state_override=None):
                    nonlocal action_id
                    if state_override is not None:
                        state = state_override
                    elif action_id:
                        state = wait_for(
                            state_path,
                            lambda value: value.get("action") == action_id
                            and value.get("settled") is True,
                            process, 12, f"{name} action {action_id} ({label})",
                            log, nvim_log, state_path)
                    else:
                        state = ready
                    if expected_visible is not None \
                            and state.get("visible") is not expected_visible:
                        raise RuntimeError(
                            f"{name} {label} visibility is "
                            f"{state.get('visible')}, expected "
                            f"{expected_visible}: {state}")
                    deadline = time.monotonic() + PIXEL_CAPTURE_TIMEOUT_SECONDS
                    previous = None
                    stable_since = None
                    attempt = 0
                    while True:
                        time.sleep(0.1)
                        path = directory / (
                            f"{action_id:02d}-{label}-{attempt}.png")
                        pixels = capture(importer, image_tool, path)
                        fixture = bounds_for(pixels, fixture_pixel)
                        green = bounds_for(pixels, green_pixel)
                        visible_pixels = (fixture["bounds"] is not None
                                          and fixture["count"] >= 1000)
                        stable = previous is not None
                        if visible_pixels and stable:
                            delta = difference(previous, pixels, threshold=2)
                            stable = (delta["mean"] <= 0.05
                                      and delta["changed"] <= 1000)
                        if visible_pixels and stable:
                            stable_since = stable_since or time.monotonic()
                        else:
                            stable_since = None
                        if stable_since is not None and time.monotonic() \
                                - stable_since >= PIXEL_SETTLE_SECONDS:
                            break
                        if time.monotonic() >= deadline:
                            screenshots.append(
                                (label, path, pixels, fixture, state))
                            raise RuntimeError(
                                f"{name} {label} did not reach a stable "
                                f"settled frame: fixture={fixture}, "
                                f"expected_visible={expected_visible}")
                        previous = pixels
                        attempt += 1
                    screenshots.append((label, path, pixels, fixture, state))
                    return path, pixels, fixture, green, state

                def send(keys):
                    nonlocal action_id
                    action_id += 1
                    temporary_action = directory / "action.next"
                    temporary_action.write_text(json.dumps({
                        "id": action_id, "keys": keys,
                    }), encoding="utf-8")
                    os.replace(temporary_action, action_path)
                    return action_id

                def move(keys, label, expected_visible=None):
                    send(keys)
                    return settled_capture(label, expected_visible)

                initial_path, initial_pixels, initial, green, initial_state = \
                    settled_capture("center", True)
                assert_visible(name + " center", initial)
                if green["bounds"] is None or green["count"] < 200:
                    raise RuntimeError(
                        f"{name} floating border is incomplete: {green}")
                source_colors = int(subprocess.check_output([
                    image_tool, str(source_path), "-format", "%k", "info:",
                ], cwd=ROOT, text=True, timeout=15).strip())
                if source_colors <= 256:
                    raise RuntimeError(
                        f"{name} fixture has only {source_colors} colors")
                image = initial_state["image"]
                window = initial_state["window"]
                cells = initial_state["cells"]
                screen_cells = {
                    "width": round(cells["width"]),
                    "height": round(cells["height"]),
                }
                gutter = initial_state["horizontal_gutter"]
                layers = initial_state["layers"]
                for layer_name in ("main", "detail", "badge"):
                    layer = layers[layer_name]
                    if not layer["open"] or not layer["visible"] \
                            or not layer["geometry"]:
                        raise RuntimeError(
                            f"{name} did not settle the {layer_name} "
                            f"image layer: {layer}")
                if image["col"] - initial_state["view"]["leftcol"] \
                        != gutter:
                    raise RuntimeError(
                        f"{name} did not center the image with its text "
                        f"gutter: {initial_state}")
                border_bounds = green["bounds"]
                terminal_origin = terminal_grid_origin(initial_pixels)
                reference_layer = layers["badge"]
                reference_bounds = image_bounds(
                    reference_layer, screen_cells, terminal_origin)
                left, top, right, bottom = reference_bounds
                if left < 0 or top < 0 or right > SCREEN_WIDTH \
                        or bottom > SCREEN_HEIGHT:
                    raise RuntimeError(
                        f"{name} reference image is outside the capture: "
                        f"{reference_bounds}")
                expected_width = round(
                    reference_layer["image"]["width"] * cells["width"])
                if abs((right - left) - expected_width) > 1:
                    raise RuntimeError(
                        f"{name} reference image width is {right - left}px, "
                        f"expected {expected_width}px: {reference_layer}")

                source_normal = normalized_rgb(image_tool, source_path)
                rendered_normal = normalized_capture(
                    image_tool, initial_path, reference_bounds)
                source_difference = difference(source_normal, rendered_normal)
                band_error = axis_error(source_normal, rendered_normal, 120)
                band_limit = source_difference["mean"] + 25
                if band_error["row"] > band_limit \
                        or band_error["column"] > band_limit:
                    raise RuntimeError(
                        f"{name} contains a row or column artifact: "
                        f"{band_error}, limit={band_limit:.2f}")
                rendered_colors = color_count(
                    crop_pixels(initial_pixels, reference_bounds))
                if source_difference["mean"] > 35:
                    raise RuntimeError(
                        f"{name} differs from source: {source_difference}")
                if rendered_colors <= 256:
                    raise RuntimeError(
                        f"{name} reduced true-color fixture to "
                        f"{rendered_colors} colors")
                baseline_float = crop_pixels(initial_pixels, border_bounds)

                def assert_center(label, result):
                    _, pixels, metrics, current_green, state = result
                    assert_visible(name + " " + label, metrics)
                    if state["view"]["topline"] \
                            != initial_state["view"]["topline"] \
                            or state["view"]["leftcol"] \
                            != initial_state["view"]["leftcol"]:
                        raise RuntimeError(
                            f"{name} {label} did not return to center: "
                            f"{state['view']} != {initial_state['view']}")
                    if current_green["bounds"] != border_bounds:
                        raise RuntimeError(
                            f"{name} {label} moved or damaged its border: "
                            f"{current_green}")
                    current_float = crop_pixels(pixels, border_bounds)
                    ignored = ()
                    delta = difference(
                        baseline_float, current_float,
                        row_width=border_bounds[2] - border_bounds[0],
                        ignored=ignored)
                    area = ((border_bounds[2] - border_bounds[0])
                            * (border_bounds[3] - border_bounds[1]))
                    if delta["mean"] > 0.8 or delta["changed"] > area * 0.005:
                        recent = [
                            (name, captured.get("view"),
                             captured.get("geometry"))
                            for name, _, _, _, captured in screenshots[-3:]
                        ]
                        raise RuntimeError(
                            f"{name} {label} did not restore its settled "
                            f"baseline: {delta}; recent states: {recent}")

                frame_sources = [frame_dir / f"{index}.png"
                                 for index in range(1, 4)]
                if not all(path.is_file() for path in frame_sources):
                    raise RuntimeError(
                        f"{name} did not publish every animation fixture")

                def assert_frame(label, result, frame_index):
                    path, pixels, _, _, state = result
                    frame = state.get("frame") or {}
                    if frame.get("index") != frame_index \
                            or frame.get("pending") is not False:
                        raise RuntimeError(
                            f"{name} {label} settled the wrong frame: "
                            f"{frame}")
                    if state.get("image_stats", {}).get(
                            "pending_preparations") != 0:
                        raise RuntimeError(
                            f"{name} {label} retained pending source work: "
                            f"{state.get('image_stats')}")
                    for layer_name, layer in state["layers"].items():
                        if layer["open"] and layer["visible"] \
                                and layer.get("source_identity") \
                                != frame.get("source_identity"):
                            raise RuntimeError(
                                f"{name} {label} retained stale "
                                f"{layer_name} source state: {layer}")
                    expected = normalized_rgb(
                        image_tool, frame_sources[frame_index - 1])
                    rendered = normalized_capture(
                        image_tool, path, reference_bounds)
                    delta = difference(expected, rendered)
                    if delta["mean"] > 35:
                        raise RuntimeError(
                            f"{name} {label} differs from frame "
                            f"{frame_index}: {delta}")
                    return pixels, rendered, state

                pending_action = send("p")
                pending_state = wait_for(
                    state_path,
                    lambda value: value.get("frame", {}).get("pending")
                    and value.get("frame", {}).get("index") == 2
                    and value.get("action", 0) < pending_action
                    and value.get("image_stats", {}).get(
                        "pending_preparations") == 1
                    and all(
                        not layer.get("open") or not layer.get("visible")
                        or layer.get("source_identity")
                        == initial_state["layers"][layer_name]
                        .get("source_identity")
                        and layer.get("fragments")
                        == initial_state["layers"][layer_name]
                        .get("fragments")
                        for layer_name, layer
                        in value.get("layers", {}).items()),
                    process, 5, f"{name} held replacement", log,
                    nvim_log, state_path)
                pending_result = settled_capture(
                    "frame-pending", True, pending_state)
                pending_float = crop_pixels(
                    pending_result[1], border_bounds)
                pending_delta = difference(baseline_float, pending_float)
                pending_area = ((border_bounds[2] - border_bounds[0])
                                * (border_bounds[3] - border_bounds[1]))
                if pending_delta["mean"] > 0.2 \
                        or pending_delta["changed"] > pending_area * 0.001:
                    raise RuntimeError(
                        f"{name} exposed fallback pixels while frame 2 "
                        f"prepared: {pending_delta}")

                frame_two = move("u", "frame-two", True)
                frame_two_pixels, frame_two_normal, frame_two_state = \
                    assert_frame("frame-two", frame_two, 2)
                initial_to_two = difference(source_normal, frame_two_normal)
                if initial_to_two["mean"] < 12:
                    raise RuntimeError(
                        f"{name} frame 2 is not visually distinct: "
                        f"{initial_to_two}")

                before_cancel = frame_two_state["image_stats"]
                superseded_action = send("p")
                wait_for(
                    state_path,
                    lambda value: value.get("frame", {}).get("pending")
                    and value.get("frame", {}).get("index") == 3
                    and value.get("action", 0) < superseded_action
                    and value.get("image_stats", {}).get(
                        "pending_preparations") == 1
                    and all(
                        not layer.get("open") or not layer.get("visible")
                        or layer.get("source_identity")
                        == frame_two_state["layers"][layer_name]
                        .get("source_identity")
                        for layer_name, layer
                        in value.get("layers", {}).items()),
                    process, 5, f"{name} superseded replacement", log,
                    nvim_log, state_path)
                cancelled_frame = move("r", "frame-cancelled", True)
                _, _, cancelled_state = assert_frame(
                    "frame-cancelled", cancelled_frame, 1)
                assert_center("frame-cancelled", cancelled_frame)
                cancelled_stats = cancelled_state["image_stats"]
                if cancelled_stats["cancelled_preparations"] \
                        != before_cancel["cancelled_preparations"] + 1:
                    raise RuntimeError(
                        f"{name} did not cancel the superseded frame: "
                        f"{before_cancel} -> {cancelled_stats}")
                if cancelled_stats["preparations"] \
                        != before_cancel["preparations"] + 1:
                    raise RuntimeError(
                        f"{name} prepared the superseded held frame: "
                        f"{before_cancel} -> {cancelled_stats}")

                preparations = cancelled_stats["preparations"]
                frame_three = move("A", "frame-churn", True)
                frame_three_pixels, frame_three_normal, frame_three_state = \
                    assert_frame("frame-churn", frame_three, 3)
                if frame_three_state["image_stats"]["preparations"] \
                        != preparations + 1:
                    raise RuntimeError(
                        f"{name} prepared intermediate rapid revisions: "
                        f"{preparations} -> "
                        f"{frame_three_state['image_stats']}")
                two_to_three = difference(
                    frame_two_normal, frame_three_normal)
                if two_to_three["mean"] < 12:
                    raise RuntimeError(
                        f"{name} rapid churn did not present frame 3: "
                        f"{two_to_three}")
                if difference(frame_two_pixels, frame_three_pixels)["mean"] \
                        < 1:
                    raise RuntimeError(
                        f"{name} rapid churn left the terminal unchanged")

                reset = move("r", "frame-reset", True)
                assert_frame("frame-reset", reset, 1)
                assert_center("frame-reset", reset)

                vertical = max(2, image["height"] // 3)
                horizontal = max(2, image["width"] // 4)

                detail_off_left = round(
                    layers["detail"]["config"]["col"]
                    + layers["detail"]["config"]["width"] + 4)
                outside = move(f"{detail_off_left}H", "detail-off-left")
                if outside[4]["layers"]["detail"]["config"]["col"] >= 0:
                    raise RuntimeError(
                        f"{name} did not move the detail layer outside "
                        f"the editor: {outside[4]['layers']['detail']}")
                assert_center("detail-off-left-return", move(
                    f"{detail_off_left}L", "detail-off-left-return", True))

                partial_down = move(f"{vertical}j", "count-j", True)
                assert_visible(name + " count-j", partial_down[2])
                assert_center("count-jk", move(
                    f"{vertical}k", "count-jk", True))
                partial_up = move(f"{vertical}k", "count-k", True)
                assert_visible(name + " count-k", partial_up[2])
                assert_center("count-kj", move(
                    f"{vertical}j", "count-kj", True))
                partial_left = move(f"{horizontal}l", "count-l", True)
                assert_visible(name + " count-l", partial_left[2])
                assert_center("count-lh", move(
                    f"{horizontal}h", "count-lh", True))
                partial_right = move(f"{horizontal}h", "count-h", True)
                assert_visible(name + " count-h", partial_right[2])
                assert_center("count-hl", move(
                    f"{horizontal}l", "count-hl", True))

                rapid_vertical = max(4, min(16, vertical))
                rapid_horizontal = max(4, min(24, horizontal))
                move("j" * rapid_vertical, "rapid-j", True)
                assert_center("rapid-jk", move(
                    "k" * rapid_vertical, "rapid-jk", True))
                move("l" * rapid_horizontal, "rapid-l", True)
                assert_center("rapid-lh", move(
                    "h" * rapid_horizontal, "rapid-lh", True))
                assert_center("rapid-jk-reversal", move(
                    "jk" * 24, "rapid-jk-reversal", True))
                assert_center("rapid-hl-reversal", move(
                    "hl" * 32, "rapid-hl-reversal", True))
                compound = (
                    "j" * rapid_vertical + "k" * rapid_vertical
                    + "l" * rapid_horizontal + "h" * rapid_horizontal
                    + "jk" * 24 + "hl" * 32
                    + "<M-j><M-j><M-k><M-k>"
                )
                assert_center("compound-rapid-reversal", move(
                    compound, "compound-rapid-reversal", True))
                move("<M-j><M-j>", "rapid-alt-j")
                assert_center("rapid-alt-jk", move(
                    "<M-k><M-k>", "rapid-alt-jk", True))
                assert_center("full-redraw", move(
                    ":redraw!<CR>", "full-redraw", True))

                detail_vertical = max(3, layers["detail"]["image"]["height"] // 3)
                detail_horizontal = max(4, layers["detail"]["image"]["width"] // 4)
                move(f"{detail_vertical}J", "detail-count-j")
                assert_center("detail-count-jk", move(
                    f"{detail_vertical}K", "detail-count-jk", True))
                move(f"{detail_horizontal}L", "detail-count-l")
                assert_center("detail-count-lh", move(
                    f"{detail_horizontal}H", "detail-count-lh", True))
                assert_center("detail-rapid-reversal", move(
                    "JK" * 20 + "LH" * 24,
                    "detail-rapid-reversal", True))

                badge_vertical = max(3, layers["badge"]["image"]["height"] // 2)
                badge_horizontal = max(4, layers["badge"]["image"]["width"] // 3)
                move(f"{badge_vertical}gj", "badge-count-j")
                assert_center("badge-count-jk", move(
                    f"{badge_vertical}gk", "badge-count-jk", True))
                move(f"{badge_horizontal}gl", "badge-count-l")
                assert_center("badge-count-lh", move(
                    f"{badge_horizontal}gh", "badge-count-lh", True))
                assert_center("badge-rapid-reversal", move(
                    "gjgk" * 16 + "glgh" * 20,
                    "badge-rapid-reversal", True))

                detail_closed = move("e", "detail-close")
                if detail_closed[4]["layers"]["detail"]["open"]:
                    raise RuntimeError(f"{name} did not close the detail layer")
                assert_center("detail-reopen", move(
                    "e", "detail-reopen", True))
                badge_closed = move("t", "badge-close")
                if badge_closed[4]["layers"]["badge"]["open"]:
                    raise RuntimeError(f"{name} did not close the badge layer")
                assert_center("badge-reopen", move(
                    "t", "badge-reopen", True))
                assert_center("detail-toggle-churn", move(
                    "eeee", "detail-toggle-churn", True))
                assert_center("badge-toggle-churn", move(
                    "tttt", "badge-toggle-churn", True))

                move("e", "detail-close-before-scroll")
                move(f"{vertical}j", "scroll-under-closed-detail", True)
                move("e", "detail-open-over-scrolled-image")
                assert_center("detail-scroll-lifecycle", move(
                    f"{vertical}k", "detail-scroll-lifecycle", True))

                first_row = initial_state["view"]["topline"] - 1
                image_row = image["row"]
                relative_row = image_row - first_row
                off_above = relative_row + image["height"]
                off_below = window["height"] - relative_row
                off_left = (image["col"] + image["width"]
                            - initial_state["view"]["leftcol"])
                off_right = initial_state["view"]["leftcol"]

                move(f"{off_above}j", "off-top", False)
                assert_center("off-top-return", move(
                    f"{off_above}k", "off-top-return", True))
                move(f"{off_below}k", "off-bottom", False)
                assert_center("off-bottom-return", move(
                    f"{off_below}j", "off-bottom-return", True))
                move(f"{off_left}l", "off-left", False)
                assert_center("off-left-return", move(
                    f"{off_left}h", "off-left-return", True))
                move(f"{off_right}h", "off-right", False)
                assert_center("off-right-return", move(
                    f"{off_right}l", "off-right-return", True))

                stop_path.write_text("stop\n", encoding="utf-8")
                process.wait(timeout=8)
                messages = diagnostics(log, nvim_log, state_path)
                if process.returncode != 0:
                    raise RuntimeError(f"{name} Neovim failed\n{messages}")
                malformed = (
                    "Invalid character in CSI", "Unknown char after ESC",
                    "VTE_DCS escape code too long", "[PARSE ERROR]",
                )
                if any(value in messages for value in malformed):
                    raise RuntimeError(
                        f"{name} produced malformed terminal output\n"
                        + messages)
                print(
                    f"PASS {name}: {len(screenshots)} settled frames, "
                    f"{initial['colors']} rendered colors, source MAE "
                    f"{source_difference['mean']:.2f}")
                frame_width = border_bounds[2] - border_bounds[0]
                frame_height = border_bounds[3] - border_bounds[1]
                return {
                    "width": frame_width,
                    "height": frame_height,
                    "frames": {
                        label: zlib.compress(
                            crop_pixels(pixels, border_bounds), 1)
                        for label, _, pixels, _, _ in screenshots
                    },
                    "states": {
                        label: state
                        for label, _, _, _, state in screenshots
                    },
                }
            except Exception as error:
                artifact.parent.mkdir(parents=True, exist_ok=True)
                for source, target in (
                        (terminal_log, terminal_log_artifact),
                        (nvim_log, nvim_log_artifact),
                        (lifecycle_log, lifecycle_artifact),
                        (terminal_bytes, bytes_artifact)):
                    if source.is_file():
                        shutil.copyfile(source, target)
                if screenshots:
                    shutil.copyfile(screenshots[-1][1], artifact)
                    shutil.copyfile(screenshots[0][1], initial_artifact)
                else:
                    subprocess.run(
                        [importer, "-window", "root", str(artifact)],
                        cwd=ROOT, check=False, timeout=10)
                raise RuntimeError(
                    f"{name} failed: {error}; return code: "
                    f"{process.poll()}; capture: {artifact}; logs: "
                    f"{terminal_log_artifact}, {nvim_log_artifact}, "
                    f"{lifecycle_artifact}, {bytes_artifact}\n"
                    + diagnostics(log, nvim_log, state_path))
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=2)
                if tmux:
                    subprocess.run(
                        [tmux, "-L", socket, "kill-server"], cwd=ROOT,
                        env=environment, stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL, timeout=2)


def compare_layout_modes(label, native, pane):
    if native["width"] != pane["width"] \
            or native["height"] != pane["height"]:
        raise RuntimeError(
            f"{label} layout modes use different fixture bounds: "
            f"{native['width']}x{native['height']} and "
            f"{pane['width']}x{pane['height']}")
    if native["frames"].keys() != pane["frames"].keys():
        raise RuntimeError(f"{label} layout modes captured different frames")
    if native["states"].keys() != pane["states"].keys():
        raise RuntimeError(f"{label} layout modes captured different states")

    def overlays_fit_stage(state):
        layers = state["layers"]
        main = layers["main"]["config"]
        for name in ("detail", "badge"):
            layer = layers[name]
            if not layer["open"]:
                continue
            config = layer["config"]
            row = config["row"] - main["row"] - 1
            column = config["col"] - main["col"] - 1
            if row < 0 or column < 0 \
                    or row + config["height"] + 2 > main["height"] \
                    or column + config["width"] + 2 > main["width"]:
                return False
        return True

    area = native["width"] * native["height"]
    worst = ("", {"mean": 0, "changed": 0})
    compared = 0
    for frame in native["frames"]:
        # Neovim floats clip to the editor. Pane layers clip to their parent
        # container. Frames outside the common clipping domain are validated
        # by each mode's settled-frame and baseline-restoration assertions.
        if not overlays_fit_stage(pane["states"][frame]):
            continue
        compared += 1
        native_pixels = zlib.decompress(native["frames"][frame])
        pane_pixels = zlib.decompress(pane["frames"][frame])
        delta = difference(
            native_pixels, pane_pixels, threshold=2)
        if delta["mean"] > worst[1]["mean"]:
            worst = (frame, delta)
        if delta["mean"] > 0.8 or delta["changed"] > area * 0.005:
            directory = ROOT / ".test-data"
            directory.mkdir(parents=True, exist_ok=True)
            stem = "terminal-layout-" + "".join(
                character.lower() if character.isalnum() else "-"
                for character in label).strip("-")
            for mode, pixels in (
                    ("native", native_pixels), ("pane", pane_pixels)):
                (directory / f"{stem}-{frame}-{mode}.ppm").write_bytes(
                    (f"P6\n{native['width']} {native['height']}\n255\n"
                     .encode("ascii") + pixels))
            raise RuntimeError(
                f"{label} {frame} differs between native and Pane "
                f"layout: {delta}; captures: {directory / stem}-"
                f"{frame}-{{native,pane}}.ppm")
    if compared < len(native["frames"]) - 4:
        raise RuntimeError(
            f"{label} compared only {compared} of "
            f"{len(native['frames'])} frames")
    print(
        f"PASS {label} layout equivalence: "
        f"{compared} common-domain frames, worst {worst[0]} "
        f"MAE {worst[1]['mean']:.2f}")


def main():
    if os.environ.get("NEOAGENT_IMAGE_HARNESS_XVFB") != "1":
        xvfb = executable(os.environ.get("XVFB_RUN", "xvfb-run"))
        if not xvfb:
            print("SKIP terminal image harness: xvfb-run is unavailable")
            return 0
        environment = os.environ.copy()
        environment["NEOAGENT_IMAGE_HARNESS_XVFB"] = "1"
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
        print("SKIP terminal image harness: unavailable " + ", ".join(missing))
        return 0

    kitty = executable(os.environ.get("KITTY", "kitty"))
    konsole = executable(os.environ.get("KONSOLE", "konsole"))
    tmux = executable(os.environ.get("TMUX", "tmux"))
    ran = 0
    if kitty:
        native = run_case(
            "kitty", "kitty", kitty, nvim, importer, image_tool,
            layout_mode="native")
        pane = run_case(
            "kitty", "kitty", kitty, nvim, importer, image_tool,
            layout_mode="pane")
        compare_layout_modes("Kitty protocol in Kitty", native, pane)
        ran += 2
        if tmux:
            tmux_native = run_case(
                "kitty", "kitty", kitty, nvim, importer, image_tool,
                layout_mode="native", tmux=tmux)
            tmux_pane = run_case(
                "kitty", "kitty", kitty, nvim, importer, image_tool,
                layout_mode="pane", tmux=tmux)
            compare_layout_modes(
                "Kitty protocol through tmux", tmux_native, tmux_pane)
            ran += 2
        else:
            print("SKIP Kitty tmux image harness: tmux is unavailable")
    else:
        print("SKIP Kitty image harness: kitty is unavailable")
    if konsole:
        native = run_case(
            "kitty", "konsole", konsole, nvim, importer, image_tool,
            layout_mode="native")
        pane = run_case(
            "kitty", "konsole", konsole, nvim, importer, image_tool,
            layout_mode="pane")
        compare_layout_modes("Kitty protocol in Konsole", native, pane)
        ran += 2
    else:
        print("SKIP Kitty Konsole image harness: Konsole is unavailable")
    if not ran:
        print("SKIP terminal image harness: no visual backend is installed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"FAIL terminal image harness: {error}", file=sys.stderr)
        raise SystemExit(1)
