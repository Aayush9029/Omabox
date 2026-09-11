#!/usr/bin/env python3
import base64
from datetime import datetime, timezone
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import shlex
import socket
import subprocess
import sys
import tempfile
import time

from check_reliability import ROOT, VM, desktop

sys.path.insert(0, str(ROOT / "Scripts"))
from prepare_guest import check, run


class SSHVM(VM):
    def ssh(self, request_type="sshStatus", **arguments):
        reply = self.control("ssh", request={"type": request_type, "version": 1, **arguments})["reply"]
        if reply.get("type") != "sshConfigured" or reply.get("version") != 1:
            raise RuntimeError("Guest rejected SSH request: " + str(reply))
        return reply

    def ssh_status_when_available(self, timeout=20):
        deadline = time.monotonic() + timeout
        while True:
            try:
                return self.ssh()
            except RuntimeError as error:
                if not str(error).startswith("Native control failed:") or time.monotonic() >= deadline:
                    raise
                self.delay(0.2)

    def ssh_ready(self, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            reply = self.ssh()
            if reply["state"] == "ready":
                return reply
            self.delay(0.5)
        raise RuntimeError("SSH did not become ready: " + str(reply))


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def generate_key(directory, name):
    key = directory / name
    run("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "Omabox disposable SSH QA", "-f", key)
    require(key.stat().st_mode & 0o077 == 0, "QA private key permissions are unsafe")
    return key, key.with_suffix(".pub").read_text().strip()


def connection_options(directory, reply, key):
    address = ipaddress.IPv4Address(reply["address"])
    require(address.is_private and not address.is_loopback and not address.is_link_local, "Expected the guest NAT IPv4 address")
    require(reply["port"] == 2222 and reply["user"] == "omaboxqa", "SSH must target the recorded nonroot QA owner")
    public = reply["hostPublicKey"].split()
    require(len(public) == 2 and public[0] == "ssh-ed25519", "Expected one Ed25519 guest host key")
    require(len(base64.b64decode(public[1], validate=True)) == 51, "Invalid guest host key")
    known_hosts = directory / "known_hosts"
    known_hosts.write_text(f"[{address}]:2222 {' '.join(public)}\n")
    known_hosts.chmod(0o600)
    return ["-F", "/dev/null", "-i", str(key), "-o", "IdentityAgent=none", "-o", "IdentitiesOnly=yes",
            "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + str(known_hosts),
            "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
            "-o", "ClearAllForwardings=yes", "-o", "ServerAliveInterval=2", "-o", "ServerAliveCountMax=2"]


def ssh_command(directory, reply, key, command, *, user=None, options=(), name="ssh"):
    arguments = ["ssh", *connection_options(directory, reply, key), *options, "-p", "2222",
                 (user or reply["user"]) + "@" + reply["address"], command]
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=20)
    (directory / (name + ".log")).write_text(result.stdout + result.stderr)
    return result


def verify_login(directory, reply, key, label):
    token = "omabox-ssh-" + secrets.token_hex(12)
    result = ssh_command(directory, reply, key, "whoami; id -u; printf '%s\\n' " + shlex.quote(token), name=label)
    require(result.returncode == 0, "SSH login failed: " + result.stderr)
    lines = result.stdout.splitlines()
    require(len(lines) == 3 and lines[0] == "omaboxqa" and int(lines[1]) >= 1000 and lines[2] == token,
            "SSH did not execute as the nonroot QA owner")
    return {"passed": True, "user": lines[0], "uid": int(lines[1]), "echoToken": token}


def verify_sftp(directory, reply, key):
    token = "omabox-sftp-" + secrets.token_hex(12) + "\n"
    upload = directory / "sftp-upload.txt"
    download = directory / "sftp-download.txt"
    upload.write_text(token)
    batch = directory / "sftp.batch"
    batch.write_text(f'put "{upload}" omabox-qa-transfer.txt\nget omabox-qa-transfer.txt "{download}"\nrm omabox-qa-transfer.txt\n')
    result = subprocess.run(["sftp", *connection_options(directory, reply, key), "-P", "2222", "-b", str(batch),
                             reply["user"] + "@" + reply["address"]], capture_output=True, text=True, timeout=20)
    (directory / "sftp.log").write_text(result.stdout + result.stderr)
    require(result.returncode == 0 and download.read_text() == token, "Pinned-host SFTP round trip failed")
    return {"passed": True, "bytes": len(token.encode())}


def verify_denied(directory, reply, key, label, **arguments):
    result = ssh_command(directory, reply, key, "printf UNEXPECTED_AUTHENTICATED", name=label, **arguments)
    require(result.returncode == 255 and "Permission denied" in result.stderr and "UNEXPECTED_AUTHENTICATED" not in result.stdout,
            "SSH authentication was not rejected as expected: " + label)
    return {"passed": True, "exitCode": result.returncode}


def verify_password_denied(directory, reply, key):
    options = ["-vv", "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive"]
    result = ssh_command(directory, reply, key, "printf UNEXPECTED_AUTHENTICATED", name="password-denied", options=options)
    methods = re.findall(r"Authentications that can continue: ([^\r\n]+)", result.stderr)
    require(result.returncode == 255 and methods and all(value == "publickey" for value in methods),
            "The SSH server offered password or keyboard-interactive authentication")
    return {"passed": True, "offeredAuthenticationMethods": sorted(set(methods))}


def verify_stopped(vm, address=None):
    vm.shell("test ! -e /var/lib/omabox/ssh/authorized_keys && test ! -e /var/lib/omabox/ssh/sshd_config && "
             "! systemctl is-active --quiet omabox-sshd.service && test -z \"$(ss -H -ltn 'sport = :2222')\" && "
             "! systemctl is-active --quiet sshd.service && test -z \"$(ss -H -ltn 'sport = :22')\"")
    if address:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                with socket.create_connection((address, 2222), timeout=1):
                    pass
            except OSError:
                return {"passed": True, "managedKeysRemoved": True, "listenerStopped": True, "hostTCPClosed": True, "upstreamSSHDisabled": True, "port22Closed": True}
            vm.delay(0.2)
        raise RuntimeError("Guest SSH port 2222 still accepts TCP connections")
    return {"passed": True, "managedKeysRemoved": True, "listenerStopped": True, "upstreamSSHDisabled": True, "port22Closed": True}


class HeldSession:
    def __init__(self, directory, reply, key, label):
        self.path = directory / (label + ".log")
        self.log = self.path.open("wb")
        self.process = subprocess.Popen(["ssh", *connection_options(directory, reply, key), "-p", "2222",
                                         reply["user"] + "@" + reply["address"],
                                         "printf 'OMABOX_SESSION_READY\\n'; exec sleep 300"],
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.output = bytearray()
        deadline = time.monotonic() + 15
        try:
            while time.monotonic() < deadline:
                self.pump()
                if b"OMABOX_SESSION_READY\n" in self.output:
                    return
                if self.process.poll() is not None:
                    break
            raise RuntimeError("Could not establish held SSH session: " + str(self.path))
        except Exception:
            self.close()
            raise

    def pump(self):
        for item, _ in self.selector.select(0.1):
            chunk = os.read(item.fileobj.fileno(), 4096)
            if not chunk:
                self.selector.unregister(item.fileobj)
                continue
            self.output.extend(chunk)
            self.log.write(chunk)
            self.log.flush()

    def verify_terminated(self, vm):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline and self.process.poll() is None:
            self.pump()
            vm.pump(0)
        require(self.process.poll() is not None and self.process.returncode != 0,
                "An authenticated SSH session survived revocation: " + str(self.path))
        vm.shell("pgrep -u omaboxqa -x Hyprland >/dev/null && pgrep -u omaboxqa -x quickshell >/dev/null")
        return {"passed": True, "exitCode": self.process.returncode, "ownerDesktopStillRunning": True}

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.pump()
        self.selector.close()
        self.log.close()


def verify_display(vm, directory):
    vm.shell('uid=$(id -u omaboxqa); instance=$(runuser -u omaboxqa -- env XDG_RUNTIME_DIR=/run/user/$uid hyprctl instances -j); '
             'signature=$(printf %s "$instance" | python3 -c \'import json,sys; print(json.load(sys.stdin)[0]["instance"])\'); '
             'wayland=$(printf %s "$instance" | python3 -c \'import json,sys; print(json.load(sys.stdin)[0]["wl_socket"])\'); '
             'user_run() { runuser -u omaboxqa -- env XDG_RUNTIME_DIR=/run/user/$uid HYPRLAND_INSTANCE_SIGNATURE="$signature" WAYLAND_DISPLAY="$wayland" "$@"; }')
    results = []
    try:
        for width, height in [(512, 320), (1440, 900)]:
            event = vm.control("resize", width=width, height=height)
            vm.delay(2)
            vm.shell("user_run python3 /mnt/build/qa-display-mode.py")
            vm.shell("user_run hyprctl monitors -j > /mnt/qa-writable/display-" + str(width) + "x" + str(height) + ".json")
            displays = json.loads((directory / "exports" / f"display-{width}x{height}.json").read_text())
            require(len(displays) == 1 and (displays[0]["width"], displays[0]["height"]) == (width, height),
                    "Hyprland actual display mode does not match the native scanout resize")
            vm.shell("user_run grim /home/omaboxqa/ssh-display.png && cp /home/omaboxqa/ssh-display.png /mnt/qa-writable/display-" + str(width) + "x" + str(height) + ".png")
            results.append({"passed": True, "width": width, "height": height, "scale": displays[0]["scale"], "nativeControl": event})
    finally:
        if not results or results[-1]["width"] != 1440:
            vm.control("resize", width=1440, height=900)
            vm.delay(2)
            vm.shell("user_run python3 /mnt/build/qa-display-mode.py")
    return results


def guest_setup(vm):
    desktop(vm)
    vm.shell("mkdir -p /mnt/qa-writable && mount -t virtiofs qa-writable /mnt/qa-writable && "
             "systemctl is-active --quiet omabox-ssh-agent.service && "
             "test ! -e /var/lib/omarchy/provisioning/pending && "
             "python3 -c 'import json; owner=json.load(open(\"/var/lib/omabox/owner.json\")); "
             "assert owner[\"user\"] == \"omaboxqa\" and owner[\"uid\"] >= 1000; print(owner)'")


def main():
    if len(sys.argv) != 1:
        raise RuntimeError("Usage: check_ssh.py")
    require(os.uname().machine == "arm64", "Native SSH QA requires an Apple silicon Mac")
    artifacts = ROOT / "Artifacts"
    artifacts.mkdir(exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="guest-ssh-", dir=artifacts))
    directory.chmod(0o700)
    print("Evidence: " + str(directory), flush=True)
    for name in ("readonly", "exports", "host-config"):
        (directory / name).mkdir()
    (directory / "readonly/readonly-sentinel.txt").write_text("omabox-qa-readonly-v1\n")
    (directory / "host-config").chmod(0o700)
    for name in ("desktop.env", "hyprland.lua"):
        path = directory / "host-config" / name
        path.write_text("")
        path.chmod(0o600)
    template = ROOT / "Omabox/Resources/Guest"
    metadata_data = (template / "metadata.json").read_bytes()
    metadata = json.loads(metadata_data)
    report = {"startedUTC": datetime.now(timezone.utc).isoformat(), "passed": False,
              "factoryIntegrity": metadata["integrity"], "integrationVersion": metadata.get("integrationVersion"), "checks": {}, "boots": [],
              "configuration": {"cpuCount": 4, "memoryGiB": 4, "vsockControlPort": 4041, "sshPort": 2222,
                                "hostKeyVerification": "strict pin from guest control reply", "keys": "generated only in this disposable directory"}}
    vm = None
    try:
        for name in ("kernel", "initramfs", "rootfs.raw"):
            source = template / name
            require(not source.is_symlink(), "Factory artifact must not be a symlink")
            expected = metadata["integrity"][name]
            check(source, expected["sha256"], expected["byteCount"])
            run("cp", "-c", source, directory / name)
            require(source.stat().st_ino != (directory / name).stat().st_ino, "The QA disk must be a separate clone")
        (directory / "factory-metadata.json").write_bytes(metadata_data)
        installed_metadata = {**metadata, "installedDiskMinimumBytes": (directory / "rootfs.raw").stat().st_size}
        (directory / "metadata.json").write_text(json.dumps(installed_metadata, indent=2) + "\n")
        key, public_key = generate_key(directory, "qa_ed25519")
        replacement_key, replacement_public = generate_key(directory, "replacement_ed25519")
        wrong_key, _ = generate_key(directory, "wrong_ed25519")
        helper = directory / "SSHVM"
        run("xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", ROOT / "Scripts/QA/SSHVM.swift", "-o", helper)
        run("codesign", "--force", "--sign", "-", "--entitlements", ROOT / "Scripts/GuestBootstrap.entitlements", helper)
        vm = SSHVM(helper, directory, "provision", provisioning=True)
        vm.shell("mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev; "
                 "mount -t tmpfs tmpfs /run; modprobe virtiofs; mkdir -p /mnt/build; "
                 "mount -t virtiofs omabox-build /mnt/build; bash /mnt/build/qa-provision.sh && "
                 "test ! -e /var/lib/omarchy/provisioning/pending && /usr/local/libexec/omabox-record-owner.py", timeout=180)
        vm.shell("sync; mount -o remount,ro /")
        vm.stop()
        vm = None
        checks = report["checks"]
        print("Booting SSH and display checks", flush=True)
        vm = SSHVM(helper, directory, "first")
        report["boots"].append({"stage": "first", "consoleReadySeconds": round(vm.boot_seconds, 3)})
        guest_setup(vm)
        initial = vm.ssh()
        require(initial["state"] == "disabled" and initial["enabled"] is False, "SSH must start disabled")
        checks["initialDisabled"] = {"reply": initial, **verify_stopped(vm)}
        vm.ssh("configureSSH", enabled=True, publicKey=public_key)
        ready = vm.ssh_ready()
        checks["enabledReply"] = ready
        checks["nonrootLogin"] = verify_login(directory, ready, key, "owner-login")
        checks["sftp"] = verify_sftp(directory, ready, key)
        checks["rootDenied"] = verify_denied(directory, ready, key, "root-denied", user="root")
        checks["wrongKeyDenied"] = verify_denied(directory, ready, wrong_key, "wrong-key-denied")
        checks["passwordDenied"] = verify_password_denied(directory, ready, key)
        vm.shell("/usr/bin/sshd -T -f /var/lib/omabox/ssh/sshd_config > /mnt/qa-writable/sshd-effective-config.txt")
        effective = dict((name.lower(), value) for name, value in (line.split(None, 1) for line in (directory / "exports/sshd-effective-config.txt").read_text().splitlines() if " " in line))
        for name, expected in {"permitrootlogin": "no", "passwordauthentication": "no", "kbdinteractiveauthentication": "no",
                               "authenticationmethods": "publickey", "usepam": "no", "allowusers": "omaboxqa"}.items():
            require(effective.get(name) == expected, "Unexpected effective sshd configuration: " + name)
        checks["effectiveConfiguration"] = {"passed": True, "usePAM": False, "authenticationMethods": "publickey"}
        openssh_failed_authentication_penalty_seconds = 16
        vm.delay(openssh_failed_authentication_penalty_seconds)
        held = HeldSession(directory, ready, key, "session-key-replacement")
        try:
            vm.ssh("configureSSH", enabled=True, publicKey=replacement_public)
            ready = vm.ssh_ready()
            checks["keyReplacementRevokesSession"] = held.verify_terminated(vm)
        finally:
            held.close()
        checks["oldKeyDenied"] = verify_denied(directory, ready, key, "old-key-denied")
        checks["replacementLogin"] = verify_login(directory, ready, replacement_key, "replacement-login")
        vm.shell("touch /var/lib/omarchy/provisioning/pending")
        pending = vm.ssh("configureSSH", enabled=True, publicKey=replacement_public)
        require(pending["state"] == "pendingOwner" and pending["enabled"] is True, "Pending first owner must block SSH")
        checks["pendingOwner"] = {"reply": pending, **verify_stopped(vm, ready["address"])}
        vm.shell("rm /var/lib/omarchy/provisioning/pending")
        ready = vm.ssh_ready()
        checks["ownerReadyAgain"] = verify_login(directory, ready, replacement_key, "owner-ready-again")
        checks["actualDisplayModes"] = verify_display(vm, directory)
        held = HeldSession(directory, ready, replacement_key, "session-disable")
        try:
            disabled = vm.ssh("configureSSH", enabled=False)
            require(disabled["state"] == "disabled" and disabled["enabled"] is False, "SSH disable failed")
            checks["disableRevokesSession"] = held.verify_terminated(vm)
            checks["disableCleanup"] = verify_stopped(vm, ready["address"])
        finally:
            held.close()
        vm.shell("cp /var/lib/omabox/owner.json /mnt/qa-writable/owner-before-update.json && bash /mnt/build/install-ssh-integration.sh && cmp /var/lib/omabox/owner.json /mnt/qa-writable/owner-before-update.json")
        vm.shell('test "$(cat /usr/local/share/omabox/image-version)" -ge ' + str(metadata["integrationVersion"]))
        updater_stopped = verify_stopped(vm, ready["address"])
        updated = vm.ssh_status_when_available()
        require(updated["state"] == "disabled" and updated["enabled"] is False, "The integration updater must leave SSH disabled")
        checks["integrationUpdater"] = {"reply": updated, "ownerMarkerPreserved": True, "integrationVersionPreserved": True, **updater_stopped}
        vm.ssh("configureSSH", enabled=True, publicKey=replacement_public)
        before_reboot = vm.ssh_ready()
        checks["enabledBeforeReboot"] = verify_login(directory, before_reboot, replacement_key, "before-reboot")
        vm.shell("sync")
        vm.stop()
        vm = None
        print("Booting persisted authorization check", flush=True)
        vm = SSHVM(helper, directory, "second")
        report["boots"].append({"stage": "second", "consoleReadySeconds": round(vm.boot_seconds, 3)})
        guest_setup(vm)
        stopped_before_status = verify_stopped(vm)
        rebooted = vm.ssh()
        require(rebooted["state"] == "disabled" and rebooted["enabled"] is False, "Persisted SSH configuration must await authorization each boot")
        checks["rebootDisabled"] = {"reply": rebooted, "checkedBeforeStatusRequest": True, **stopped_before_status}
        vm.ssh("configureSSH", enabled=True, publicKey=replacement_public)
        after_reboot = vm.ssh_ready()
        require(after_reboot["hostPublicKey"] == before_reboot["hostPublicKey"], "Guest host key changed across cold boot")
        checks["explicitReauthorization"] = verify_login(directory, after_reboot, replacement_key, "after-reboot")
        checks["hostKeyPersisted"] = True
        vm.ssh("configureSSH", enabled=False)
        checks["finalCleanup"] = verify_stopped(vm, after_reboot["address"])
        report["passed"] = True
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        if vm:
            try:
                vm.shell("journalctl --no-pager -u omabox-ssh-agent.service -u omabox-sshd.service > /mnt/qa-writable/ssh-journal.txt; sync", timeout=20)
            except Exception:
                pass
            vm.stop()
            report["shutdownConfirmed"] = vm.process.returncode == 0 and b'"event":"stopped"' in vm.output
            if not report["shutdownConfirmed"]:
                report["passed"] = False
                report["error"] = "The disposable guest did not confirm a clean shutdown"
        report["finishedUTC"] = datetime.now(timezone.utc).isoformat()
        (directory / "ssh-report.json").write_text(json.dumps(report, indent=2) + "\n")
    require(report["passed"], report.get("error", "SSH QA did not complete"))
    print(json.dumps(report, indent=2))
    print("Evidence: " + str(directory))


if __name__ == "__main__":
    main()
