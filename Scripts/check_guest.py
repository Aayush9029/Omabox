#!/usr/bin/env python3
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time

from prepare_guest import ARTIFACTS, ROOT, check, run


def boot(helper, directory, provisioning, customized=False):
    command_line = "root=/dev/vda rw rootwait console=tty0 console=hvc0 loglevel=4 systemd.show_status=false"
    if provisioning:
        command_line += " init=/bin/bash"
    else:
        command_line += " omabox.display_scale=1 omabox.render_threads=2"
    environment = dict(os.environ)
    if not provisioning:
        environment["OMABOX_QA_CLIPBOARD"] = "1"
    process = subprocess.Popen([str(helper), str(directory), str(ROOT / "Guest"), command_line], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=environment)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    prefix = "mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev; mount -t tmpfs tmpfs /run; modprobe virtiofs; " if provisioning else "export TERM=dumb SYSTEMD_COLORS=0 SYSTEMD_PAGER=cat; "
    script = "qa-provision.sh" if provisioning else ("qa-verify.sh custom" if customized else "qa-verify.sh native")
    ending = "sync; mount -o remount,ro /; poweroff -f" if provisioning else "systemctl poweroff"
    command = prefix + "mkdir -p /mnt/build; mount -t virtiofs omabox-build /mnt/build; bash /mnt/build/" + script + "; result=$?; echo OMABOX_QA_RESULT:$result; " + ending + "\n"
    log_path = directory / ("provision.log" if provisioning else ("customization.log" if customized else "verification.log"))
    captured = bytearray()
    sent = False
    deadline = time.monotonic() + 180
    try:
        with log_path.open("wb") as log:
            while time.monotonic() < deadline:
                for key, _ in selector.select(1):
                    chunk = os.read(key.fileobj.fileno(), 16384)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    log.write(chunk)
                    log.flush()
                    captured.extend(chunk)
                    if not sent and b"]# " in captured:
                        process.stdin.write(command.encode())
                        process.stdin.flush()
                        sent = True
                if process.poll() is not None and not selector.get_map():
                    break
            else:
                raise RuntimeError("QA guest timed out: " + str(log_path))
        if process.wait(timeout=10) != 0 or b"\nOMABOX_QA_RESULT:0\r" not in captured:
            raise RuntimeError("QA guest failed: " + str(log_path))
        if not provisioning and b'"text":"omabox-guest-clipboard-qa-20260911"' not in captured:
            raise RuntimeError("Host did not receive the guest clipboard token")
    finally:
        selector.close()
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)


def main():
    template = ROOT / "Omabox/Resources/Guest"
    metadata = json.loads((template / "metadata.json").read_text())
    directory = Path(tempfile.mkdtemp(prefix="guest-qa-", dir=ARTIFACTS))
    for name in ["kernel", "initramfs", "rootfs.raw"]:
        expected = metadata["integrity"][name]
        check(template / name, expected["sha256"], expected["byteCount"])
        run("cp", "-c", template / name, directory / name)
    helper = directory / "GuestBootstrap"
    run("xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", ROOT / "Scripts/GuestBootstrap.swift", "-o", helper)
    run("codesign", "--force", "--sign", "-", "--entitlements", ROOT / "Scripts/GuestBootstrap.entitlements", helper)
    boot(helper, directory, True)
    boot(helper, directory, False)
    boot(helper, directory, False, customized=True)
    assert (directory / "exports/desktop-native.png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
    assert (directory / "exports/desktop-custom.png").read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
    print("Native desktop, sound, VirtioFS, portals, bidirectional clipboard, and persistent user overrides passed.")
    print("Evidence: " + str(directory))


if __name__ == "__main__":
    main()
