#!/usr/bin/env python3
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import shlex
import sys
import tempfile
import time

from check_configuration import SSHVM, guest_python
from check_ssh import ROOT, generate_key, guest_setup, require, verify_login, verify_stopped
from prepare_guest import check, run


class ScalingVM(SSHVM):
    def __init__(self, helper, directory, stage, provisioning=False):
        launcher = directory / 'ScalingVM'
        launcher.write_text('#!/bin/bash\ncommand_line=${3/omabox.display_scale=1/omabox.display_scale=auto}\nexec ' + shlex.quote(str(helper)) + ' "$1" "$2" "$command_line"\n')
        launcher.chmod(0o700)
        super().__init__(launcher, directory, stage, provisioning=provisioning)


def create_fixture():
    artifacts = ROOT / 'Artifacts'
    artifacts.mkdir(exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix='guest-scaling-', dir=artifacts))
    directory.chmod(0o700)
    for name in ('readonly', 'exports', 'host-config'):
        (directory / name).mkdir()
    (directory / 'host-config').chmod(0o700)
    for name, content in {'desktop.env': 'OMABOX_DISPLAY_SCALE=auto\n', 'hyprland.lua': ''}.items():
        path = directory / 'host-config' / name
        path.write_text(content)
        path.chmod(0o600)
    template = ROOT / 'Omabox/Resources/Guest'
    metadata = json.loads((template / 'metadata.json').read_text())
    for name in ('kernel', 'initramfs', 'rootfs.raw'):
        source = template / name
        require(not source.is_symlink(), 'Factory artifacts must not be symlinks')
        expected = metadata['integrity'][name]
        check(source, expected['sha256'], expected['byteCount'])
        run('cp', '-c', source, directory / name)
        require(source.stat().st_ino != (directory / name).stat().st_ino, 'QA requires a separate disposable clone')
    (directory / 'factory-metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    (directory / 'metadata.json').write_text(json.dumps({**metadata, 'installedDiskMinimumBytes': (directory / 'rootfs.raw').stat().st_size}, indent=2) + '\n')
    helper = directory / 'SSHVM'
    run('xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', ROOT / 'Scripts/QA/SSHVM.swift', '-o', helper)
    run('codesign', '--force', '--sign', '-', '--entitlements', ROOT / 'Scripts/GuestBootstrap.entitlements', helper)
    print('Evidence: ' + str(directory), flush=True)
    vm = ScalingVM(helper, directory, 'provision', provisioning=True)
    try:
        vm.shell('mount -t proc proc /proc; mount -t sysfs sysfs /sys; mount -t devtmpfs devtmpfs /dev; '
                 'mount -t tmpfs tmpfs /run; modprobe virtiofs; mkdir -p /mnt/build; '
                 'mount -t virtiofs omabox-build /mnt/build; bash /mnt/build/qa-provision.sh && '
                 'test ! -e /var/lib/omarchy/provisioning/pending && /usr/local/libexec/omabox-record-owner.py', timeout=180)
        vm.shell('sync; mount -o remount,ro /')
    finally:
        vm.stop()
    require(vm.process.returncode == 0, 'Provisioning guest did not shut down cleanly')
    return directory


def run_probes(directory):
    report = {'startedUTC': datetime.now(timezone.utc).isoformat(), 'fixture': str(directory), 'passed': False}
    vm = ScalingVM(directory / 'SSHVM', directory, 'lua-interface-probe')
    try:
        guest_setup(vm)
        source = '''import json,pwd,subprocess,time
from pathlib import Path
owner=pwd.getpwnam('omaboxqa')
prefix=['runuser','-u',owner.pw_name,'--','env','XDG_RUNTIME_DIR=/run/user/'+str(owner.pw_uid)]
instances=[]
for attempt in range(20):
 raw=subprocess.check_output(prefix+['hyprctl','instances','-j'],text=True)
 try:
  instances=json.loads(raw)
  if len(instances)==1: break
 except ValueError:
  Path('/mnt/qa-writable/instances-startup-output.txt').write_text(raw)
 time.sleep(0.25)
assert len(instances)==1
prefix += ['HYPRLAND_INSTANCE_SIGNATURE='+instances[0]['instance'],'WAYLAND_DISPLAY='+instances[0]['wl_socket']]
probes=[('replReturn',['repl','return 1']),('replExpression',['repl','1']),('evalSetGlobal',['eval','OMABOX_QA_PROBE_VALUE = 731']),('replReadGlobal',['repl','OMABOX_QA_PROBE_VALUE']),('evalReadGlobal',['eval','assert(OMABOX_QA_PROBE_VALUE == 731)']),('replTable',['repl','{automatic=true, scale=1.25, output=""}'])]
report={}
for name,args in probes:
 result=subprocess.run(prefix+['hyprctl',*args],capture_output=True,text=True,timeout=10)
 report[name]={'exitCode':result.returncode,'stdout':result.stdout,'stderr':result.stderr}
path=Path('/usr/bin/start-hyprland')
contents=path.read_bytes()
report['launcher']={'path':str(path),'resolvedPath':str(path.resolve()),'isScript':contents.startswith(b'#!')}
if contents.startswith(b'#!'):
 Path('/mnt/qa-writable/start-hyprland-source.txt').write_bytes(contents)
else:
 result=subprocess.run(['strings',str(path)],capture_output=True,text=True,timeout=10)
 Path('/mnt/qa-writable/start-hyprland-strings.txt').write_text(result.stdout)
Path('/mnt/qa-writable/lua-interface-probes.json').write_text(json.dumps(report,indent=2))
'''
        guest_python(vm, source)
        report['probes'] = json.loads((directory / 'exports/lua-interface-probes.json').read_text())
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        vm.stop()
        report['shutdownConfirmed'] = vm.process.returncode == 0 and b'"event":"stopped"' in vm.output
        report['finishedUTC'] = datetime.now(timezone.utc).isoformat()
        (directory / 'scaling-probe-report.json').write_text(json.dumps(report, indent=2) + '\n')
    require(report['shutdownConfirmed'], 'Scaling probe guest did not shut down cleanly')
    print(json.dumps(report, indent=2))



def prepare_session(vm):
    guest_setup(vm)
    guest_python(vm, """import json,pwd,shlex,subprocess,time
from pathlib import Path
owner=pwd.getpwnam('omaboxqa')
uid=str(owner.pw_uid)
prefix=['runuser','-u',owner.pw_name,'--','env','XDG_RUNTIME_DIR=/run/user/'+uid]
instances=[]
for attempt in range(40):
 result=subprocess.run(prefix+['hyprctl','instances','-j'],capture_output=True,text=True,timeout=5)
 try:
  instances=json.loads(result.stdout)
  if len(instances)==1 and instances[0].get('instance') and instances[0].get('wl_socket'): break
 except ValueError:
  pass
 time.sleep(0.25)
assert len(instances)==1, instances
values={'uid':uid,'signature':instances[0]['instance'],'wayland':instances[0]['wl_socket']}
Path('/run/omabox-scaling-session.env').write_text('\\n'.join(key+'='+shlex.quote(value) for key,value in values.items())+'\\n')
""")
    vm.shell('. /run/omabox-scaling-session.env; user_run() { runuser -u omaboxqa -- env XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus HYPRLAND_INSTANCE_SIGNATURE="$signature" WAYLAND_DISPLAY="$wayland" "$@"; }; user_run hyprctl version >/dev/null')


def policy(vm, directory, label):
    vm.shell("user_run hyprctl repl 'return omabox_display_policy(\"Virtual-1\",\"\")' > /mnt/qa-writable/" + label + '-policy.txt')
    return (directory / 'exports' / (label + '-policy.txt')).read_text().strip()


def monitor(vm, directory, label):
    vm.shell('user_run hyprctl monitors -j > /mnt/qa-writable/' + label + '-monitors.json')
    values = json.loads((directory / 'exports' / (label + '-monitors.json')).read_text())
    require(len(values) == 1, 'Scaling QA requires one active monitor')
    return values[0]


def expect_mode(vm, directory, label, width, height, scale, *, request=True, hold=False):
    native = vm.control('resize', width=width, height=height) if request else None
    deadline = time.monotonic() + (3 if hold else 15)
    current = None
    while time.monotonic() < deadline:
        vm.delay(0.25)
        current = monitor(vm, directory, label)
        matches = (current['width'], current['height']) == (width, height) and math.isclose(current['scale'], scale, abs_tol=0.0051)
        if matches and not hold:
            break
        if hold:
            require(matches, 'An explicit desktop configuration changed unexpectedly: ' + str(current))
    require(current and (current['width'], current['height']) == (width, height) and math.isclose(current['scale'], scale, abs_tol=0.0051),
            'Unexpected actual display geometry or scale: ' + str(current))
    vm.shell('user_run systemctl --user is-active --quiet omabox-display-sync.service && user_run hyprctl configerrors > /mnt/qa-writable/' + label + '-config-errors.txt')
    errors = (directory / 'exports' / (label + '-config-errors.txt')).read_text().strip()
    require(not errors, 'Hyprland reported errors: ' + errors)
    return {'passed': True, 'width': current['width'], 'height': current['height'], 'scale': current['scale'], 'expectedScale': scale,
            'logicalWidth': round(width / scale), 'logicalHeight': round(height / scale), 'policy': policy(vm, directory, label), 'nativeControl': native}


def set_host_preferences(directory, scale='auto', dynamic=True):
    path = directory / 'host-config/desktop.env'
    path.write_text('OMABOX_DISPLAY_SCALE=' + str(scale) + '\nOMABOX_DYNAMIC_RESOLUTION=' + ('1' if dynamic else '0') + '\n')
    path.chmod(0o600)


def service_idle_snapshot(vm, directory, label):
    vm.shell('user_run systemctl --user show omabox-display-sync.service -p ActiveState -p MainPID -p NRestarts > /mnt/qa-writable/' + label + '-service.txt && '
             'journalctl --no-pager _UID=1000 _SYSTEMD_USER_UNIT=omabox-display-sync.service -o cat > /mnt/qa-writable/' + label + '-journal.txt')
    values = dict(line.split('=', 1) for line in (directory / 'exports' / (label + '-service.txt')).read_text().splitlines())
    require(values.get('ActiveState') == 'active' and int(values.get('MainPID', '0')) > 0, 'Display synchronizer is not running after reload')
    return {'mainPID': int(values['MainPID']), 'restartCount': int(values['NRestarts']),
            'synchronizationLogCount': (directory / 'exports' / (label + '-journal.txt')).read_text().count('Display synchronized:')}


def set_guest_lua(vm, value):
    guest_python(vm, "from pathlib import Path; import os,pwd; owner=pwd.getpwnam('omaboxqa'); path=Path(owner.pw_dir)/'.config/omabox/hyprland.lua'; "
                 'path.write_text(' + repr(value) + '); os.chown(path,owner.pw_uid,owner.pw_gid)')


def run_checks(directory):
    metadata = json.loads((directory / 'factory-metadata.json').read_text())
    report = {'startedUTC': datetime.now(timezone.utc).isoformat(), 'factoryIntegrity': metadata['integrity'], 'passed': False, 'checks': {}, 'boots': []}
    vm = None

    def start(stage):
        nonlocal vm
        print('Booting ' + stage + ': ' + str(directory), flush=True)
        vm = ScalingVM(directory / 'SSHVM', directory, stage)
        report['boots'].append({'stage': stage, 'consoleReadySeconds': round(vm.boot_seconds, 3)})
        prepare_session(vm)

    def stop():
        nonlocal vm
        if vm is None:
            return
        vm.stop()
        clean = vm.process.returncode == 0 and b'"event":"stopped"' in vm.output
        report['boots'][-1]['shutdownConfirmed'] = clean
        vm = None
        require(clean, 'The disposable scaling guest did not shut down cleanly')

    try:
        set_host_preferences(directory)
        (directory / 'host-config/hyprland.lua').write_text('')
        start('install-development-integration')
        set_guest_lua(vm, '')
        vm.shell('bash /mnt/build/install-integration.sh && test -r /usr/local/share/omabox/display-policy.lua && sync')
        stop()
        start('automatic-scaling')
        report['checks']['automaticStartup'] = expect_mode(vm, directory, 'automatic-startup', 1440, 900, 1.25, request=False)
        require(report['checks']['automaticStartup']['policy'] == 'automatic', 'Default host auto did not select automatic scaling')
        presets = [(512, 320, 0.5), (960, 600, 0.75), (1280, 800, 1.0), (1440, 900, 1.25), (1920, 1200, 1.5)]
        report['checks']['presets'] = []
        for width, height, scale in presets:
            report['checks']['presets'].append(expect_mode(vm, directory, f'preset-{width}x{height}', width, height, scale))
            vm.shell('user_run grim /home/omaboxqa/scaling-qa.png && cp /home/omaboxqa/scaling-qa.png /mnt/qa-writable/preset-' + str(width) + 'x' + str(height) + '.png')
        report['checks']['arbitraryFit'] = []
        fit_expectations = {(1500, 940): 1.25, (1496, 940): 4 / 3, (1511, 943): 1.0, (1504, 943): 1.0,
                            (1498, 938): 7 / 6, (1496, 938): 1.0, (1118, 694): 2 / 3, (1112, 694): 2 / 3}
        for width, height in [(1500, 940), (1511, 943), (1498, 938), (1118, 694)]:
            native = vm.control('resize', width=width, height=height)
            vm.delay(0.5)
            label = f'fit-{width}x{height}'
            vm.shell('user_run python3 /mnt/build/qa-display-mode.py --inspect-only > /mnt/qa-writable/' + label + '-drm.json')
            drm = json.loads((directory / 'exports' / (label + '-drm.json')).read_text())
            dimensions = (drm['mode']['hdisplay'], drm['mode']['vdisplay'])
            require(dimensions in ((width, height), (width // 8 * 8, height)), 'Unexpected native DRM dimensions for the requested resize: ' + repr(dimensions))
            result = expect_mode(vm, directory, label, *dimensions, fit_expectations[dimensions], request=False)
            result.update(requestedWidth=width, requestedHeight=height, nativeControl=native, drmPreferredMode=drm['mode'])
            report['checks']['arbitraryFit'].append(result)
        for width, height in [(800, 600), (1024, 768), (1440, 900), (960, 600), (1920, 1200), (512, 320), (1498, 938), (1280, 800)]:
            vm.control('resize', width=width, height=height)
        report['checks']['rapidResizeLatestWins'] = expect_mode(vm, directory, 'rapid-latest', 1280, 800, 1, request=False)
        set_host_preferences(directory, dynamic=False)
        vm.control('resize', width=1920, height=1200)
        report['checks']['dynamicDisabledPreservesGeometryAndScale'] = expect_mode(vm, directory, 'dynamic-disabled', 1280, 800, 1, request=False, hold=True)
        set_host_preferences(directory, dynamic=True)
        report['checks']['dynamicReenabled'] = expect_mode(vm, directory, 'dynamic-reenabled', 1440, 900, 1.25)
        stop()
        report['checks']['explicitEnvironmentScales'] = []
        for scale in (1, 2, 1.25):
            set_host_preferences(directory, scale=scale)
            label = 'environment-scale-' + str(scale)
            start(label)
            startup = expect_mode(vm, directory, label + '-startup', 1440, 900, scale, request=False)
            resized = expect_mode(vm, directory, label + '-resize', 1280, 800, scale)
            require(resized['policy'].startswith('fixed:') and math.isclose(float(resized['policy'][6:]), scale), 'Explicit environment scale was not preserved')
            report['checks']['explicitEnvironmentScales'].append({'startup': startup, 'resized': resized})
            if scale == 1.25:
                set_guest_lua(vm, 'hl.monitor({ output = "", scale = 2 })\n')
            stop()
        set_host_preferences(directory)
        run_manual_checks(directory, report)
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        try:
            stop()
        except Exception as error:
            report['passed'] = False
            report['shutdownError'] = str(error)
        report['shutdownConfirmed'] = bool(report['boots']) and all(entry.get('shutdownConfirmed') for entry in report['boots'])
        report['finishedUTC'] = datetime.now(timezone.utc).isoformat()
        (directory / 'scaling-report.json').write_text(json.dumps(report, indent=2) + '\n')
    require(report['passed'], report.get('shutdownError', 'Scaling QA did not complete'))
    print(json.dumps(report, indent=2))



def run_manual_checks(directory, report):
    vm = None

    def start(label):
        nonlocal vm
        print('Booting ' + label + ': ' + str(directory), flush=True)
        vm = ScalingVM(directory / 'SSHVM', directory, label)
        report['boots'].append({'stage': label, 'consoleReadySeconds': round(vm.boot_seconds, 3)})
        prepare_session(vm)

    def stop():
        nonlocal vm
        if vm is None:
            return
        vm.stop()
        clean = vm.process.returncode == 0 and b'"event":"stopped"' in vm.output
        report['boots'][-1]['shutdownConfirmed'] = clean
        vm = None
        require(clean, 'Manual scaling guest did not shut down cleanly')

    try:
        start('manual-lua-rules')
        report['checks']['guestLuaExplicitScale'] = expect_mode(vm, directory, 'guest-lua-scale-startup', 1440, 900, 2, request=False)
        report['checks']['guestLuaExplicitScaleAfterResize'] = expect_mode(vm, directory, 'guest-lua-scale-resize', 1280, 800, 2)
        vm.shell("response=$(user_run hyprctl eval 'hl.monitor({output=\"\",mode=\"1024x768\",scale=1})'); test \"$response\" = ok")
        vm.delay(0.5)
        accepted = monitor(vm, directory, 'manual-fallback-accepted')
        require(policy(vm, directory, 'manual-fallback-accepted') == 'manual' and accepted['scale'] == 1, 'Live fallback rule did not select manual policy and requested scale')
        vm.control('resize', width=1920, height=1200)
        manual = expect_mode(vm, directory, 'manual-fallback-rule', accepted['width'], accepted['height'], accepted['scale'], request=False, hold=True)
        manual['requestedManualMode'] = '1024x768'
        manual['acceptedBeforeNativeResize'] = {key: accepted[key] for key in ('width', 'height', 'scale')}
        manual['hyprlandRetainedPriorCustomModeline'] = (accepted['width'], accepted['height']) != (1024, 768)
        require(manual['policy'] == 'manual', 'Explicit fallback mode was not treated as manual')
        report['checks']['manualFallbackRulePreserved'] = manual
        vm.shell("response=$(user_run hyprctl eval 'hl.monitor({output=\"Virtual-1\",mode=\"1280x800\",scale=2})'); test \"$response\" = ok")
        vm.delay(0.5)
        accepted = monitor(vm, directory, 'manual-named-accepted')
        require(accepted['scale'] == 2, 'Live named rule did not apply the requested explicit scale')
        vm.control('resize', width=512, height=320)
        manual = expect_mode(vm, directory, 'manual-named-rule', accepted['width'], accepted['height'], accepted['scale'], request=False, hold=True)
        require(manual['policy'] == 'manual', 'Explicit named mode was not treated as manual')
        report['checks']['manualNamedRulePreserved'] = manual
        set_guest_lua(vm, '')
        stop()
        path = directory / 'host-config/hyprland.lua'
        path.write_text('hl.monitor({ output = "", mode = "1024x768", scale = 1 })\n')
        path.chmod(0o600)
        start('cold-manual-fallback')
        report['checks']['coldManualFallbackExactMode'] = expect_mode(vm, directory, 'cold-fallback-startup', 1024, 768, 1, request=False)
        vm.control('resize', width=1920, height=1200)
        result = expect_mode(vm, directory, 'cold-fallback-preserved', 1024, 768, 1, request=False, hold=True)
        require(result['policy'] == 'manual', 'Cold fallback manual policy was not preserved')
        report['checks']['coldManualFallbackPreserved'] = result
        stop()
        path.write_text('hl.monitor({ output = "Virtual-1", mode = "1280x800", scale = 2 })\n')
        start('cold-manual-named')
        report['checks']['coldManualNamedExactMode'] = expect_mode(vm, directory, 'cold-named-startup', 1280, 800, 2, request=False)
        vm.control('resize', width=512, height=320)
        result = expect_mode(vm, directory, 'cold-named-preserved', 1280, 800, 2, request=False, hold=True)
        require(result['policy'] == 'manual', 'Cold named manual policy was not preserved')
        report['checks']['coldManualNamedPreserved'] = result
        path.write_text('')
        vm.shell('journalctl --no-pager _UID=1000 _SYSTEMD_USER_UNIT=omabox-display-sync.service > /mnt/qa-writable/scaling-journal.txt && sync')
    finally:
        stop()


def finish_manual_checks(directory):
    report_path = directory / 'scaling-report.json'
    report = json.loads(report_path.read_text())
    require(len(report['checks'].get('presets', [])) == 5 and len(report['checks'].get('arbitraryFit', [])) == 4
            and len(report['checks'].get('explicitEnvironmentScales', [])) == 3, 'Complete the main scaling checks before the targeted manual continuation')
    prerequisites = ['automaticStartup', 'rapidResizeLatestWins', 'dynamicDisabledPreservesGeometryAndScale', 'dynamicReenabled']
    require(all(report['checks'].get(name, {}).get('passed') for name in prerequisites)
            and all(check.get('passed') for name in ('presets', 'arbitraryFit') for check in report['checks'][name])
            and all(check.get('passed') for entry in report['checks']['explicitEnvironmentScales'] for check in entry.values())
            and report['boots'] and all(entry.get('shutdownConfirmed') for entry in report['boots']),
            'The prerequisite scaling checks and shutdowns must have passed')
    if 'error' in report:
        report['supersededHarnessExpectation'] = report.pop('error')
    try:
        run_manual_checks(directory, report)
        report['passed'] = True
    except Exception as error:
        report['passed'] = False
        report['error'] = str(error)
        raise
    finally:
        report['shutdownConfirmed'] = all(entry.get('shutdownConfirmed') for entry in report['boots'])
        report['finishedUTC'] = datetime.now(timezone.utc).isoformat()
        report_path.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'passed': report['passed'], 'shutdownConfirmed': report['shutdownConfirmed'], 'checks': list(report['checks'])}, indent=2))


def existing_fixture(value):
    directory = Path(value).resolve()
    require(directory.parent == ROOT / 'Artifacts' and directory.name.startswith('guest-scaling-') and not (directory / 'rootfs.raw').is_symlink()
            and (directory / 'factory-metadata.json').is_file(), 'An existing disposable scaling fixture is required')
    return directory


def run_factory_smoke(directory):
    metadata = json.loads((directory / 'factory-metadata.json').read_text())
    require(metadata.get('integrationVersion', 0) >= 4, 'The final scaling factory must include integration 4')
    (directory / 'host-config/desktop.env').write_text('')
    key = directory / 'qa_ed25519'
    if key.exists():
        require(not key.is_symlink() and key.stat().st_mode & 0o077 == 0, 'Expected this disposable fixture private key')
        public_key = key.with_suffix('.pub').read_text().strip()
    else:
        key, public_key = generate_key(directory, 'qa_ed25519')
    report = {'startedUTC': datetime.now(timezone.utc).isoformat(), 'fixture': str(directory),
              'factoryIntegrity': metadata['integrity'], 'integrationVersion': metadata['integrationVersion'],
              'guestVersion': metadata.get('version'), 'factoryRootfsSHA256': metadata['integrity']['rootfs.raw']['sha256'],
              'passed': False, 'checks': {}}
    vm = ScalingVM(directory / 'SSHVM', directory, 'final-factory-smoke')
    try:
        prepare_session(vm)
        vm.shell('test "$(cat /usr/local/share/omabox/image-version)" -eq ' + str(metadata['integrationVersion']))
        source_paths = ['usr/local/share/omabox/display-policy.lua', 'usr/local/share/omabox/runtime.lua', 'usr/local/libexec/omabox-display-sync.py']
        guest_python(vm, 'import hashlib,json\nfrom pathlib import Path\npaths=' + repr(source_paths) + '\n'
                     'Path("/mnt/qa-writable/installed-source-hashes.json").write_text(json.dumps({path:hashlib.sha256(Path("/",path).read_bytes()).hexdigest() for path in paths},indent=2))\n'
                     'Path("/mnt/qa-writable/boot-command-line.txt").write_text(Path("/proc/cmdline").read_text())')
        installed = json.loads((directory / 'exports/installed-source-hashes.json').read_text())
        expected = {path: hashlib.sha256((ROOT / 'Guest/overlay' / path).read_bytes()).hexdigest() for path in source_paths}
        require(installed == expected, 'Installed final-factory scaling sources differ from the repository overlay')
        report['checks']['installedSourceHashes'] = {'passed': True, 'sha256': installed}
        report['guestBootCommandLine'] = (directory / 'exports/boot-command-line.txt').read_text().strip()
        initial = vm.ssh()
        require(initial['state'] == 'disabled' and initial['enabled'] is False, 'Final factory SSH must start disabled')
        report['checks']['initialDisabled'] = {'reply': initial, **verify_stopped(vm)}
        vm.ssh('configureSSH', enabled=True, publicKey=public_key)
        ready = vm.ssh_ready()
        report['checks']['enabledReply'] = ready
        report['checks']['pinnedNonrootLogin'] = verify_login(directory, ready, key, 'final-factory-owner-login')
        report['checks']['automaticStartup'] = expect_mode(vm, directory, 'final-auto-startup', 1440, 900, 1.25, request=False)
        report['checks']['automaticSmallPreset'] = expect_mode(vm, directory, 'final-auto-small', 512, 320, 0.5)
        report['checks']['automaticRetinaSize'] = expect_mode(vm, directory, 'final-auto-retina', 2560, 1600, 2)
        report['checks']['automaticRestoredPreset'] = expect_mode(vm, directory, 'final-auto-restored', 1440, 900, 1.25)
        require(all(report['checks'][name]['policy'] == 'automatic' for name in
                    ('automaticStartup', 'automaticSmallPreset', 'automaticRetinaSize', 'automaticRestoredPreset')),
                'An empty host configuration must use automatic scaling')
        vm.shell('response=$(user_run hyprctl reload); test "$response" = ok')
        vm.delay(0.5)
        recovered = expect_mode(vm, directory, 'final-auto-reload', 1440, 900, 1.25, request=False)
        require(recovered['policy'] == 'automatic', 'Final-factory reload did not retain automatic scaling')
        report['checks']['automaticReloadRecovery'] = recovered
        vm.delay(2)
        idle_before = service_idle_snapshot(vm, directory, 'final-reload-idle-before')
        vm.delay(3)
        idle_after = service_idle_snapshot(vm, directory, 'final-reload-idle-after')
        require(idle_before == idle_after, 'The final-factory display service did not settle after reload')
        report['checks']['idleServiceStableAfterReload'] = {'passed': True, 'durationSeconds': 3, 'before': idle_before, 'after': idle_after}
        vm.shell('user_run grim /home/omaboxqa/final-factory.png && cp /home/omaboxqa/final-factory.png /mnt/qa-writable/final-factory.png')
        disabled = vm.ssh('configureSSH', enabled=False)
        require(disabled['state'] == 'disabled' and disabled['enabled'] is False, 'Final factory SSH disable failed')
        report['checks']['disableCleanup'] = {'reply': disabled, **verify_stopped(vm, ready['address'])}
        vm.shell('cp /var/lib/omabox/owner.json /mnt/qa-writable/owner.json && sync')
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        vm.stop()
        report['shutdownConfirmed'] = vm.process.returncode == 0 and b'"event":"stopped"' in vm.output
        if not report['shutdownConfirmed']:
            report['passed'] = False
            report['error'] = 'The disposable final-factory guest did not confirm a clean shutdown'
        report['finishedUTC'] = datetime.now(timezone.utc).isoformat()
        (directory / 'final-factory-smoke-report.json').write_text(json.dumps(report, indent=2) + '\n')
    require(report['passed'], report.get('error', 'Final factory smoke failed'))
    print(json.dumps(report, indent=2))


def run_reload_checks(directory, update=False):
    set_host_preferences(directory)
    (directory / 'host-config/hyprland.lua').write_text('')
    if update:
        updating = ScalingVM(directory / 'SSHVM', directory, 'reload-integration-update')
        try:
            prepare_session(updating)
            set_guest_lua(updating, '')
            updating.shell('bash /mnt/build/install-integration.sh && sync')
        finally:
            updating.stop()
        require(updating.process.returncode == 0 and b'"event":"stopped"' in updating.output, 'Integration update guest did not stop cleanly')
    report = {'startedUTC': datetime.now(timezone.utc).isoformat(), 'fixture': str(directory), 'passed': False, 'checks': {}}
    vm = ScalingVM(directory / 'SSHVM', directory, 'configuration-reload')

    def reload_with_sentinel(label):
        vm.shell("response=$(user_run hyprctl eval 'OMABOX_QA_RELOAD_SENTINEL = 731'); test \"$response\" = ok && "
                 "test \"$(user_run hyprctl repl 'return OMABOX_QA_RELOAD_SENTINEL')\" = 731 && "
                 "response=$(user_run hyprctl reload); test \"$response\" = ok")
        vm.delay(0.5)
        vm.shell("user_run hyprctl repl 'return type(OMABOX_QA_RELOAD_SENTINEL)' > /mnt/qa-writable/" + label + '-sentinel.txt')
        value = (directory / 'exports' / (label + '-sentinel.txt')).read_text().strip()
        require(value == 'nil', 'The previous Lua global survived configuration reload: ' + value)
        immediate = monitor(vm, directory, label + '-before-resize-immediate')
        vm.delay(2)
        settled = monitor(vm, directory, label + '-before-resize-settled')
        return {'passed': True, 'sentinelBeforeReload': 731, 'sentinelTypeAfterReload': value,
                'monitorBeforeAnyNativeResize': {key: immediate[key] for key in ('width', 'height', 'scale')},
                'monitorBeforeAnyNativeResizeAfterTwoSeconds': {key: settled[key] for key in ('width', 'height', 'scale')},
                'policyBeforeNativeResize': policy(vm, directory, label + '-before-resize')}

    try:
        prepare_session(vm)
        set_guest_lua(vm, '')
        source_paths = ['usr/local/share/omabox/display-policy.lua', 'usr/local/share/omabox/runtime.lua', 'usr/local/libexec/omabox-display-sync.py']
        guest_python(vm, 'import hashlib,json\nfrom pathlib import Path\npaths=' + repr(source_paths) + '\n'
                     'Path("/mnt/qa-writable/reload-source-hashes.json").write_text(json.dumps({path:hashlib.sha256(Path("/",path).read_bytes()).hexdigest() for path in paths},indent=2))')
        installed = json.loads((directory / 'exports/reload-source-hashes.json').read_text())
        expected = {path: hashlib.sha256((ROOT / 'Guest/overlay' / path).read_bytes()).hexdigest() for path in source_paths}
        require(installed == expected, 'Reload QA must use the final shipped scaling source')
        report['checks']['installedSourceHashes'] = {'passed': True, 'sha256': installed}
        report['checks']['automaticBeforeReload'] = expect_mode(vm, directory, 'before-first-reload', 1440, 900, 1.25, request=False)
        report['checks']['firstReloadResetsLuaGlobal'] = reload_with_sentinel('reload-automatic')
        settled = report['checks']['firstReloadResetsLuaGlobal']['monitorBeforeAnyNativeResizeAfterTwoSeconds']
        report['checks']['automaticRestoredWithoutNativeResize'] = {
            'passed': (settled['width'], settled['height'], settled['scale']) == (1440, 900, 1.25), 'actual': settled,
            'expected': {'width': 1440, 'height': 900, 'scale': 1.25}}
        idle_before = service_idle_snapshot(vm, directory, 'reload-idle-before')
        vm.delay(3)
        idle_after = service_idle_snapshot(vm, directory, 'reload-idle-after')
        report['checks']['idleServiceStableAfterReload'] = {'passed': idle_before == idle_after, 'durationSeconds': 3, 'before': idle_before, 'after': idle_after}
        automatic = expect_mode(vm, directory, 'reload-automatic-resize', 960, 600, 0.75)
        require(automatic['policy'] == 'automatic', 'Reload did not restore the automatic policy')
        report['checks']['automaticResizeAfterReload'] = automatic
        set_guest_lua(vm, 'hl.monitor({ output = "", scale = 1.25 })\n')
        report['checks']['secondReloadResetsLuaGlobal'] = reload_with_sentinel('reload-custom')
        numeric = expect_mode(vm, directory, 'reload-custom-resize', 1280, 800, 1.25)
        require(numeric['policy'] == 'fixed:1.25', 'Reloaded custom Lua scale was not preserved')
        report['checks']['customScaleAfterReload'] = numeric
        report['checks']['customScaleSecondResize'] = expect_mode(vm, directory, 'reload-custom-second-resize', 1440, 900, 1.25)
        vm.shell("response=$(user_run hyprctl eval 'hl.monitor({output=\"\",mode=\"1024x768\",scale=1})'); test \"$response\" = ok")
        vm.delay(0.5)
        accepted = monitor(vm, directory, 'reload-manual-accepted')
        require(accepted['scale'] == 1 and policy(vm, directory, 'reload-manual-accepted') == 'manual', 'Reloaded observer did not identify the manual override')
        vm.control('resize', width=1920, height=1200)
        manual = expect_mode(vm, directory, 'reload-manual-preserved', accepted['width'], accepted['height'], accepted['scale'], request=False, hold=True)
        require(manual['policy'] == 'manual', 'Manual override policy changed after native resize')
        report['checks']['manualOverrideAfterReload'] = manual
        set_guest_lua(vm, 'hl.monitor({ output = "", mode = "1024x768", scale = 1 })\n')
        report['checks']['manualPreferenceReloadResetsLuaGlobal'] = reload_with_sentinel('reload-manual-preference')
        manual_state = monitor(vm, directory, 'reload-manual-preference-accepted')
        require(manual_state['scale'] == 1 and policy(vm, directory, 'reload-manual-preference-accepted') == 'manual', 'Reload did not restore the explicit manual preference')
        vm.control('resize', width=1280, height=800)
        manual = expect_mode(vm, directory, 'reload-manual-preference-held', manual_state['width'], manual_state['height'], manual_state['scale'], request=False, hold=True)
        require(manual['policy'] == 'manual', 'The service restart overrode a manual preference after reload')
        report['checks']['manualPreferencePreservedAfterReload'] = manual
        set_guest_lua(vm, '')
        vm.shell('sync')
        report['passed'] = all(check.get('passed') for check in report['checks'].values())
        if not report['passed']:
            report['error'] = 'Reload checks failed: ' + ', '.join(name for name, check in report['checks'].items() if not check.get('passed'))
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        vm.stop()
        report['shutdownConfirmed'] = vm.process.returncode == 0 and b'"event":"stopped"' in vm.output
        report['passed'] = report['passed'] and report['shutdownConfirmed']
        report['finishedUTC'] = datetime.now(timezone.utc).isoformat()
        (directory / 'scaling-reload-report.json').write_text(json.dumps(report, indent=2) + '\n')
    require(report['passed'], report.get('error', 'The reload check did not finish cleanly'))
    print(json.dumps(report, indent=2))


def main():
    require(os.uname().machine == 'arm64', 'Scaling QA requires an Apple silicon Mac')
    if not sys.argv[1:]:
        run_checks(create_fixture())
    elif sys.argv[1:] == ['--probe']:
        run_probes(create_fixture())
    elif sys.argv[1:] == ['--factory-smoke']:
        run_factory_smoke(create_fixture())
    elif len(sys.argv) == 3 and sys.argv[1] == '--factory-smoke-existing':
        run_factory_smoke(existing_fixture(sys.argv[2]))
    elif len(sys.argv) == 3 and sys.argv[1] == '--reload-existing':
        run_reload_checks(existing_fixture(sys.argv[2]))
    elif len(sys.argv) == 3 and sys.argv[1] == '--update-reload-existing':
        run_reload_checks(existing_fixture(sys.argv[2]), update=True)
    elif len(sys.argv) == 3 and sys.argv[1] == '--probe-existing':
        run_probes(existing_fixture(sys.argv[2]))
    elif len(sys.argv) == 3 and sys.argv[1] == '--manual-existing':
        finish_manual_checks(existing_fixture(sys.argv[2]))
    elif len(sys.argv) == 3 and sys.argv[1] == '--resume':
        run_checks(existing_fixture(sys.argv[2]))
    else:
        raise RuntimeError('Usage: check_scaling.py [--probe | --factory-smoke | --factory-smoke-existing DIRECTORY | --reload-existing DIRECTORY | --update-reload-existing DIRECTORY | --probe-existing DIRECTORY | --resume DIRECTORY | --manual-existing DIRECTORY]')



if __name__ == '__main__':
    main()
