#!/bin/bash

release_die() {
    echo "Release error: $*" >&2
    exit 1
}

release_absolute_path() {
    python3 - "$release_root" "$1" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[2]).expanduser()
print(path.absolute() if path.is_absolute() else (Path(sys.argv[1]) / path).absolute())
PY
}

release_configure() {
    release_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    [[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || release_die 'Use an Apple silicon Mac.'
    command -v python3 >/dev/null || release_die 'python3 is required.'
    [[ ${OMABOX_VERSION:-} =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || release_die 'Set OMABOX_VERSION to a numeric release version, such as 0.1.0.'
    [[ ${OMABOX_BUILD_NUMBER:-} =~ ^[1-9][0-9]*$ ]] || release_die 'Set OMABOX_BUILD_NUMBER to a positive integer.'
    release_team=${OMABOX_TEAM_ID:-6Q29HJZ4AG}
    [[ $release_team =~ ^[A-Z0-9]{10}$ ]] || release_die 'OMABOX_TEAM_ID must be a ten-character Apple team identifier.'
    release_identity=${OMABOX_SIGNING_IDENTITY:-}
    [[ -n $release_identity && $release_identity != '-' ]] || release_die 'Set OMABOX_SIGNING_IDENTITY to a Developer ID Application identity or certificate SHA-1.'
    release_version=$OMABOX_VERSION
    release_build=$OMABOX_BUILD_NUMBER
    release_name="Omabox-$release_version-$release_build"
    release_archive=$(release_absolute_path "${OMABOX_ARCHIVE_PATH:-build/Archives/$release_name.xcarchive}")
    release_export=$(release_absolute_path "${OMABOX_EXPORT_PATH:-build/Export/$release_name}")
    release_output=$(release_absolute_path "${OMABOX_RELEASE_PATH:-build/Release/$release_name}")
    release_app="$release_export/Omabox.app"
    release_signing_flags='--timestamp'
    if [[ -n ${OMABOX_KEYCHAIN_PATH:-} ]]; then
        release_keychain=$(release_absolute_path "$OMABOX_KEYCHAIN_PATH")
        [[ -f $release_keychain ]] || release_die "Signing keychain does not exist: $release_keychain"
        release_signing_flags="--timestamp --keychain $(python3 -c 'import shlex,sys; print(shlex.quote(sys.argv[1]))' "$release_keychain")"
    fi
}

release_claim_destination() {
    local destination=$1
    [[ ! -e $destination && ! -L $destination ]] || release_die "Destination already exists; choose a new path: $destination"
    mkdir -p "$(dirname "$destination")"
    release_lock_path="$destination.lock"
    mkdir "$release_lock_path" 2>/dev/null || release_die "Destination is reserved by another release operation: $destination"
    trap 'rmdir "$release_lock_path" 2>/dev/null || true' EXIT
    [[ ! -e $destination && ! -L $destination ]] || release_die "Destination already exists: $destination"
}

release_verify_app() {
    python3 - "$1" "$release_version" "$release_build" "$release_team" <<'PY'
from pathlib import Path
import os
import plistlib
import re
import subprocess
import sys

app = Path(sys.argv[1])
version, build, team = sys.argv[2:]

def require(condition, message):
    if not condition:
        raise SystemExit(f"Release verification failed: {message}")

def run(*arguments):
    result = subprocess.run(arguments, capture_output=True, text=True)
    require(result.returncode == 0, result.stderr.strip() or " ".join(arguments))
    return result.stdout, result.stderr

require(app.is_dir() and not app.is_symlink(), f"Missing app bundle: {app}")
with (app / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
require(info.get("CFBundleIdentifier") == "ca.optimalapps.omabox", "Unexpected bundle identifier")
require(info.get("CFBundleShortVersionString") == version, "App version does not match OMABOX_VERSION")
require(info.get("CFBundleVersion") == build, "App build does not match OMABOX_BUILD_NUMBER")
minimum = info.get("LSMinimumSystemVersion", "")
require(re.fullmatch(r"26(?:\.\d+){0,2}", minimum) is not None, "The release must retain its macOS 26 deployment target")
run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
stdout, stderr = run("/usr/bin/codesign", "--display", "--verbose=4", str(app))
signature = stdout + stderr
require(f"TeamIdentifier={team}" in signature, "Signing team does not match OMABOX_TEAM_ID")
require("Authority=Developer ID Application:" in signature, "App is not Developer ID Application signed")
require(re.search(r"flags=.*\bruntime\b", signature) is not None, "Hardened runtime is disabled")
require("Timestamp=" in signature, "A secure signing timestamp is missing")
entitlements, _ = run("/usr/bin/codesign", "--display", "--entitlements", ":-", str(app))
values = plistlib.loads(entitlements.encode())
required = (
    "com.apple.security.app-sandbox",
    "com.apple.security.virtualization",
    "com.apple.security.network.client",
    "com.apple.security.files.user-selected.read-write",
    "com.apple.security.files.bookmarks.app-scope",
    "com.apple.security.device.audio-input",
)
for name in required:
    require(values.get(name) is True, f"Required entitlement is missing: {name}")
for name in (
    "com.apple.security.get-task-allow",
    "com.apple.security.cs.allow-jit",
    "com.apple.security.cs.allow-unsigned-executable-memory",
    "com.apple.security.cs.disable-library-validation",
    "com.apple.security.cs.disable-executable-page-protection",
):
    require(not values.get(name, False), f"Unexpected release entitlement: {name}")
executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
architectures, _ = run("/usr/bin/lipo", "-archs", str(executable))
require(architectures.strip() == "arm64", "App executable must contain only arm64")
mach_o_magic = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
for directory, subdirectories, files in os.walk(app):
    if Path(directory) == app / "Contents/Resources":
        subdirectories[:] = [name for name in subdirectories if name != "Guest"]
    for name in files:
        path = Path(directory) / name
        if path.is_symlink():
            continue
        with path.open("rb") as stream:
            magic = stream.read(4)
        if magic in mach_o_magic:
            architectures, _ = run("/usr/bin/lipo", "-archs", str(path))
            require(architectures.strip() == "arm64", f"Non-arm64 nested binary: {path.relative_to(app)}")
print(f"Verified Developer ID app: {app}")
PY
}
