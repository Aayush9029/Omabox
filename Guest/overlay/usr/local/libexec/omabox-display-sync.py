#!/usr/bin/env python3

import ctypes
import json
import math
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import time


DRM_MODE_TYPE_PREFERRED = 1 << 3
COMMAND_TIMEOUT = 10.0
STARTUP_TIMEOUT = 20.0
MAX_EVENT_LINE = 8192
MODE_FIELDS = (
    "clock", "hdisplay", "hsync_start", "hsync_end", "htotal", "hskew",
    "vdisplay", "vsync_start", "vsync_end", "vtotal", "vscan",
    "vrefresh", "flags", "type",
)


# ABI: https://gitlab.freedesktop.org/mesa/drm/-/blob/main/xf86drmMode.h
class DRMModeInfo(ctypes.Structure):
    _fields_ = [
        ("clock", ctypes.c_uint32),
        *[(name, ctypes.c_uint16) for name in MODE_FIELDS[1:11]],
        ("vrefresh", ctypes.c_uint32),
        ("flags", ctypes.c_uint32),
        ("type", ctypes.c_uint32),
        ("name", ctypes.c_char * 32),
    ]


class DRMConnector(ctypes.Structure):
    _fields_ = [
        ("connector_id", ctypes.c_uint32),
        ("encoder_id", ctypes.c_uint32),
        ("connector_type", ctypes.c_uint32),
        ("connector_type_id", ctypes.c_uint32),
        ("connection", ctypes.c_int),
        ("mmWidth", ctypes.c_uint32),
        ("mmHeight", ctypes.c_uint32),
        ("subpixel", ctypes.c_int),
        ("count_modes", ctypes.c_int),
        ("modes", ctypes.POINTER(DRMModeInfo)),
        ("count_props", ctypes.c_int),
        ("props", ctypes.POINTER(ctypes.c_uint32)),
        ("prop_values", ctypes.POINTER(ctypes.c_uint64)),
        ("count_encoders", ctypes.c_int),
        ("encoders", ctypes.POINTER(ctypes.c_uint32)),
    ]


class DRMReader:
    def __init__(self):
        if ctypes.sizeof(DRMModeInfo) != 68 or ctypes.sizeof(DRMConnector) != 88:
            raise RuntimeError("Unsupported libdrm ABI")
        self.library = ctypes.CDLL("libdrm.so.2", use_errno=True)
        self.library.drmModeGetConnector.argtypes = [ctypes.c_int, ctypes.c_uint32]
        self.library.drmModeGetConnector.restype = ctypes.POINTER(DRMConnector)
        self.library.drmModeFreeConnector.argtypes = [ctypes.POINTER(DRMConnector)]
        self.library.drmModeFreeConnector.restype = None

    def preferred_mode(self, card, connector_path):
        connector_id = int((connector_path / "connector_id").read_text().strip())
        if not 0 < connector_id <= 0xFFFFFFFF:
            raise ValueError("Invalid DRM connector ID")
        descriptor = os.open(card, os.O_RDONLY | os.O_CLOEXEC)
        connector = None
        try:
            connector = self.library.drmModeGetConnector(descriptor, connector_id)
            if not connector:
                raise OSError("Cannot read DRM connector")
            info = connector.contents
            if info.connection != 1 or info.connector_id != connector_id:
                raise ValueError("DRM connector is not connected")
            if not 0 < info.count_modes <= 1024 or not info.modes:
                raise ValueError("Invalid DRM mode list")
            for index in range(info.count_modes):
                mode = info.modes[index]
                if mode.type & DRM_MODE_TYPE_PREFERRED:
                    return {name: int(getattr(mode, name)) for name in MODE_FIELDS}
            raise ValueError("No preferred DRM mode")
        finally:
            try:
                if connector:
                    self.library.drmModeFreeConnector(connector)
            finally:
                os.close(descriptor)


def modeline(mode):
    if any(type(mode.get(name)) is not int or mode[name] < 0 for name in MODE_FIELDS):
        raise ValueError("Invalid numeric mode fields")
    if not 64 <= mode["hdisplay"] <= 8192 or not 64 <= mode["vdisplay"] <= 8192:
        raise ValueError("Unsupported preferred dimensions")
    if not 1000 <= mode["clock"] <= 4_000_000:
        raise ValueError("Invalid preferred pixel clock")
    for prefix in ("h", "v"):
        if not (
            mode[f"{prefix}display"] < mode[f"{prefix}sync_start"]
            < mode[f"{prefix}sync_end"] <= mode[f"{prefix}total"] <= 65535
        ):
            raise ValueError("Invalid preferred sync timings")
    flags = mode["flags"]
    if flags & ~0xF or flags & 3 not in (1, 2) or flags & 12 not in (4, 8):
        raise ValueError("Unsupported preferred sync flags")
    if mode["hskew"] or mode["vscan"] not in (0, 1):
        raise ValueError("Unsupported preferred scan parameters")

    # Hyprland 0.56 converts MHz to an integer before multiplying by 1000.
    clock_mhz = (mode["clock"] + 500) // 1000
    timing = [mode[name] for name in (
        "hdisplay", "hsync_start", "hsync_end", "htotal",
        "vdisplay", "vsync_start", "vsync_end", "vtotal",
    )]
    hsync = "+hsync" if flags & 1 else "-hsync"
    vsync = "+vsync" if flags & 4 else "-vsync"
    return " ".join(["modeline", str(clock_mhz), *map(str, timing), hsync, vsync])


def validated_scale(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("Invalid display scale")
    if not 0.25 <= value <= 4 or not math.isfinite(value):
        raise ValueError("Unsupported display scale")
    return float(value)


def parse_dynamic_resolution(text, enabled=True):
    for line in text.splitlines():
        if line == "OMABOX_DYNAMIC_RESOLUTION=0":
            enabled = False
        elif line == "OMABOX_DYNAMIC_RESOLUTION=1":
            enabled = True
    return enabled


def dynamic_resolution_enabled(path, host_path=Path("/mnt/omabox-config/desktop.env")):
    enabled = True
    for settings in (path, host_path):
        try:
            with settings.open("r", encoding="utf-8") as source:
                text = source.read(32769)
        except FileNotFoundError:
            continue
        if len(text) > 32768:
            raise ValueError("Display settings exceed the size limit")
        enabled = parse_dynamic_resolution(text, enabled)
    return enabled


class HotplugDebouncer:
    def __init__(self):
        self.deadline = None
        self.first_event = None
        self.action = None
        self.hotplug = None

    def feed(self, line, now):
        if len(line) > MAX_EVENT_LINE:
            self.action = self.hotplug = None
        elif not line:
            if self.action == "change" and self.hotplug == "1":
                if self.first_event is None:
                    self.first_event = now
                self.deadline = min(now + 0.12, self.first_event + 0.5)
            self.action = self.hotplug = None
        elif line.startswith("ACTION="):
            self.action = line[7:]
        elif line.startswith("HOTPLUG="):
            self.hotplug = line[8:]

    def pop_due(self, now):
        if self.deadline is None or now < self.deadline:
            return False
        self.deadline = self.first_event = None
        return True


class UdevReader:
    def __init__(self, descriptor, debouncer):
        self.descriptor = descriptor
        self.debouncer = debouncer
        self.buffer = b""
        self.discarding = False
        self.ready = False

    def read_available(self):
        consumed = 0
        while consumed < 65536:
            try:
                data = os.read(self.descriptor, 16384)
            except BlockingIOError:
                return
            if not data:
                raise RuntimeError("Display event monitor stopped")
            consumed += len(data)
            chunks = (self.buffer + data).split(b"\n")
            self.buffer = chunks.pop()
            for chunk in chunks:
                if not self.discarding:
                    line = chunk.decode("ascii", errors="replace").rstrip("\r")
                    if line.startswith("UDEV - ") or line.startswith("UDEV  ["):
                        self.ready = True
                    self.debouncer.feed(line, time.monotonic())
                self.discarding = False
            if len(self.buffer) > MAX_EVENT_LINE:
                self.buffer = b""
                self.discarding = True
                self.debouncer.action = self.debouncer.hotplug = None


def hyprctl(*arguments, environment=None, deadline=None):
    timeout = COMMAND_TIMEOUT if deadline is None else min(COMMAND_TIMEOUT, deadline - time.monotonic())
    if timeout <= 0:
        raise TimeoutError("Display startup timed out")
    return subprocess.run(
        ["hyprctl", *arguments], check=True, text=True, env=environment,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=timeout,
    ).stdout.strip()


def hyprland_environment(deadline=None):
    environment = dict(os.environ)
    signature = environment.get("HYPRLAND_INSTANCE_SIGNATURE")
    if not signature:
        instances = json.loads(hyprctl("instances", "-j", environment=environment, deadline=deadline))
        if not isinstance(instances, list):
            raise ValueError("Invalid compositor instance list")
        if len(instances) > 1:
            instances = [instance for instance in instances if isinstance(instance, dict)
                         and instance.get("wl_socket") == environment.get("WAYLAND_DISPLAY")]
        if len(instances) != 1 or not isinstance(instances[0], dict):
            raise RuntimeError("Compositor instance is not ready")
        signature = instances[0].get("instance")
    if not isinstance(signature, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,256}", signature):
        raise ValueError("Invalid compositor instance")
    environment["HYPRLAND_INSTANCE_SIGNATURE"] = signature
    return environment


class DisplaySynchronizer:
    def __init__(self, settings_path=None, drm_root=Path("/sys/class/drm"), reader=None):
        self.settings_path = settings_path or Path.home() / ".config/omabox/desktop.env"
        self.drm_root = drm_root
        self.reader = reader or DRMReader()
        self.environment = None
        self.last_applied = {}

    def monitors(self, deadline=None):
        result = json.loads(hyprctl("monitors", "-j", environment=self.environment, deadline=deadline))
        if not isinstance(result, list) or not result or any(not isinstance(item, dict) for item in result):
            raise RuntimeError("Compositor outputs are not ready")
        return result

    def update(self, deadline=None):
        if not dynamic_resolution_enabled(self.settings_path):
            self.last_applied.clear()
            return
        if self.environment is None:
            self.environment = hyprland_environment(deadline)
        monitors = self.monitors(deadline)
        outputs = []
        for connector in sorted(self.drm_root.glob("card*-Virtual-*")):
            match = re.fullmatch(r"(card[0-9]+)-(Virtual-[0-9]+)", connector.name)
            if not match or (connector / "status").read_text().strip() != "connected":
                continue
            matches = [monitor for monitor in monitors if monitor.get("name") == match[2]]
            if len(matches) == 1:
                outputs.append((connector, match, matches[0]))
        if len(outputs) != 1:
            raise RuntimeError("One active Virtio display is required")
        connector, match, monitor = outputs[0]
        mode = self.reader.preferred_mode(Path("/dev/dri") / match[1], connector)
        mode_string = modeline(mode)
        scale = validated_scale(monitor.get("scale"))
        fingerprint = (tuple(mode[name] for name in MODE_FIELDS), scale)
        output = match[2]
        geometry = (mode["hdisplay"], mode["vdisplay"])
        if (monitor.get("width"), monitor.get("height")) == geometry:
            self.last_applied[output] = fingerprint
            return
        if self.last_applied.get(output) == fingerprint:
            return
        rule = f'hl.monitor({{ output = "", mode = "{mode_string}", scale = {scale:.8g} }})'
        if hyprctl("eval", rule, environment=self.environment, deadline=deadline) != "ok":
            raise RuntimeError("Compositor rejected the display mode")
        self.last_applied[output] = fingerprint
        current = next((item for item in self.monitors(deadline) if item.get("name") == output), None)
        if current and (current.get("width"), current.get("height")) == geometry:
            if math.isclose(validated_scale(current.get("scale")), scale, abs_tol=1e-7):
                print(f"Display synchronized: {geometry[0]}x{geometry[1]} scale {scale:g}", flush=True)


def run():
    watcher = subprocess.Popen(
        ["udevadm", "monitor", "--udev", "--subsystem-match=drm", "--property"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        bufsize=0, env={**os.environ, "LC_ALL": "C"},
    )
    try:
        os.set_blocking(watcher.stdout.fileno(), False)
        debouncer = HotplugDebouncer()
        events = UdevReader(watcher.stdout.fileno(), debouncer)
        synchronizer = DisplaySynchronizer()
        with selectors.DefaultSelector() as selector:
            selector.register(watcher.stdout, selectors.EVENT_READ)
            startup_deadline = time.monotonic() + STARTUP_TIMEOUT
            while not events.ready:
                remaining = startup_deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise RuntimeError("Display event monitor startup timed out")
                events.read_available()
            while True:
                try:
                    synchronizer.update(startup_deadline)
                    break
                except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                    synchronizer.environment = None
                    remaining = startup_deadline - time.monotonic()
                    if remaining <= 0:
                        raise RuntimeError("Display startup timed out") from None
                    if selector.select(min(0.25, remaining)):
                        events.read_available()
            while True:
                timeout = None if debouncer.deadline is None else max(0, debouncer.deadline - time.monotonic())
                if selector.select(timeout):
                    events.read_available()
                if debouncer.pop_due(time.monotonic()):
                    try:
                        synchronizer.update()
                    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                        synchronizer.environment = None
                        print("Display synchronization deferred after a guest display error.", file=sys.stderr, flush=True)
    finally:
        watcher.terminate()
        try:
            watcher.wait(timeout=3)
        except subprocess.TimeoutExpired:
            watcher.kill()
            watcher.wait(timeout=3)
        if watcher.stdout:
            watcher.stdout.close()


if __name__ == "__main__":
    try:
        run()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        print("Display synchronization stopped; the session service will retry.", file=sys.stderr, flush=True)
        raise SystemExit(1)
