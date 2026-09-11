#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / "Artifacts"
SOURCE = json.loads((ROOT / "Guest/source.json").read_text())


def run(*arguments):
    subprocess.run([str(argument) for argument in arguments], check=True)


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def check(path, expected, byte_count=None):
    if not path.is_file() or (byte_count is not None and path.stat().st_size != byte_count):
        raise RuntimeError("Missing or truncated guest artifact: " + str(path))
    if digest(path) != expected:
        raise RuntimeError("SHA-256 mismatch: " + str(path))


def adapt(helper, work):
    command_line = "root=/dev/vda rw rootwait console=hvc0 init=/bin/bash loglevel=4"
    process = subprocess.Popen([str(helper), str(work), str(ROOT / "Guest"), command_line], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    command = (
        "mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev; "
        "modprobe virtiofs; mkdir -p /mnt/build; mount -t virtiofs omabox-build /mnt/build; "
        "bash /mnt/build/adapt-guest.sh /mnt/build; result=$?; "
        "echo OMABOX_BUILD_RESULT:$result; sync; mount -o remount,ro /; poweroff -f\n"
    )
    output = bytearray()
    sent = False
    deadline = time.monotonic() + 240
    try:
        with (work / "bootstrap.log").open("wb") as log:
            while time.monotonic() < deadline:
                for key, _ in selector.select(1):
                    chunk = os.read(key.fileobj.fileno(), 16384)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    log.write(chunk)
                    log.flush()
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                    output.extend(chunk)
                    if not sent and b"]# " in output:
                        process.stdin.write(command.encode())
                        process.stdin.flush()
                        sent = True
                if process.poll() is not None and not selector.get_map():
                    break
            else:
                raise RuntimeError("Native guest adaptation exceeded four minutes")
        if process.wait(timeout=10) != 0 or not re.search(rb"[\r\n]OMABOX_BUILD_RESULT:0[\r\n]", output):
            raise RuntimeError("Native guest adaptation failed; see " + str(work / "bootstrap.log"))
    finally:
        selector.close()
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)


def main():
    if len(sys.argv) > 1:
        raise RuntimeError("prepare-guest.sh takes no arguments; it only builds the bundled factory template")
    if os.uname().machine != "arm64":
        raise RuntimeError("Guest preparation requires an Apple silicon Mac")
    downloads = ARTIFACTS / "Downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    image = downloads / "TryOmarchy-v0.3.0.dmg"
    if not image.exists():
        partial = image.with_suffix(".dmg.partial")
        run("curl", "--fail", "--location", "--retry", "3", "--continue-at", "-", "--output", partial, SOURCE["url"])
        check(partial, SOURCE["sha256"])
        partial.rename(image)
    check(image, SOURCE["sha256"])
    work = Path(tempfile.mkdtemp(prefix="guest-build-", dir=ARTIFACTS))
    mount = work / "source"
    mount.mkdir()
    mounted = False
    try:
        run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount, image)
        mounted = True
        resources = mount / "Try Omarchy.app/Contents/Resources"
        factory = resources / "guest"
        upstream_manifest = json.loads((factory / "guest-manifest.json").read_text())
        for entry in upstream_manifest["artifacts"]:
            file = factory / entry["path"]
            if file.exists():
                check(file, entry["sha256"], entry["bytes"])
        shutil.copyfile(factory / "vmlinuz-linux", work / "kernel")
        shutil.copyfile(factory / "initramfs-linux.img", work / "initramfs")
        run(resources / "runtime/bin/zstd", "--decompress", "--sparse", "-o", work / "rootfs.raw", factory / "rootfs.ext4.zst")
        root_entry = next(item for item in upstream_manifest["artifacts"] if item["path"] == "rootfs.ext4")
        check(work / "rootfs.raw", root_entry["sha256"], root_entry["bytes"])
        for name in ["guest-manifest.json", "provenance.json", "packages.lock.txt", "LICENSE.omarchy", "build-spec.json"]:
            shutil.copyfile(factory / name, work / name)
        helper = ARTIFACTS / "GuestBootstrap"
        run("xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", ROOT / "Scripts/GuestBootstrap.swift", "-o", helper)
        run("codesign", "--force", "--sign", "-", "--entitlements", ROOT / "Scripts/GuestBootstrap.entitlements", helper)
        adapt(helper, work)
        names = ["kernel", "initramfs", "rootfs.raw"]
        metadata = {
            "schemaVersion": 1,
            "architecture": "aarch64",
            "version": "0.4.0",
            "integrationVersion": 4,
            "kernelFile": "kernel",
            "initramfsFile": "initramfs",
            "diskFile": "rootfs.raw",
            "commandLine": "root=/dev/vda rw rootwait console=tty0 console=hvc0 loglevel=4 systemd.show_status=false rd.systemd.show_status=false",
            "integrity": {name: {"byteCount": (work / name).stat().st_size, "sha256": digest(work / name)} for name in names},
            "source": SOURCE,
        }
        (work / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        destination = ROOT / "Omabox/Resources/Guest"
        destination.mkdir(parents=True, exist_ok=True)
        for name in names + ["metadata.json", "guest-manifest.json", "provenance.json", "packages.lock.txt", "LICENSE.omarchy", "build-spec.json"]:
            temporary = destination / (name + ".partial")
            if temporary.exists():
                temporary.unlink()
            run("cp", "-c", work / name, temporary)
            temporary.replace(destination / name)
        print("Prepared native Apple Virtualization guest at " + str(destination))
        print("The factory is unprovisioned. Omarchy creates the owner's account at first boot.")
    finally:
        if mounted:
            run("hdiutil", "detach", mount)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Guest preparation failed: " + str(error), file=sys.stderr)
        sys.exit(1)
