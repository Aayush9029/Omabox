#!/usr/bin/env python3
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile
import time

from check_ssh import ROOT, SSHVM, guest_setup, require
from prepare_guest import check, run


GUEST_ENVIRONMENT = "LP_NUM_THREADS=2\nGDK_SCALE=1\nOMABOX_DYNAMIC_RESOLUTION=1\n"
GUEST_LUA = "hl.config({ general = { gaps_in = 3 } })\n"
HOST_ENVIRONMENT = "LP_NUM_THREADS=1\nGDK_SCALE=2\nOMABOX_DYNAMIC_RESOLUTION=0\nOMABOX_QA_LITERAL=$(touch /tmp/omabox-host-config-executed)\n"
HOST_LUA = "hl.config({ general = { gaps_in = 7 } })\n"
CONFIG_MOUNT = "/mnt/omabox-config"


def guest_python(vm, source):
    vm.shell("python3 -c " + shlex.quote(source))


def user_session(vm):
    guest_setup(vm)
    vm.shell('uid=$(id -u omaboxqa) && instance=$(runuser -u omaboxqa -- env XDG_RUNTIME_DIR=/run/user/$uid hyprctl instances -j) && '
             'signature=$(printf %s "$instance" | python3 -c \'import json,sys; print(json.load(sys.stdin)[0]["instance"])\') && '
             'wayland=$(printf %s "$instance" | python3 -c \'import json,sys; print(json.load(sys.stdin)[0]["wl_socket"])\') && '
             'test -n "$signature" && test -n "$wayland"')
    vm.shell('user_run() { runuser -u omaboxqa -- env XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus HYPRLAND_INSTANCE_SIGNATURE="$signature" WAYLAND_DISPLAY="$wayland" "$@"; }; '
             'user_run systemctl --user is-active --quiet omabox-display-sync.service')


def write_guest_preferences(vm, environment, lua):
    guest_python(vm, "from pathlib import Path; import os,pwd; owner=pwd.getpwnam('omaboxqa'); root=Path('/home/omaboxqa/.config/omabox'); "
                 f"(root/'desktop.env').write_text({environment!r}); (root/'hyprland.lua').write_text({lua!r}); "
                 "os.chown(root/'desktop.env',owner.pw_uid,owner.pw_gid); os.chown(root/'hyprland.lua',owner.pw_uid,owner.pw_gid)")


def snapshot(vm, directory, label):
    guest_python(vm, "from pathlib import Path; import hashlib,json,subprocess; "
                 "pid=subprocess.check_output(['pgrep','-u','omaboxqa','-x','Hyprland'],text=True).strip(); "
                 "assert pid.isdigit(); "
                 "environment=dict(entry.split(b'=',1) for entry in Path('/proc/'+pid+'/environ').read_bytes().split(b'\\0') if b'=' in entry); "
                 "keys=['LP_NUM_THREADS','GDK_SCALE','OMABOX_GDK_SCALE','OMABOX_DYNAMIC_RESOLUTION','OMABOX_QA_LITERAL','LIBGL_ALWAYS_SOFTWARE','GALLIUM_DRIVER']; "
                 "root=Path('/home/omaboxqa/.config/omabox'); "
                 "report={'environment':{key:environment.get(key.encode(),b'').decode() for key in keys},"
                 "'guestFiles':{name:{'sha256':hashlib.sha256((root/name).read_bytes()).hexdigest(),'text':(root/name).read_text()} for name in ['desktop.env','hyprland.lua']},"
                 "'literalValueExecuted':Path('/tmp/omabox-host-config-executed').exists()}; "
                 f"Path('/mnt/qa-writable/{label}-state.json').write_text(json.dumps(report,indent=2)+'\\n')")
    vm.shell("user_run hyprctl getoption general.gaps_in -j > /mnt/qa-writable/" + label + "-gaps.json && "
             "user_run hyprctl monitors -j > /mnt/qa-writable/" + label + "-monitors.json && "
             "user_run hyprctl configerrors > /mnt/qa-writable/" + label + "-config-errors.txt")
    result = json.loads((directory / "exports" / (label + "-state.json")).read_text())
    result["gaps"] = json.loads((directory / "exports" / (label + "-gaps.json")).read_text())
    result["monitors"] = json.loads((directory / "exports" / (label + "-monitors.json")).read_text())
    errors = (directory / "exports" / (label + "-config-errors.txt")).read_text().strip()
    require(not errors, "Hyprland reported configuration errors: " + errors)
    return result


def assert_gaps(vm, result, expected):
    expression = 'local g = hl.get_config("general.gaps_in"); assert(g.top == ' + str(expected) + ' and g.left == ' + str(expected) + ' and g.right == ' + str(expected) + ' and g.bottom == ' + str(expected) + ', "configuration precedence failed")'
    vm.shell('response=$(user_run hyprctl eval ' + shlex.quote(expression) + '); test "$response" = ok')
    require("css" in result["gaps"], "Hyprland did not report CSS gaps: " + str(result["gaps"]))


def assert_environment(result, expected):
    for key, value in expected.items():
        require(result["environment"].get(key) == value, "Unexpected compositor environment: " + key + "=" + repr(result["environment"].get(key)))
    require(not result["literalValueExecuted"], "A literal host desktop.env value was executed as shell code")


def assert_guest_files(result, environment, lua):
    for name, expected in {"desktop.env": environment, "hyprland.lua": lua}.items():
        require(result["guestFiles"][name]["text"] == expected, "Host configuration changed the guest's " + name)


def read_only_mount(vm, directory):
    guest_python(vm, "import errno,json; from pathlib import Path; path=Path(" + repr(CONFIG_MOUNT + "/guest-root-write") + "); "
                 "result={'rootUID':__import__('os').geteuid()}; "
                 "exec(\"try:\\n path.write_text('unexpected')\\n result['writeSucceeded']=True\\nexcept OSError as error:\\n result.update(writeSucceeded=False,errno=error.errno)\"); "
                 "assert result.get('errno')==errno.EROFS and result['rootUID']==0, result; "
                 "Path('/mnt/qa-writable/read-only-config.json').write_text(json.dumps(result,indent=2)+'\\n')")
    vm.shell("findmnt --json " + CONFIG_MOUNT + " > /mnt/qa-writable/config-mount.json")
    result = json.loads((directory / "exports/read-only-config.json").read_text())
    mount = json.loads((directory / "exports/config-mount.json").read_text())["filesystems"][0]
    require(mount["source"] == "omabox-config" and mount["fstype"] == "virtiofs" and "ro" in mount["options"].split(","),
            "Expected the dedicated read-only VirtioFS config mount")
    require(not (directory / "host-config/guest-root-write").exists(), "Guest wrote into the host config directory")
    guest_python(vm, "from pathlib import Path; import json,pwd,stat; root=Path(" + repr(CONFIG_MOUNT) + "); owner=pwd.getpwnam('omaboxqa'); "
                 "paths=[root,root/'desktop.env',root/'hyprland.lua']; result={'guestOwnerUID':owner.pw_uid,'guestOwnerGID':owner.pw_gid,"
                 "'paths':[{'path':str(path),'uid':path.stat().st_uid,'gid':path.stat().st_gid,'mode':oct(stat.S_IMODE(path.stat().st_mode))} for path in paths]}; "
                 "Path('/mnt/qa-writable/guest-config-ownership.json').write_text(json.dumps(result,indent=2))")
    ownership = json.loads((directory / "exports/guest-config-ownership.json").read_text())
    return {"passed": True, **result, "mount": mount, "guestOwnership": ownership}


def verify_resize(vm, directory, label, requested, expected):
    vm.shell("user_run hyprctl monitors -j > /mnt/qa-writable/" + label + "-before-resize.json")
    before = json.loads((directory / "exports" / (label + "-before-resize.json")).read_text())
    require(len(before) == 1, "Expected one active Hyprland output before resizing")
    scale = before[0]["scale"]
    event = vm.control("resize", width=requested[0], height=requested[1])
    deadline = time.monotonic() + (3 if requested != expected else 15)
    actual = None
    while time.monotonic() < deadline:
        vm.delay(0.5)
        vm.shell("user_run hyprctl monitors -j > /mnt/qa-writable/" + label + "-resize.json")
        monitors = json.loads((directory / "exports" / (label + "-resize.json")).read_text())
        require(len(monitors) == 1, "Expected one active Hyprland output")
        actual = (monitors[0]["width"], monitors[0]["height"])
        require(monitors[0]["scale"] == scale, "Dynamic resolution changed the compositor scale")
        if requested == expected and actual == expected:
            break
        if requested != expected:
            require(actual == expected, "Host disabled dynamic resolution but the guest changed its mode")
    require(actual == expected, "Dynamic resolution did not respect configuration precedence: " + repr(actual))
    vm.shell("user_run systemctl --user is-active --quiet omabox-display-sync.service")
    return {"passed": True, "requested": list(requested), "actual": list(actual), "scale": scale, "synchronizerActive": True, "nativeControl": event}


def main():
    if len(sys.argv) != 1:
        raise RuntimeError("Usage: check_configuration.py")
    require(os.uname().machine == "arm64", "Configuration QA requires an Apple silicon Mac")
    artifacts = ROOT / "Artifacts"
    artifacts.mkdir(exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="guest-configuration-", dir=artifacts))
    directory.chmod(0o700)
    print("Evidence: " + str(directory), flush=True)
    for name in ("readonly", "exports", "host-config"):
        (directory / name).mkdir()
    (directory / "host-config").chmod(0o700)
    for name in ("desktop.env", "hyprland.lua"):
        path = directory / "host-config" / name
        path.write_text("")
        path.chmod(0o600)
    template = ROOT / "Omabox/Resources/Guest"
    metadata_data = (template / "metadata.json").read_bytes()
    metadata = json.loads(metadata_data)
    require(metadata.get("integrationVersion", 0) >= 3, "Prepare the integration 3 factory before running configuration QA")
    report = {"startedUTC": datetime.now(timezone.utc).isoformat(), "passed": False, "factoryIntegrity": metadata["integrity"],
              "integrationVersion": metadata["integrationVersion"], "boots": [], "checks": {}}
    vm = None

    def start(stage, provisioning=False):
        nonlocal vm
        print("Booting " + stage, flush=True)
        vm = SSHVM(helper, directory, stage, provisioning=provisioning)
        report["boots"].append({"stage": stage, "consoleReadySeconds": round(vm.boot_seconds, 3)})
        if not provisioning:
            user_session(vm)

    def stop():
        nonlocal vm
        if vm is None:
            return
        vm.stop()
        clean = vm.process.returncode == 0 and b'"event":"stopped"' in vm.output
        report["boots"][-1]["shutdownConfirmed"] = clean
        vm = None
        require(clean, "The disposable guest did not confirm a clean shutdown")

    try:
        for name in ("kernel", "initramfs", "rootfs.raw"):
            source = template / name
            require(not source.is_symlink(), "Factory artifact must not be a symlink")
            expected = metadata["integrity"][name]
            check(source, expected["sha256"], expected["byteCount"])
            run("cp", "-c", source, directory / name)
            require(source.stat().st_ino != (directory / name).stat().st_ino, "The QA disk must be a separate clone")
        (directory / "factory-metadata.json").write_bytes(metadata_data)
        (directory / "metadata.json").write_text(json.dumps({**metadata, "installedDiskMinimumBytes": (directory / "rootfs.raw").stat().st_size}, indent=2) + "\n")
        helper = directory / "SSHVM"
        run("xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", ROOT / "Scripts/QA/SSHVM.swift", "-o", helper)
        run("codesign", "--force", "--sign", "-", "--entitlements", ROOT / "Scripts/GuestBootstrap.entitlements", helper)
        start("provision", provisioning=True)
        vm.shell("mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev; "
                 "mount -t tmpfs tmpfs /run; modprobe virtiofs; mkdir -p /mnt/build; "
                 "mount -t virtiofs omabox-build /mnt/build; bash /mnt/build/qa-provision.sh && "
                 "test ! -e /var/lib/omarchy/provisioning/pending && /usr/local/libexec/omabox-record-owner.py", timeout=180)
        vm.shell("sync; mount -o remount,ro /")
        stop()
        start("fresh-defaults")
        vm.shell("cmp /usr/local/share/omabox/desktop.env /home/omaboxqa/.config/omabox/desktop.env && "
                 "cmp /usr/local/share/omabox/hyprland.lua /home/omaboxqa/.config/omabox/hyprland.lua")
        defaults = snapshot(vm, directory, "fresh-defaults")
        assert_environment(defaults, {"LP_NUM_THREADS": "2", "LIBGL_ALWAYS_SOFTWARE": "1", "GALLIUM_DRIVER": "llvmpipe"})
        report["checks"]["freshDefaults"] = {"passed": True, **defaults}
        report["checks"]["readOnlyHostMount"] = read_only_mount(vm, directory)
        vm.shell("runuser -u omaboxqa -- test -r " + CONFIG_MOUNT + "/desktop.env && runuser -u omaboxqa -- test -r " + CONFIG_MOUNT + "/hyprland.lua")
        report["checks"]["privateHostFilesReadableByOwner"] = {"passed": True, "hostDirectoryMode": "0700", "hostFileMode": "0600"}
        write_guest_preferences(vm, GUEST_ENVIRONMENT, GUEST_LUA)
        vm.shell("sync")
        stop()
        start("empty-host")
        empty_host = snapshot(vm, directory, "empty-host")
        assert_environment(empty_host, {"LP_NUM_THREADS": "2", "GDK_SCALE": "1", "OMABOX_DYNAMIC_RESOLUTION": "1"})
        assert_gaps(vm, empty_host, 3)
        assert_guest_files(empty_host, GUEST_ENVIRONMENT, GUEST_LUA)
        report["checks"]["emptyHostPreservesGuest"] = {"passed": True, **empty_host}
        report["checks"]["guestDynamicResolution"] = verify_resize(vm, directory, "empty-host", (1024, 768), (1024, 768))
        stop()
        (directory / "host-config/desktop.env").write_text(HOST_ENVIRONMENT)
        (directory / "host-config/hyprland.lua").write_text(HOST_LUA)
        start("host-overrides")
        host_overrides = snapshot(vm, directory, "host-overrides")
        assert_environment(host_overrides, {"LP_NUM_THREADS": "1", "GDK_SCALE": "2", "OMABOX_GDK_SCALE": "2", "OMABOX_DYNAMIC_RESOLUTION": "0",
                                           "OMABOX_QA_LITERAL": "$(touch /tmp/omabox-host-config-executed)"})
        assert_gaps(vm, host_overrides, 7)
        assert_guest_files(host_overrides, GUEST_ENVIRONMENT, GUEST_LUA)
        report["checks"]["hostOverridesGuest"] = {"passed": True, **host_overrides}
        report["checks"]["hostDisablesGuestDynamicResolution"] = verify_resize(vm, directory, "host-overrides", (1024, 768), (1440, 900))
        guest_disabled = GUEST_ENVIRONMENT.replace("OMABOX_DYNAMIC_RESOLUTION=1", "OMABOX_DYNAMIC_RESOLUTION=0")
        write_guest_preferences(vm, guest_disabled, GUEST_LUA)
        stop()
        (directory / "host-config/desktop.env").write_text(HOST_ENVIRONMENT.replace("OMABOX_DYNAMIC_RESOLUTION=0", "OMABOX_DYNAMIC_RESOLUTION=1"))
        (directory / "host-config/hyprland.lua").write_text("hl.config({ general = { gaps_in = 7 } }\n")
        start("malformed-host-lua")
        malformed = snapshot(vm, directory, "malformed-host-lua")
        assert_environment(malformed, {"LP_NUM_THREADS": "1", "GDK_SCALE": "2", "OMABOX_DYNAMIC_RESOLUTION": "1"})
        assert_gaps(vm, malformed, 3)
        assert_guest_files(malformed, guest_disabled, GUEST_LUA)
        report["checks"]["malformedHostLuaKeepsDesktopRunning"] = {"passed": True, **malformed}
        report["checks"]["hostEnablesGuestDynamicResolution"] = verify_resize(vm, directory, "malformed-host-lua", (1280, 800), (1280, 800))
        (directory / "host-config/desktop.env").write_text("")
        report["checks"]["emptyHostFallsBackToGuestDisabled"] = verify_resize(vm, directory, "empty-host-disabled", (1024, 768), (1280, 800))
        (directory / "host-config/desktop.env").unlink()
        report["checks"]["missingHostFallsBackToGuestDisabled"] = verify_resize(vm, directory, "missing-host-disabled", (1440, 900), (1280, 800))
        (directory / "host-config/desktop.env").write_text(HOST_ENVIRONMENT.replace("OMABOX_DYNAMIC_RESOLUTION=0", "OMABOX_DYNAMIC_RESOLUTION=1"))
        (directory / "host-config/desktop.env").chmod(0o600)
        vm.shell("user_run grim /home/omaboxqa/configuration-qa.png && cp /home/omaboxqa/configuration-qa.png /mnt/qa-writable/malformed-host-lua-desktop.png && "
                 "journalctl --no-pager _UID=1000 > /mnt/qa-writable/configuration-user-journal.txt && sync")
        vm.shell("sha256sum /home/omaboxqa/.config/omabox/desktop.env /home/omaboxqa/.config/omabox/hyprland.lua > /mnt/qa-writable/guest-preferences-before-update.sha256 && "
                 "bash /mnt/build/install-integration.sh && bash /mnt/build/install-integration.sh && "
                 "sha256sum -c /mnt/qa-writable/guest-preferences-before-update.sha256 && pgrep -u omaboxqa -x Hyprland >/dev/null && sync")
        report["checks"]["idempotentIntegrationUpdatePreservesPreferences"] = {"passed": True, "runs": 2}
        report["passed"] = True
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        try:
            stop()
        except Exception as error:
            report["passed"] = False
            report["shutdownError"] = str(error)
        report["shutdownConfirmed"] = bool(report["boots"]) and all(entry.get("shutdownConfirmed") for entry in report["boots"])
        report["finishedUTC"] = datetime.now(timezone.utc).isoformat()
        (directory / "configuration-report.json").write_text(json.dumps(report, indent=2) + "\n")
    require(report["passed"], report.get("shutdownError", "Configuration QA did not complete"))
    print(json.dumps(report, indent=2))
    print("Evidence: " + str(directory))


if __name__ == "__main__":
    main()
