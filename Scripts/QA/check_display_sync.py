#!/usr/bin/env python3
import json
from pathlib import Path
import sys

from check_reliability import ROOT, VM, desktop


def main():
    if len(sys.argv) != 2:
        raise RuntimeError("Usage: check_display_sync.py DISPOSABLE_RELIABILITY_DIRECTORY")
    directory = Path(sys.argv[1]).resolve()
    if directory.parent != ROOT / "Artifacts" or not directory.name.startswith("guest-reliability-") or (directory / "rootfs.raw").is_symlink() or not (directory / "exports/reliability-first.json").is_file():
        raise RuntimeError("An existing disposable reliability fixture is required")
    vm = VM(directory / "ReliabilityVM", directory, "display-sync")
    report = {"checks": [], "passed": False}

    def check_display(name, width, height, scale):
        vm.delay(1)
        vm.shell("user_run hyprctl monitors -j > /mnt/qa-writable/display-sync-monitors.json")
        display = json.loads((directory / "exports/display-sync-monitors.json").read_text())[0]
        result = {"name": name, "width": display["width"], "height": display["height"], "scale": display["scale"]}
        result["passed"] = (display["width"], display["height"], display["scale"]) == (width, height, scale)
        report["checks"].append(result)
        if not result["passed"]:
            raise RuntimeError("Display check failed: " + str(result))

    try:
        desktop(vm)
        vm.shell('mkdir -p /mnt/qa-writable; mount -t virtiofs qa-writable /mnt/qa-writable; instance=$(runuser -u omaboxqa -- env XDG_RUNTIME_DIR=/run/user/1000 hyprctl instances -j); signature=$(printf %s "$instance" | python3 -c \'import json,sys; print(json.load(sys.stdin)[0]["instance"])\'); wayland=$(printf %s "$instance" | python3 -c \'import json,sys; print(json.load(sys.stdin)[0]["wl_socket"])\'); user_run() { runuser -u omaboxqa -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus HYPRLAND_INSTANCE_SIGNATURE="$signature" WAYLAND_DISPLAY="$wayland" "$@"; }')
        vm.shell("install -m 0755 /mnt/build/overlay/usr/local/libexec/omabox-display-sync.py /usr/local/libexec/omabox-display-sync.py; install -m 0644 /mnt/build/overlay/usr/lib/systemd/user/omabox-display-sync.service /usr/lib/systemd/user/omabox-display-sync.service; user_run systemctl --user daemon-reload; user_run systemctl --user stop omabox-display-sync.service; printf 'OMABOX_DYNAMIC_RESOLUTION=1\\n' > /home/omaboxqa/.config/omabox/desktop.env; chown omaboxqa:omaboxqa /home/omaboxqa/.config/omabox/desktop.env")
        vm.control("resize", width=1024, height=768)
        vm.delay(1)
        vm.shell("user_run systemctl --user start omabox-display-sync.service")
        check_display("startupCatchup", 1024, 768, 1)
        vm.control("resize", width=1440, height=900)
        check_display("liveResize", 1440, 900, 1)
        vm.shell('user_run hyprctl eval \'hl.monitor({output="", mode="1440x900", scale=2})\'')
        vm.control("resize", width=1280, height=800)
        check_display("scalePreserved", 1280, 800, 2)
        vm.shell("printf 'OMABOX_DYNAMIC_RESOLUTION=0\\n' > /home/omaboxqa/.config/omabox/desktop.env")
        vm.control("resize", width=1024, height=768)
        check_display("runtimeOptOut", 1280, 800, 2)
        vm.shell("user_run systemctl --user stop omabox-display-sync.service")
        vm.control("resize", width=1440, height=900)
        vm.shell("user_run systemctl --user start omabox-display-sync.service")
        check_display("startupOptOut", 1280, 800, 2)
        vm.shell("printf 'OMABOX_DYNAMIC_RESOLUTION=1\\n' > /home/omaboxqa/.config/omabox/desktop.env")
        vm.control("resize", width=1360, height=768)
        check_display("reEnabled", 1360, 768, 2)
        for index in range(12):
            vm.control("resize", width=1024 + 8 * index, height=768)
        check_display("rapidResizeLatestWins", 1112, 768, 2)
        vm.shell("user_run systemctl --user is-active omabox-display-sync.service; user_run hyprctl configerrors; user_run grim /home/omaboxqa/display-sync.png; cp /home/omaboxqa/display-sync.png /mnt/qa-writable/display-sync-1112x768-scale2.png; journalctl --no-pager _UID=1000 _SYSTEMD_USER_UNIT=omabox-display-sync.service > /mnt/qa-writable/display-sync-journal.txt; sync")
        report["passed"] = True
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        try:
            vm.shell("journalctl --no-pager _UID=1000 _SYSTEMD_USER_UNIT=omabox-display-sync.service > /mnt/qa-writable/display-sync-journal.txt; sync")
        except Exception:
            pass
        vm.stop()
        (directory / "display-sync-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    print("Evidence: " + str(directory))


if __name__ == "__main__":
    main()
