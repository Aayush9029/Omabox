#!/usr/bin/env python3

import argparse
import ctypes
import ctypes.util
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys


DRM_MODE_TYPE_PREFERRED = 1 << 3


# ABI: https://gitlab.freedesktop.org/mesa/drm/-/blob/main/xf86drmMode.h
class DRMModeInfo(ctypes.Structure):
    _fields_ = [
        ("clock", ctypes.c_uint32),
        *[(name, ctypes.c_uint16) for name in (
            "hdisplay", "hsync_start", "hsync_end", "htotal", "hskew",
            "vdisplay", "vsync_start", "vsync_end", "vtotal", "vscan",
        )],
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


def preferred_mode(card, connector_path):
    connector_id = int((connector_path / "connector_id").read_text().strip())
    if not 0 < connector_id <= 0xFFFFFFFF:
        raise ValueError("Invalid DRM connector ID")
    if ctypes.sizeof(DRMModeInfo) != 68 or ctypes.sizeof(DRMConnector) != 88:
        raise RuntimeError("Unsupported libdrm ABI; this fixture requires 64-bit Linux")

    library = ctypes.util.find_library("drm")
    if not library:
        raise RuntimeError("libdrm is unavailable")
    drm = ctypes.CDLL(library, use_errno=True)
    drm.drmModeGetConnector.argtypes = [ctypes.c_int, ctypes.c_uint32]
    drm.drmModeGetConnector.restype = ctypes.POINTER(DRMConnector)
    drm.drmModeFreeConnector.argtypes = [ctypes.POINTER(DRMConnector)]
    drm.drmModeFreeConnector.restype = None

    descriptor = os.open(card, os.O_RDONLY | os.O_CLOEXEC)
    connector = None
    try:
        connector = drm.drmModeGetConnector(descriptor, connector_id)
        if not connector:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), str(card))
        info = connector.contents
        if info.connection != 1 or info.connector_id != connector_id:
            raise ValueError("DRM connector is not connected")
        if not 0 < info.count_modes <= 1024 or not info.modes:
            raise ValueError("DRM connector has no valid mode list")
        for index in range(info.count_modes):
            mode = info.modes[index]
            if mode.type & DRM_MODE_TYPE_PREFERRED:
                return {
                    name: int(getattr(mode, name))
                    for name, _ in DRMModeInfo._fields_ if name != "name"
                }
        raise ValueError("DRM connector has no preferred mode")
    finally:
        if connector:
            drm.drmModeFreeConnector(connector)
        os.close(descriptor)


def modeline(mode):
    if not 64 <= mode["hdisplay"] <= 8192 or not 64 <= mode["vdisplay"] <= 8192:
        raise ValueError("Preferred dimensions exceed fixture bounds")
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
        raise ValueError("Only progressive separate-sync timings are supported")
    if mode["hskew"] or mode["vscan"] not in (0, 1):
        raise ValueError("Unsupported preferred scan parameters")

    # Hyprland 0.56 parses MHz as an integer, so retain exact geometry and round the clock.
    clock_mhz = (mode["clock"] + 500) // 1000
    timing = [mode[name] for name in (
        "hdisplay", "hsync_start", "hsync_end", "htotal",
        "vdisplay", "vsync_start", "vsync_end", "vtotal",
    )]
    hsync = "+hsync" if flags & 1 else "-hsync"
    vsync = "+vsync" if flags & 4 else "-vsync"
    return " ".join(["modeline", str(clock_mhz), *map(str, timing), hsync, vsync])


def hyprctl(*arguments):
    return subprocess.run(
        ["hyprctl", *arguments], check=True, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
    ).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description="Apply a fresh DRM preferred mode in a disposable Omabox guest")
    parser.add_argument("--connector", type=Path)
    parser.add_argument("--card", type=Path)
    parser.add_argument("--inspect-only", action="store_true")
    args = parser.parse_args()
    if not os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") or not os.environ.get("XDG_RUNTIME_DIR"):
        raise ValueError("HYPRLAND_INSTANCE_SIGNATURE and XDG_RUNTIME_DIR must be set")

    candidates = [args.connector] if args.connector else sorted(Path("/sys/class/drm").glob("card*-Virtual-*"))
    connected = [path for path in candidates if (path / "status").read_text().strip() == "connected"]
    if len(connected) != 1:
        raise ValueError("Select exactly one connected Virtio connector with --connector")
    connector = connected[0]
    match = re.fullmatch(r"(card[0-9]+)-(Virtual-[0-9]+)", connector.name)
    if not match:
        raise ValueError("Expected a cardN-Virtual-N DRM connector")
    card = args.card or Path("/dev/dri") / match[1]
    if card != Path("/dev/dri") / match[1]:
        raise ValueError("Card path does not match the selected DRM connector")

    mode = preferred_mode(card, connector)
    mode_string = modeline(mode)
    monitors = json.loads(hyprctl("monitors", "-j"))
    matches = [monitor for monitor in monitors if monitor.get("name") == match[2]]
    if len(matches) != 1:
        raise ValueError("The DRM connector does not match one active Hyprland output")
    scale = matches[0].get("scale")
    if isinstance(scale, bool) or not isinstance(scale, (int, float)) or not math.isfinite(scale) or not 0.25 <= scale <= 4:
        raise ValueError("Invalid current Hyprland output scale")

    rule = f'hl.monitor({{ output = "", mode = "{mode_string}", scale = {scale:.8g} }})'
    report = {"card": str(card), "connector": connector.name, "mode": mode, "scale": scale, "rule": rule}
    print(json.dumps(report, sort_keys=True), flush=True)
    if not args.inspect_only:
        response = hyprctl("eval", rule)
        if response != "ok":
            raise RuntimeError(f"Hyprland rejected the preferred mode: {response}")
        print(json.dumps({"applied": True, "width": mode["hdisplay"], "height": mode["vdisplay"]}), flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"qa-display-mode: {error}", file=sys.stderr)
        raise SystemExit(1)
