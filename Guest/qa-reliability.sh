#!/bin/bash
set -euo pipefail
exec python3 - "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import platform
import pwd
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
import wave


MODE = sys.argv[1] if len(sys.argv) == 2 else ""
WRITABLE = Path("/mnt/qa-writable")
READONLY = Path("/mnt/qa-readonly")
BOOT_ID = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
report = {"schemaVersion": 1, "mode": MODE, "bootID": BOOT_ID, "uptimeAtStartSeconds": float(Path("/proc/uptime").read_text().split()[0]), "checks": {}}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def command(*arguments, timeout=15):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
    require(result.returncode == 0, f"{arguments[0]} exited {result.returncode}: {result.stderr.strip()[:1024]}")
    return result.stdout.strip()


def check(name, operation):
    started = time.monotonic()
    try:
        details = operation()
        report["checks"][name] = {"passed": True, **details}
    except Exception as error:
        report["checks"][name] = {"passed": False, "error": str(error)[:2048]}
    report["checks"][name]["elapsedSeconds"] = round(time.monotonic() - started, 6)
    print("OMABOX_RELIABILITY_CHECK " + name + " " + json.dumps(report["checks"][name]), flush=True)


def mount_share(tag, path):
    path.mkdir(parents=True, exist_ok=True)
    require(not os.path.ismount(path), f"Unexpected existing mount: {path}")
    command("mount", "-t", "virtiofs", "-o", "rw,nosuid,nodev", tag, str(path))
    fields = command("findmnt", "-n", "-o", "SOURCE,FSTYPE,OPTIONS", "-M", str(path)).split()
    require(len(fields) == 3 and fields[0] == tag and fields[1] == "virtiofs", "Unexpected share mount")
    return {"tag": tag, "requestedMountMode": "rw", "reportedOptions": fields[2]}


def writable_share():
    return mount_share("qa-writable", WRITABLE)


def readonly_share():
    details = mount_share("qa-readonly", READONLY)
    require("rw" in details["reportedOptions"].split(","), "Guest must request and retain a rw mount to test host write rejection")
    try:
        expected = b"omabox-qa-readonly-v1\n"
        require((READONLY / "readonly-sentinel.txt").read_bytes() == expected, "Readonly host fixture did not match")
        probe = READONLY / ("omabox-write-probe-" + BOOT_ID)
        try:
            with probe.open("xb") as stream:
                stream.write(b"This write must be rejected.\n")
                stream.flush()
                os.fsync(stream.fileno())
        except OSError as error:
            require(error.errno in (1, 13, 30), f"Unexpected write failure: {error}")
            details["writeErrno"] = error.errno
            details["hostRejectedWrite"] = True
        else:
            probe.unlink()
            raise RuntimeError("Readonly host share allowed a root write through a rw guest mount")
        details["fixtureSHA256"] = hashlib.sha256(expected).hexdigest()
        return details
    finally:
        command("mount", "-o", "remount,ro", str(READONLY))


def durable_json(path, value, exclusive=False):
    encoded = (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()
    flags = os.O_WRONLY | os.O_CREAT | (os.O_EXCL if exclusive else os.O_TRUNC)
    descriptor = os.open(path, flags, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(encoded)
        stream.flush()
        os.fsync(stream.fileno())
    descriptor = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def persistence():
    require(report["checks"]["writableShare"]["passed"], "Writable VirtioFS share is unavailable")
    path = WRITABLE / "persisted-sentinel.json"
    payload = "omabox-virtiofs-persistence-v1\n" * 1024
    digest = hashlib.sha256(payload.encode()).hexdigest()
    if MODE == "first":
        value = {"schemaVersion": 1, "firstBootID": BOOT_ID, "payload": payload, "sha256": digest}
        durable_json(path, value, exclusive=True)
    else:
        value = json.loads(path.read_text())
        require(value["firstBootID"] != BOOT_ID, "Persistence must be tested after a different Linux boot")
        require(value["schemaVersion"] == 1, "Unexpected persisted sentinel version")
    stored = json.loads(path.read_text())
    require(stored["payload"] == payload and stored["sha256"] == digest, "Persisted host share content changed")
    return {"sha256": digest, "byteCount": len(payload.encode()), "firstBootID": stored["firstBootID"], "survivedReboot": MODE == "second"}


NETWORK_SCRIPT = r'''
import json
import socket
import urllib.request
from urllib.parse import urlparse
addresses = sorted({entry[4][0] for entry in socket.getaddrinfo("archlinuxarm.org", 443, family=socket.AF_INET, type=socket.SOCK_STREAM)})
class OfficialRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        parsed = urlparse(newurl)
        if parsed.scheme != "https" or parsed.hostname not in {"archlinuxarm.org", "www.archlinuxarm.org"}:
            raise RuntimeError("Unexpected HTTPS redirect")
        return super().redirect_request(request, fp, code, message, headers, newurl)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), OfficialRedirects())
request = urllib.request.Request("https://archlinuxarm.org/", headers={"User-Agent": "Omabox-Guest-Reliability/1.0"})
with opener.open(request, timeout=8) as response:
    body = response.read(1024)
    assert response.status == 200 and body
    print(json.dumps({"dnsAddressCount": len(addresses), "dnsAddresses": addresses, "httpStatus": response.status, "sampleByteCount": len(body), "url": response.url, "tlsCertificateVerified": True}))
'''


def networking():
    routes = [line.split() for line in Path("/proc/net/route").read_text().splitlines()[1:]]
    defaults = [route[0] for route in routes if route[1] == "00000000" and int(route[3], 16) & 2]
    require(defaults, "No IPv4 default route was configured by the NAT network")
    failures = []
    for attempt in range(1, 3):
        try:
            value = json.loads(command(sys.executable, "-I", "-c", NETWORK_SCRIPT, timeout=20))
            value.update({"attempt": attempt, "defaultRouteInterfaces": defaults})
            return value
        except Exception as error:
            failures.append(str(error))
            if attempt == 1:
                time.sleep(2)
    raise RuntimeError("DNS/HTTPS failed after two bounded attempts: " + "; ".join(failures))


ALSA_SCRIPT = r'''
import ctypes
import ctypes.util
import json
import sys
import wave
library = ctypes.util.find_library("asound")
if not library:
    raise RuntimeError("libasound is unavailable")
alsa = ctypes.CDLL(library)
pointer = ctypes.c_void_p
alsa.snd_pcm_open.argtypes = [ctypes.POINTER(pointer), ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
alsa.snd_pcm_open.restype = ctypes.c_int
alsa.snd_pcm_set_params.argtypes = [pointer, ctypes.c_int, ctypes.c_int, ctypes.c_uint, ctypes.c_uint, ctypes.c_int, ctypes.c_uint]
alsa.snd_pcm_set_params.restype = ctypes.c_int
alsa.snd_pcm_writei.argtypes = [pointer, pointer, ctypes.c_ulong]
alsa.snd_pcm_writei.restype = ctypes.c_long
alsa.snd_pcm_drain.argtypes = [pointer]
alsa.snd_pcm_drain.restype = ctypes.c_int
alsa.snd_pcm_drop.argtypes = [pointer]
alsa.snd_pcm_drop.restype = ctypes.c_int
alsa.snd_pcm_close.argtypes = [pointer]
alsa.snd_pcm_close.restype = ctypes.c_int
alsa.snd_strerror.argtypes = [ctypes.c_int]
alsa.snd_strerror.restype = ctypes.c_char_p
def checked(result):
    if result < 0:
        raise RuntimeError(alsa.snd_strerror(result).decode("utf-8", "replace") + f" ({result})")
    return result
handle = pointer()
checked(alsa.snd_pcm_open(ctypes.byref(handle), sys.argv[1].encode(), 0, 0))
drained = False
try:
    with wave.open(sys.argv[2], "rb") as stream:
        frames = stream.getnframes()
        channels = stream.getnchannels()
        checked(alsa.snd_pcm_set_params(handle, 2, 3, channels, stream.getframerate(), 0, 500000))
        samples = stream.readframes(frames)
    buffer = ctypes.create_string_buffer(samples)
    written = 0
    while written < frames:
        count = checked(alsa.snd_pcm_writei(handle, ctypes.byref(buffer, written * channels * 2), frames - written))
        if not 0 < count <= frames - written:
            raise RuntimeError("ALSA returned invalid write progress")
        written += count
    checked(alsa.snd_pcm_drain(handle))
    drained = True
    print(json.dumps({"framesWritten": written, "api": "libasound"}))
finally:
    if not drained:
        alsa.snd_pcm_drop(handle)
    checked(alsa.snd_pcm_close(handle))
'''


def audio():
    pcm = Path("/proc/asound/pcm").read_text()
    match = re.search(r"^(\d+)-(\d+):[^\n]*virtio[^\n]*playback\s+1", pcm, re.MULTILINE)
    require(match is not None, "No VirtIO PCM playback device was enumerated")
    device = f"hw:{int(match[1])},{int(match[2])}"
    frames = 48000 * 2
    with tempfile.TemporaryDirectory(prefix="omabox-audio-", dir="/run") as directory:
        path = Path(directory) / "silence.wav"
        with wave.open(str(path), "wb") as stream:
            stream.setnchannels(2)
            stream.setsampwidth(2)
            stream.setframerate(48000)
            stream.writeframes(bytes(frames * 4))
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        def play():
            if shutil.which("aplay"):
                command("aplay", "-q", "-D", device, str(path), timeout=12)
                return {"framesWritten": frames, "api": "aplay"}
            return json.loads(command(sys.executable, "-I", "-c", ALSA_SCRIPT, device, str(path), timeout=12))
        try:
            result = play()
            result["releasedQAUserAudio"] = False
        except RuntimeError as error:
            if "(-16)" not in str(error) and "Device or resource busy" not in str(error):
                raise
            uid = pwd.getpwnam("omaboxqa").pw_uid
            user_command = ["runuser", "-u", "omaboxqa", "--", "env", f"XDG_RUNTIME_DIR=/run/user/{uid}", f"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{uid}/bus", "systemctl", "--user"]
            units = ["wireplumber.service", "pipewire-pulse.socket", "pipewire-pulse.service", "pipewire.socket", "pipewire.service"]
            active = [unit for unit in units if subprocess.run([*user_command, "is-active", "--quiet", unit], timeout=5).returncode == 0]
            require(active, "VirtIO PCM is busy, but no disposable QA audio service can be released")
            try:
                command(*user_command, "stop", *units)
                result = play()
                result["releasedQAUserAudio"] = True
                result["restoredQAUnits"] = active
            finally:
                command(*user_command, "start", *active)
    require(result["framesWritten"] == frames, "The entire PCM stream was not accepted")
    return {**result, "device": device, "sampleRate": 48000, "channels": 2, "sampleFormat": "S16_LE", "digitalSilence": True, "waveSHA256": digest}


def cpu_workload():
    seed = 0x4F4D41424F58
    payload = random.Random(seed).randbytes(16 * 1024 * 1024)
    expected = hashlib.sha256(payload).hexdigest()
    iterations = 32
    started = time.perf_counter()
    for _ in range(iterations):
        require(hashlib.sha256(payload).hexdigest() == expected, "SHA-256 workload returned inconsistent output")
    elapsed = time.perf_counter() - started
    details = {"seed": seed, "inputByteCount": len(payload), "iterations": iterations, "sha256": expected, "workloadSeconds": round(elapsed, 6), "mebibytesPerSecond": round(len(payload) * iterations / 1048576 / elapsed, 3), "logicalCPUCount": os.cpu_count()}
    if MODE == "second":
        first = json.loads((WRITABLE / "reliability-first.json").read_text())["checks"]["cpu"]
        require(first["passed"] and first["sha256"] == expected, "CPU workload did not match the previous boot")
        details["matchesPreviousBoot"] = True
    return details


require(MODE in {"first", "second"}, "Usage: qa-reliability.sh first|second")
require(os.geteuid() == 0 and platform.machine() == "aarch64", "Run as root in the native ARM64 test guest")
require(Path("/proc/1/comm").read_text().strip() == "systemd", "Run after a normal systemd boot")
require(Path("/home/omaboxqa").is_dir() and not Path("/var/lib/omarchy/provisioning/pending").exists(), "Disposable QA user fixture is required")
check("writableShare", writable_share)
check("readonlyShare", readonly_share)
check("persistence", persistence)
check("natDNSAndHTTPS", networking)
check("audioPCM", audio)
check("cpu", cpu_workload)
report["passed"] = all(value["passed"] for value in report["checks"].values())
report["uptimeAtEndSeconds"] = float(Path("/proc/uptime").read_text().split()[0])
if report["checks"]["writableShare"]["passed"]:
    temporary = WRITABLE / ("reliability-" + MODE + ".json.tmp")
    destination = WRITABLE / ("reliability-" + MODE + ".json")
    durable_json(temporary, report)
    os.replace(temporary, destination)
    descriptor = os.open(WRITABLE, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
print("OMABOX_RELIABILITY_REPORT " + json.dumps(report, sort_keys=True), flush=True)
sys.exit(0 if report["passed"] else 1)
PY
