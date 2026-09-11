#!/usr/bin/env python3
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, build_opener


ROOT = Path(__file__).resolve().parent.parent
SOURCE_TREES = ("Guest/overlay", "Guest/virtio-sound-source")
SOURCE_FILES = (
    "Guest/adapt-guest.sh", "Guest/source.json", "Scripts/prepare_guest.py",
    "Scripts/prepare-guest.sh", "Scripts/GuestBootstrap.swift", "Scripts/GuestBootstrap.entitlements",
)
GUEST_FILES = (
    "metadata.json", "guest-manifest.json", "provenance.json", "build-spec.json",
    "packages.lock.txt", "LICENSE.omarchy", "kernel", "initramfs", "rootfs.raw",
)
CHUNK_BYTES = 8 * 1024 * 1024
RENAME_EXCL = 0x00000004


class PreparedGuestError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise PreparedGuestError(message)


def run(*arguments):
    subprocess.run([str(argument) for argument in arguments], check=True)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path):
    with Path(path).open("rb") as handle:
        content = handle.read(2 * 1024 * 1024 + 1)
    require(len(content) <= 2 * 1024 * 1024, f"JSON exceeds the size limit: {path}")
    value = json.loads(content, object_pairs_hook=unique_object)
    require(isinstance(value, dict), f"JSON must contain an object: {path}")
    return value


def valid_sha256(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) and value != "0" * 64


def valid_https(value):
    if not isinstance(value, str) or any(ord(character) <= 32 or ord(character) == 127 for character in value):
        return False
    try:
        url = urlsplit(value)
        return url.scheme == "https" and bool(url.hostname) and not url.username and not url.password and not url.fragment
    except ValueError:
        return False


def digest_file(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as handle:
        before = os.fstat(handle.fileno())
        require(stat.S_ISREG(before.st_mode), f"Expected a regular file: {path}")
        digest = hashlib.sha256()
        count = 0
        for chunk in iter(lambda: handle.read(CHUNK_BYTES), b""):
            count += len(chunk)
            digest.update(chunk)
        after = os.fstat(handle.fileno())
        identity = lambda info: (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        require(identity(before) == identity(after) == identity(os.stat(path, follow_symlinks=False)), f"File changed during hashing: {path}")
        return digest.hexdigest(), count


def ignored_source(path):
    return any(part in ("tests", "__pycache__") for part in path.parts) or path.name.lower().startswith("readme") or path.name.startswith("test_") or path.suffix == ".pyc"


def source_hash(root=ROOT):
    root = Path(root)
    for name in SOURCE_FILES + SOURCE_TREES:
        ancestor = root
        for component in Path(name).parts[:-1]:
            ancestor /= component
            require(not ancestor.is_symlink(), f"Guest source ancestors must not be symlinks: {ancestor}")
    paths = [root / name for name in SOURCE_FILES]
    for path in paths:
        require(path.is_file() and not path.is_symlink(), f"Guest build entry point must be a regular file: {path}")
    for name in SOURCE_TREES:
        tree = root / name
        require(tree.is_dir() and not tree.is_symlink(), f"Missing source tree: {name}")
        for directory, directories, files in os.walk(tree, followlinks=False):
            parent = Path(directory)
            for child in list(directories):
                path = parent / child
                if ignored_source(path.relative_to(root)):
                    directories.remove(child)
                elif path.is_symlink():
                    paths.append(path)
                    directories.remove(child)
            paths.extend(parent / child for child in files if not ignored_source((parent / child).relative_to(root)))
    records = []
    for path in sorted(paths, key=lambda item: item.relative_to(root).as_posix()):
        info = path.lstat()
        record = {"path": path.relative_to(root).as_posix()}
        if stat.S_ISLNK(info.st_mode):
            record.update(kind="symlink", target=os.readlink(path))
        else:
            require(stat.S_ISREG(info.st_mode), f"Guest source must be a regular file: {path}")
            record.update(kind="file", executable=bool(info.st_mode & 0o111), sha256=digest_file(path)[0])
        records.append(record)
    canonical = json.dumps(records, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def validate_integrity(entry, name):
    require(isinstance(entry, dict) and set(entry) == {"byteCount", "sha256"}, f"Invalid integrity record: {name}")
    require(type(entry["byteCount"]) is int and entry["byteCount"] > 0 and valid_sha256(entry["sha256"]), f"Integrity is not finalized for {name}; pin the verified release byte count and SHA-256")


def load_manifest(path, root=ROOT):
    manifest = read_json(path)
    require(set(manifest) == {"schemaVersion", "sourceHash", "releaseImage", "guest"}, "Unexpected prepared guest manifest fields")
    require(type(manifest["schemaVersion"]) is int and manifest["schemaVersion"] == 1, "Unsupported prepared guest manifest schema")
    source = manifest["sourceHash"]
    require(isinstance(source, dict) and set(source) == {"algorithm", "sha256"} and source["algorithm"] == "sha256-tree-v1" and valid_sha256(source["sha256"]), "Invalid guest source hash")
    require(source["sha256"] == source_hash(root), "Guest build inputs changed; prepare and verify a new guest release, then refresh Guest/prepared-release.json")
    image = manifest["releaseImage"]
    require(isinstance(image, dict) and set(image) == {"url", "byteCount", "sha256"}, "Invalid release image record")
    require(valid_https(image["url"]), "Release image URL must use HTTPS without credentials or a fragment")
    validate_integrity({key: image[key] for key in ("byteCount", "sha256")}, "releaseImage")
    guest = manifest["guest"]
    require(isinstance(guest, dict) and set(guest) == {"version", "integrationVersion", "metadataSHA256", "integrity"}, "Invalid prepared guest record")
    require(isinstance(guest["version"], str) and bool(guest["version"].strip()), "Missing prepared guest version")
    require(type(guest["integrationVersion"]) is int and guest["integrationVersion"] > 0, "Invalid guest integration version")
    require(valid_sha256(guest["metadataSHA256"]), "Invalid prepared metadata SHA-256")
    require(isinstance(guest["integrity"], dict) and set(guest["integrity"]) == {"kernel", "initramfs", "rootfs.raw"}, "Prepared integrity must cover exactly kernel, initramfs, and rootfs.raw")
    for name, entry in guest["integrity"].items():
        validate_integrity(entry, name)
    return manifest


def verify_image(path, entry):
    validate_integrity({key: entry[key] for key in ("byteCount", "sha256")}, "releaseImage")
    info = Path(path).lstat()
    require(stat.S_ISREG(info.st_mode), "Release image must be a regular file, not a symlink or device")
    require(info.st_size == entry["byteCount"], "Release image byte count mismatch")
    digest, count = digest_file(path)
    require(count == entry["byteCount"] and digest == entry["sha256"], "Release image SHA-256 mismatch")


class HTTPSRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        require(valid_https(new_url), "Release download redirected outside HTTPS")
        return super().redirect_request(request, response, code, message, headers, new_url)


def download_image(entry, path):
    require(valid_https(entry["url"]), "Release image URL must use HTTPS")
    opener = build_opener(HTTPSRedirectHandler())
    with opener.open(entry["url"], timeout=60) as response, Path(path).open("xb") as destination:
        require(valid_https(response.geturl()), "Release download left HTTPS")
        count = 0
        while chunk := response.read(min(CHUNK_BYTES, entry["byteCount"] - count + 1)):
            count += len(chunk)
            require(count <= entry["byteCount"], "Release download exceeds its pinned byte count")
            destination.write(chunk)
    verify_image(path, entry)


def copy_guest(mount, staging, guest):
    source = Path(mount)
    for component in ("Omabox.app", "Contents", "Resources", "Guest"):
        source /= component
        require(source.is_dir() and not source.is_symlink(), f"Expected a real release directory: {source}")
    require({path.name for path in source.iterdir()} == set(GUEST_FILES), "The prepared Guest directory contains missing or unexpected files")
    staging.mkdir()
    for name in GUEST_FILES:
        original = source / name
        descriptor = os.open(original, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as handle, (staging / name).open("xb") as destination:
            require(stat.S_ISREG(os.fstat(handle.fileno()).st_mode), f"Guest artifact must be a regular file: {name}")
            count = 0
            for chunk in iter(lambda: handle.read(CHUNK_BYTES), b""):
                count += len(chunk)
                if chunk.strip(b"\x00"):
                    destination.write(chunk)
                else:
                    destination.seek(len(chunk), os.SEEK_CUR)
            destination.truncate(count)


def verify_staged_guest(staging, guest, root=ROOT):
    require(digest_file(staging / "metadata.json")[0] == guest["metadataSHA256"], "Prepared guest metadata SHA-256 mismatch")
    metadata = read_json(staging / "metadata.json")
    require(metadata.get("version") == guest["version"] and type(metadata.get("integrationVersion")) is int and metadata["integrationVersion"] == guest["integrationVersion"], "Prepared guest version or integration version mismatch")
    require(metadata.get("integrity") == guest["integrity"], "Prepared guest integrity differs from its release pin")
    run(sys.executable, Path(root) / "Scripts/verify-guest.py", staging)


def publish_directory(staging, destination):
    require(not os.path.lexists(destination), f"Refusing to overwrite an existing factory directory: {destination}")
    library = ctypes.CDLL(None, use_errno=True)
    rename = library.renamex_np
    rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(os.fsencode(staging), os.fsencode(destination), RENAME_EXCL) != 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number), str(destination))


def fetch_guest(manifest, image=None, root=ROOT):
    root = Path(root)
    destination = root / "Omabox/Resources/Guest"
    require(not os.path.lexists(destination), f"Refusing to overwrite an existing factory directory: {destination}; use a clean checkout")
    parent = destination.parent
    require(not (root / "Omabox").is_symlink() and not parent.is_symlink(), "Factory destination ancestors must not be symlinks")
    parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=".prepared-guest-", dir=parent))
    mount = work / "image"
    mount.mkdir()
    staging = work / "Guest"
    mounted = False
    attached = False
    try:
        if image is None:
            image = work / "release.dmg"
            download_image(manifest["releaseImage"], image)
        verify_image(image, manifest["releaseImage"])
        try:
            mounted = True
            run("hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, Path(image).absolute())
            attached = True
            copy_guest(mount, staging, manifest["guest"])
            verify_staged_guest(staging, manifest["guest"], root)
        finally:
            try:
                run("hdiutil", "detach", mount)
                mounted = False
            except subprocess.CalledProcessError:
                mounted = attached or os.path.ismount(mount)
                if mounted:
                    raise PreparedGuestError(f"Could not detach the release image; nothing was published. Detach {mount} before removing {work}") from None
        publish_directory(staging, destination)
        return destination
    finally:
        if not mounted:
            shutil.rmtree(work)


def main():
    parser = argparse.ArgumentParser(description="Import the pinned prepared guest from a verified Omabox release DMG without booting a VM.")
    parser.add_argument("--image", type=Path, help="Use a local DMG; the pinned release size and SHA-256 are still required.")
    parser.add_argument("--print-source-hash", action="store_true", help="Print the current guest build-input SHA-256 without downloading or mounting anything.")
    arguments = parser.parse_args()
    try:
        if arguments.print_source_hash:
            print(source_hash())
            return 0
        require(sys.platform == "darwin", "Prepared guest extraction requires macOS hdiutil")
        manifest = load_manifest(ROOT / "Guest/prepared-release.json")
        destination = fetch_guest(manifest, arguments.image)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Prepared guest import failed: {error}", file=sys.stderr)
        return 1
    print(f"Imported verified Omabox guest {manifest['guest']['version']} to {destination}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
