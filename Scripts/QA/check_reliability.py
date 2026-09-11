#!/usr/bin/env python3
import json
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Scripts"))
from prepare_guest import check, run


def processes():
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,time=,rss=,comm="], text=True)
    result = {}
    for line in output.splitlines():
        pid, parent, elapsed, rss, name = line.split(None, 4)
        seconds = 0.0
        for part in elapsed.split(":"):
            seconds = seconds * 60 + float(part)
        result[int(pid)] = {"parent": int(parent), "cpuSeconds": seconds, "residentKiB": int(rss), "name": name}
    return result


class VM:
    def __init__(self, helper, directory, stage, provisioning=False):
        self.directory = directory
        self.stage = stage
        self.provisioning = provisioning
        self.baseline = set(processes())
        command = "root=/dev/vda rw rootwait console=tty0 console=hvc0 loglevel=4 systemd.show_status=false omabox.display_scale=1 omabox.render_threads=2"
        if provisioning:
            command += " init=/bin/bash"
        self.started = time.monotonic()
        self.process = subprocess.Popen([str(helper), str(directory), str(ROOT / "Guest"), command], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.output = bytearray()
        self.log = (directory / (stage + ".log")).open("wb")
        try:
            self.wait(rb"\]# ", timeout=180)
        except Exception:
            self.stop()
            raise
        self.boot_seconds = time.monotonic() - self.started

    def pump(self, timeout=0.1):
        for key, _ in self.selector.select(timeout):
            data = os.read(key.fileobj.fileno(), 16_384)
            if not data:
                self.selector.unregister(key.fileobj)
                continue
            self.log.write(data)
            self.log.flush()
            self.output.extend(data)

    def wait(self, pattern, start=0, timeout=120):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            match = re.search(pattern, self.output[start:])
            if match:
                return match
            self.pump()
            if self.process.poll() is not None and not self.selector.get_map():
                break
        raise RuntimeError(f"{self.stage}: missing {pattern!r}; see {self.log.name}")

    def send(self, command):
        self.process.stdin.write(command.encode() + b"\n")
        self.process.stdin.flush()

    def shell(self, command, timeout=120):
        start = len(self.output)
        self.send(command + "; result=$?; printf '\\nOMABOX_RELIABILITY_RESULT:%s\\n' \"$result\"")
        match = self.wait(rb"[\r\n]OMABOX_RELIABILITY_RESULT:(\d+)[\r\n]", start, timeout)
        if match[1] != b"0":
            raise RuntimeError(f"Guest command failed: {self.log.name}")

    def control(self, action, **arguments):
        start = len(self.output)
        self.send("@omabox " + json.dumps({"action": action, **arguments}))
        match = self.wait(rb"[\r\n]@QA (\{[^\r\n]+\})[\r\n]", start, timeout=20)
        event = json.loads(match[1])
        if event["event"] != action:
            raise RuntimeError("Native control failed: " + str(event))
        return event

    def delay(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.pump(min(0.2, deadline - time.monotonic()))

    def idle(self, seconds=20):
        before = processes()
        selected = {pid for pid, details in before.items() if pid == self.process.pid or (pid not in self.baseline and "Virtualization.VirtualMachine" in details["name"])}
        if len(selected) != 2:
            raise RuntimeError("Idle sample needs exactly one new Virtualization service and this QA helper")
        sample_started = datetime.now(timezone.utc).isoformat()
        host_load = os.getloadavg()
        started = time.monotonic()
        self.delay(seconds)
        elapsed = time.monotonic() - started
        after = processes()
        samples = []
        for pid in sorted(selected):
            if pid in after:
                samples.append({"pid": pid, "name": after[pid]["name"], "cpuPercentOneCore": round((after[pid]["cpuSeconds"] - before[pid]["cpuSeconds"]) / elapsed * 100, 3), "residentMiB": round(after[pid]["residentKiB"] / 1024, 2)})
        return {"sampleStartedUTC": sample_started, "sampleSeconds": round(elapsed, 3), "hostLoadAverageAtStart": host_load, "hostLogicalCPUCount": os.cpu_count(), "processes": samples, "totalCPUPercentOneCore": round(sum(value["cpuPercentOneCore"] for value in samples), 3)}

    def stop(self):
        if self.process.poll() is None:
            self.send("sync; poweroff -f" if self.provisioning else "systemctl poweroff")
            deadline = time.monotonic() + 40
            while self.process.poll() is None and time.monotonic() < deadline:
                self.pump()
            if self.process.poll() is None:
                self.process.terminate()
                self.process.wait(timeout=10)
        self.pump(0)
        self.selector.close()
        self.log.close()


def desktop(vm):
    vm.shell("export TERM=dumb SYSTEMD_COLORS=0 SYSTEMD_PAGER=cat; for attempt in {1..45}; do pgrep -u omaboxqa -x Hyprland >/dev/null && pgrep -u omaboxqa -x quickshell >/dev/null && break; sleep 1; done; pgrep -u omaboxqa -x Hyprland >/dev/null && pgrep -u omaboxqa -x quickshell >/dev/null")
    vm.shell("mkdir -p /mnt/build; mount -t virtiofs omabox-build /mnt/build")


def verify_size(vm, width, height):
    vm.shell("instance=$(runuser -u omaboxqa -- env XDG_RUNTIME_DIR=/run/user/1000 hyprctl instances -j); signature=$(printf '%s' \"$instance\" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0][\"instance\"])'); wayland=$(printf '%s' \"$instance\" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0][\"wl_socket\"])'); test -n \"$signature\" && test -n \"$wayland\"")
    command = 'runuser -u omaboxqa -- env XDG_RUNTIME_DIR=/run/user/1000 HYPRLAND_INSTANCE_SIGNATURE="$signature" WAYLAND_DISPLAY="$wayland"'
    vm.shell(command + " hyprctl monitors -j | python3 -c 'import json,sys; display=json.load(sys.stdin)[0]; assert display[\"width\"] == " + str(width) + " and display[\"height\"] == " + str(height) + "; print(\"OMABOX_RESIZE_VERIFIED\",display[\"width\"],display[\"height\"])'")
    vm.shell(command + " grim /home/omaboxqa/resize.png && cp /home/omaboxqa/resize.png /mnt/qa-writable/resize-" + str(width) + "x" + str(height) + ".png")


def main():
    resuming = len(sys.argv) == 3 and sys.argv[1] == "--resume"
    if len(sys.argv) != 1 and not resuming:
        raise RuntimeError("Usage: check_reliability.py [--resume ARTIFACT_DIRECTORY]")
    if resuming:
        directory = Path(sys.argv[2]).resolve()
        if directory.parent != ROOT / "Artifacts" or not directory.name.startswith("guest-reliability-") or (directory / "rootfs.raw").is_symlink() or not (directory / "exports/reliability-first.json").is_file():
            raise RuntimeError("Resume requires an existing disposable reliability fixture")
    else:
        directory = Path(tempfile.mkdtemp(prefix="guest-reliability-", dir=ROOT / "Artifacts"))
        (directory / "readonly").mkdir()
        (directory / "exports").mkdir()
        (directory / "readonly/readonly-sentinel.txt").write_text("omabox-qa-readonly-v1\n")
    template = ROOT / "Omabox/Resources/Guest"
    metadata = json.loads((template / "metadata.json").read_text())
    for name in ["kernel", "initramfs", "rootfs.raw"]:
        expected = metadata["integrity"][name]
        check(template / name, expected["sha256"], expected["byteCount"])
        if not resuming:
            run("cp", "-c", template / name, directory / name)
    helper = directory / "ReliabilityVM"
    run("xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", ROOT / "Scripts/QA/ReliabilityVM.swift", "-o", helper)
    run("codesign", "--force", "--sign", "-", "--entitlements", ROOT / "Scripts/GuestBootstrap.entitlements", helper)
    report = {"factoryIntegrity": metadata["integrity"], "configuration": {"cpuCount": 4, "memoryGiB": 4, "renderThreads": 2, "audioSink": "nil: framework discards guest audio", "audioSinkReference": "macOS SDK Virtualization.framework/Headers/VZVirtioSoundDeviceOutputStreamConfiguration.h:26-31", "host": subprocess.check_output(["sw_vers"], text=True).strip()}, "resumedExistingFixture": resuming, "boots": []}
    if not resuming:
        vm = VM(helper, directory, "provision", provisioning=True)
        try:
            vm.shell("mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev; mount -t tmpfs tmpfs /run; modprobe virtiofs; mkdir -p /mnt/build; mount -t virtiofs omabox-build /mnt/build; bash /mnt/build/qa-provision.sh", timeout=180)
            vm.shell("sync; mount -o remount,ro /")
        finally:
            vm.stop()
    for stage in (["second"] if resuming else ["first", "second"]):
        print("Booting " + stage + ": " + str(directory), flush=True)
        vm = VM(helper, directory, stage)
        entry = {"stage": stage, "consoleReadySeconds": round(vm.boot_seconds, 3), "completed": False}
        report["boots"].append(entry)
        try:
            desktop(vm)
            entry["desktopReadySeconds"] = round(time.monotonic() - vm.started, 3)
            vm.shell("bash /mnt/build/qa-reliability.sh " + stage, timeout=180)
            if stage == "first" or resuming:
                vm.delay(15)
                entry["idle"] = vm.idle()
                entry["pauseResume"] = []
                for _ in range(3):
                    pause = vm.control("pause")
                    vm.delay(1)
                    resume = vm.control("resume")
                    vm.shell("test -r /proc/uptime && pgrep -u omaboxqa -x Hyprland >/dev/null")
                    entry["pauseResume"].append({"pause": pause, "resume": resume})
                entry["resize"] = []
                for width, height in [(1024, 768), (1440, 900)]:
                    event = vm.control("resize", width=width, height=height)
                    vm.delay(2)
                    verify_size(vm, width, height)
                    entry["resize"].append({**event, "width": width, "height": height, "guestConfirmed": True})
            vm.shell("sync")
            entry["completed"] = True
        except Exception as error:
            entry["error"] = str(error)
            raise
        finally:
            vm.stop()
            (directory / "host-report.json").write_text(json.dumps(report, indent=2) + "\n")
    assert (directory / "readonly/readonly-sentinel.txt").read_text() == "omabox-qa-readonly-v1\n"
    assert sorted(path.name for path in (directory / "readonly").iterdir()) == ["readonly-sentinel.txt"]
    print(json.dumps(report, indent=2))
    print("Evidence: " + str(directory))


if __name__ == "__main__":
    main()
