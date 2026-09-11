#!/usr/bin/env python3
import argparse
import ast
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import sys
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parent.parent
MINIMUM_BYTES = {"kernel": 1024 * 1024, "initramfs": 64 * 1024, "rootfs.raw": 1024**3}
SIDECARS = ("provenance.json", "build-spec.json", "packages.lock.txt", "LICENSE.omarchy")


class VerificationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(handle, name):
    handle.seek(0)
    content = handle.read(2 * 1024 * 1024 + 1)
    require(len(content) <= 2 * 1024 * 1024, f"{name} exceeds the metadata size limit")
    try:
        value = json.loads(content, object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"Invalid JSON in {name}: {error}") from error
    require(isinstance(value, dict), f"{name} must contain a JSON object")
    return value


def sha256_value(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) and value != "0" * 64


def commit_value(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value) and set(value) != {"0"}


def https_value(value):
    if not isinstance(value, str):
        return False
    parsed = urlsplit(value)
    return parsed.scheme == "https" and bool(parsed.hostname) and not parsed.username and not parsed.password


def nonempty_string(value):
    return isinstance(value, str) and bool(value.strip())


def validate_integrity(entry, name, count_key="byteCount"):
    require(isinstance(entry, dict), f"Missing integrity record for {name}")
    count = entry.get(count_key)
    require(type(count) is int and count > 0, f"Invalid byte count for {name}")
    require(sha256_value(entry.get("sha256")), f"Invalid SHA-256 for {name}")


def trusted_command_line():
    path = ROOT / "Scripts/prepare_guest.py"
    try:
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    except SyntaxError as error:
        raise VerificationError(f"Cannot read the trusted preparation command line: {error}") from error
    values = []
    for function in tree.body:
        if not isinstance(function, ast.FunctionDef) or function.name != "main":
            continue
        for node in ast.walk(function):
            if not isinstance(node, ast.Assign) or not any(isinstance(target, ast.Name) and target.id == "metadata" for target in node.targets):
                continue
            require(isinstance(node.value, ast.Dict), "Preparation metadata must contain a literal commandLine")
            for key, value in zip(node.value.keys, node.value.values):
                if isinstance(key, ast.Constant) and key.value == "commandLine":
                    require(isinstance(value, ast.Constant) and nonempty_string(value.value), "Preparation commandLine must be a literal string")
                    values.append(value.value)
    require(len(values) == 1, "Expected exactly one trusted metadata commandLine in Scripts/prepare_guest.py")
    return values[0]


def validate_metadata(metadata):
    require(type(metadata.get("schemaVersion")) is int and metadata["schemaVersion"] == 1, "Unsupported metadata schema")
    require(metadata.get("architecture") == "aarch64", "Guest architecture must be aarch64")
    require(nonempty_string(metadata.get("version")), "Missing guest version")
    for key, name in (("kernelFile", "kernel"), ("initramfsFile", "initramfs"), ("diskFile", "rootfs.raw")):
        require(metadata.get(key) == name, f"{key} must be {name}")
    command_line = metadata.get("commandLine")
    require(nonempty_string(command_line) and "\x00" not in command_line, "Missing or invalid kernel command line")
    roots = [token for token in command_line.split() if token.startswith("root=")]
    require(roots == ["root=/dev/vda"], "The raw filesystem must have exactly one root=/dev/vda boot argument")
    require(command_line == trusted_command_line(), "Kernel commandLine must match the trusted release boot arguments in Scripts/prepare_guest.py")
    integrity = metadata.get("integrity")
    require(isinstance(integrity, dict) and set(integrity) == set(MINIMUM_BYTES), "Integrity must cover exactly kernel, initramfs, and rootfs.raw")
    for name, minimum in MINIMUM_BYTES.items():
        validate_integrity(integrity[name], name)
        require(integrity[name]["byteCount"] >= minimum, f"{name} is too small for a release guest; CI stubs cannot be shipped")
    source = metadata.get("source")
    require(isinstance(source, dict), "Missing source provenance")
    for key in ("url", "sourceRepository"):
        require(https_value(source.get(key)), f"Invalid source {key}")
    for key in ("sourceCommit", "omarchyCommit"):
        require(commit_value(source.get(key)), f"Invalid source {key}")
    require(sha256_value(source.get("sha256")), "Missing source archive SHA-256")
    for key in ("release", "omarchyRelease", "kernelVersion"):
        require(nonempty_string(source.get(key)), f"Missing source {key}")
    with (ROOT / "Guest/source.json").open("rb") as handle:
        source_lock = read_json(handle, "Guest/source.json")
    require(source == source_lock, "Guest source does not match the repository's pinned Guest/source.json")


def validate_provenance(metadata, manifest, provenance, build_spec):
    for name, document in (("guest-manifest.json", manifest), ("provenance.json", provenance), ("build-spec.json", build_spec)):
        require(type(document.get("schemaVersion")) is int and document["schemaVersion"] == 1, f"Unsupported schema in {name}")
        upstream = document.get("upstream")
        require(isinstance(upstream, dict), f"Missing upstream provenance in {name}")
        require(upstream.get("commit") == metadata["source"]["omarchyCommit"], f"Upstream commit differs in {name}")
        require(upstream.get("release") == metadata["source"]["omarchyRelease"], f"Upstream release differs in {name}")
        require(https_value(upstream.get("repository")), f"Missing upstream repository in {name}")
        require(commit_value(upstream.get("tree")) and sha256_value(upstream.get("treeSha256")), f"Missing upstream tree identity in {name}")
        require(nonempty_string(upstream.get("license")), f"Missing upstream license in {name}")
        require(upstream == manifest.get("upstream"), f"Upstream provenance differs in {name}")
    require(manifest.get("kind") == "try-omarchy-guest-artifacts", "Unrecognized guest source manifest")
    require(isinstance(manifest.get("guest"), dict) and manifest["guest"].get("architecture") == "aarch64", "Source manifest must describe an aarch64 guest")
    image = build_spec.get("image")
    require(isinstance(image, dict) and image.get("architecture") == "aarch64" and image.get("filesystem") == "ext4", "Build specification must describe a raw aarch64 ext4 image")
    require(type(image.get("sizeMiB")) is int and image["sizeMiB"] * 1024**2 == metadata["integrity"]["rootfs.raw"]["byteCount"], "Disk size differs from its build specification")
    for document in (manifest, provenance):
        tree = document.get("normalizedUpstreamTree")
        require(isinstance(tree, dict) and tree.get("sha256") == document["upstream"]["treeSha256"], "Normalized upstream tree digest differs")
        require(type(tree.get("files")) is int and tree["files"] > 0 and nonempty_string(tree.get("algorithm")), "Missing normalized upstream tree details")
    entries = manifest.get("artifacts")
    require(isinstance(entries, list), "Source manifest has no artifact inventory")
    artifacts = {}
    for entry in entries:
        require(isinstance(entry, dict), "Invalid source manifest artifact")
        name = entry.get("path")
        require(isinstance(name, str) and Path(name).name == name and name not in (".", "..") and name not in artifacts, "Invalid or duplicate source artifact path")
        validate_integrity(entry, name, "bytes")
        artifacts[name] = entry
    for name in SIDECARS + ("vmlinuz-linux", "initramfs-linux.img", "rootfs.ext4"):
        require(name in artifacts, f"Source manifest is missing {name}")
    for name, upstream_name in (("kernel", "vmlinuz-linux"), ("initramfs", "initramfs-linux.img")):
        require(artifacts[upstream_name]["sha256"] == metadata["integrity"][name]["sha256"] and artifacts[upstream_name]["bytes"] == metadata["integrity"][name]["byteCount"], f"{name} differs from the pinned source manifest")
    require(artifacts["rootfs.ext4"]["bytes"] == metadata["integrity"]["rootfs.raw"]["byteCount"], "Adapted root filesystem size differs from its source")
    return artifacts


def validate_headers(handles, sizes):
    kernel = handles["kernel"]
    kernel.seek(0)
    header = kernel.read(64)
    require(header[56:60] == b"ARM\x64", "kernel is not an uncompressed ARM64 Linux Image")
    initramfs = handles["initramfs"]
    initramfs.seek(0)
    header = initramfs.read(8)
    require(header.startswith((b"070701", b"070702", b"\x1f\x8b", b"\xfd7zXZ\x00", b"\x28\xb5\x2f\xfd", b"\x04\x22\x4d\x18", b"\x02\x21\x4c\x18")), "initramfs has no recognized Linux archive signature")
    disk = handles["rootfs.raw"]
    disk.seek(1024)
    superblock = disk.read(1024)
    require(len(superblock) == 1024 and superblock[56:58] == b"\x53\xef", "rootfs.raw is not a raw ext4 filesystem")
    inode_count, blocks = struct.unpack_from("<II", superblock)
    block_shift = struct.unpack_from("<I", superblock, 24)[0]
    incompat = struct.unpack_from("<I", superblock, 96)[0]
    require(inode_count > 0 and block_shift <= 6 and incompat & 0x40, "Invalid ext4 superblock")
    if incompat & 0x80:
        blocks |= struct.unpack_from("<I", superblock, 336)[0] << 32
    filesystem_bytes = blocks * (1024 << block_shift)
    require(MINIMUM_BYTES["rootfs.raw"] <= filesystem_bytes <= sizes["rootfs.raw"], "Ext4 filesystem is too small or exceeds rootfs.raw")


def verify_hash(handle, name, expected, count_key="byteCount"):
    before = os.fstat(handle.fileno())
    require(before.st_size == expected[count_key], f"Byte count mismatch: {name}")
    handle.seek(0)
    digest = hashlib.sha256()
    count = 0
    for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
        count += len(chunk)
        digest.update(chunk)
    after = os.fstat(handle.fileno())
    require((before.st_size, before.st_mtime_ns, before.st_ctime_ns) == (after.st_size, after.st_mtime_ns, after.st_ctime_ns), f"Artifact changed during verification: {name}")
    require(count == expected[count_key] and digest.hexdigest() == expected["sha256"], f"SHA-256 mismatch: {name}")


def file_identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def verify_guest(directory):
    directory = Path(directory).absolute()
    require(not directory.is_symlink() and directory.is_dir(), f"Guest directory must be a real directory: {directory}")
    require(not os.path.lexists(directory / "CI_ONLY_NOT_A_GUEST.txt"), "CI_ONLY_NOT_A_GUEST.txt is present; CI stubs cannot be shipped")
    with ExitStack() as stack:
        handles = {}
        sizes = {}
        identities = {}
        names = ("metadata.json", "guest-manifest.json") + SIDECARS + tuple(MINIMUM_BYTES)
        for name in names:
            path = directory / name
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            handle = stack.enter_context(os.fdopen(descriptor, "rb"))
            info = os.fstat(handle.fileno())
            require(stat.S_ISREG(info.st_mode), f"Guest artifact must be a regular file: {name}")
            handles[name] = handle
            sizes[name] = info.st_size
            identities[name] = file_identity(info)
        metadata = read_json(handles["metadata.json"], "metadata.json")
        validate_metadata(metadata)
        for name, minimum in MINIMUM_BYTES.items():
            require(sizes[name] >= minimum, f"{name} is too small for a release guest; CI stubs cannot be shipped")
            require(sizes[name] == metadata["integrity"][name]["byteCount"], f"Byte count mismatch: {name}")
        documents = {name: read_json(handles[name], name) for name in ("guest-manifest.json", "provenance.json", "build-spec.json")}
        artifacts = validate_provenance(metadata, documents["guest-manifest.json"], documents["provenance.json"], documents["build-spec.json"])
        validate_headers(handles, sizes)
        for name in SIDECARS:
            verify_hash(handles[name], name, artifacts[name], "bytes")
        handles["packages.lock.txt"].seek(0)
        packages = {}
        for line in handles["packages.lock.txt"].read().decode("utf-8").splitlines():
            fields = line.split()
            require(len(fields) == 2 and fields[0] not in packages, "Invalid or duplicate package inventory entry")
            packages[fields[0]] = fields[1]
        require({"bash", "glibc", "hyprland", "systemd", "wl-clipboard", "linux-aarch64"} <= packages.keys(), "Package inventory is missing essential Omarchy components")
        require(sizes["LICENSE.omarchy"] >= 100, "Missing substantive Omarchy license text")
        for name in MINIMUM_BYTES:
            verify_hash(handles[name], name, metadata["integrity"][name])
        for name, handle in handles.items():
            final = os.stat(directory / name, follow_symlinks=False)
            opened = os.fstat(handle.fileno())
            require(file_identity(final) == file_identity(opened) == identities[name], f"Artifact changed or was replaced during verification: {name}")
    return metadata


def main():
    parser = argparse.ArgumentParser(description="Verify that a guest directory contains release-ready ARM64 Linux artifacts.")
    parser.add_argument("guest_directory", nargs="?", type=Path, default=ROOT / "Omabox/Resources/Guest")
    arguments = parser.parse_args()
    try:
        metadata = verify_guest(arguments.guest_directory)
    except (OSError, ValueError) as error:
        print(f"Guest verification failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified Omabox guest {metadata['version']} ({metadata['architecture']}): {arguments.guest_directory}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
