import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "verify-guest.py"
SPEC = importlib.util.spec_from_file_location("verify_guest", SCRIPT)
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)


class GuestVerificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name) / "Omabox.app/Contents/Resources/Guest"
        self.directory.mkdir(parents=True)
        self.limits = patch.dict(verifier.MINIMUM_BYTES, {"kernel": 4096, "initramfs": 4096, "rootfs.raw": 1024**2})
        self.limits.start()
        self.addCleanup(self.limits.stop)
        kernel = bytearray(4096)
        kernel[56:60] = b"ARM\x64"
        (self.directory / "kernel").write_bytes(kernel)
        (self.directory / "initramfs").write_bytes(b"070701" + bytes(4090))
        disk = bytearray(1024**2)
        struct.pack_into("<II", disk, 1024, 256, 256)
        struct.pack_into("<I", disk, 1024 + 24, 2)
        disk[1024 + 56:1024 + 58] = b"\x53\xef"
        struct.pack_into("<I", disk, 1024 + 96, 0x40)
        (self.directory / "rootfs.raw").write_bytes(disk)
        source = json.loads((SCRIPT.parents[1] / "Guest/source.json").read_text())
        upstream = {"commit": source["omarchyCommit"], "release": source["omarchyRelease"], "repository": "https://example.com/omarchy", "tree": "2" * 40, "treeSha256": "3" * 64, "license": "MIT"}
        tree = {"sha256": "3" * 64, "files": 1000, "algorithm": "tree-sha256-v1"}
        self.metadata = {
            "schemaVersion": 1,
            "architecture": "aarch64",
            "version": "0.1.0",
            "kernelFile": "kernel",
            "initramfsFile": "initramfs",
            "diskFile": "rootfs.raw",
            "commandLine": verifier.trusted_command_line(),
            "source": source,
            "integrity": {name: self.integrity(name) for name in verifier.MINIMUM_BYTES},
        }
        self.write_json("metadata.json", self.metadata)
        self.write_json("provenance.json", {"schemaVersion": 1, "upstream": upstream, "normalizedUpstreamTree": tree})
        self.write_json("build-spec.json", {"schemaVersion": 1, "upstream": upstream, "image": {"architecture": "aarch64", "filesystem": "ext4", "sizeMiB": 1}})
        (self.directory / "packages.lock.txt").write_text("".join(f"{name} 1.0\n" for name in ("bash", "glibc", "hyprland", "systemd", "wl-clipboard", "linux-aarch64")))
        (self.directory / "LICENSE.omarchy").write_text("Test license text. " * 10)
        self.manifest = {
            "schemaVersion": 1,
            "kind": "try-omarchy-guest-artifacts",
            "upstream": upstream,
            "normalizedUpstreamTree": tree,
            "guest": {"architecture": "aarch64"},
            "artifacts": [{"path": name, **self.integrity(name, "bytes")} for name in verifier.SIDECARS]
            + [{"path": upstream_name, **self.integrity(name, "bytes")} for name, upstream_name in (("kernel", "vmlinuz-linux"), ("initramfs", "initramfs-linux.img"))]
            + [{"path": "rootfs.ext4", "bytes": len(disk), "sha256": "6" * 64}],
        }
        self.write_json("guest-manifest.json", self.manifest)

    def write_json(self, name, value):
        (self.directory / name).write_text(json.dumps(value))

    def integrity(self, name, count_key="byteCount"):
        content = (self.directory / name).read_bytes()
        return {count_key: len(content), "sha256": hashlib.sha256(content).hexdigest()}

    def verify(self):
        return verifier.verify_guest(self.directory)

    def refresh_integrity(self, name):
        self.metadata["integrity"][name] = self.integrity(name)
        self.write_json("metadata.json", self.metadata)

    def test_accepts_bundle_layout_and_adapted_disk_with_original_provenance(self):
        self.assertEqual(self.verify()["architecture"], "aarch64")

    def test_rejects_self_consistent_ci_stub_with_production_limits(self):
        self.limits.stop()
        with self.assertRaisesRegex(verifier.VerificationError, "too small"):
            self.verify()

    def test_rejects_ci_marker_even_with_otherwise_valid_guest(self):
        (self.directory / "CI_ONLY_NOT_A_GUEST.txt").write_text("CI fixture")
        with self.assertRaisesRegex(verifier.VerificationError, "CI_ONLY_NOT_A_GUEST.txt is present"):
            self.verify()

    def test_rejects_noncanonical_artifact_filename(self):
        self.metadata["kernelFile"] = "../kernel"
        self.write_json("metadata.json", self.metadata)
        with self.assertRaisesRegex(verifier.VerificationError, "kernelFile must be kernel"):
            self.verify()

    def test_rejects_boolean_schema_and_wrong_architecture(self):
        for key, value in (("schemaVersion", True), ("architecture", "x86_64")):
            with self.subTest(key=key):
                metadata = dict(self.metadata, **{key: value})
                with self.assertRaises(verifier.VerificationError):
                    verifier.validate_metadata(metadata)

    def test_rejects_duplicate_json_keys(self):
        (self.directory / "metadata.json").write_text('{"schemaVersion":1,"schemaVersion":1}')
        with self.assertRaisesRegex(verifier.VerificationError, "Duplicate JSON key"):
            self.verify()

    def test_rejects_same_size_disk_tampering(self):
        with (self.directory / "rootfs.raw").open("r+b") as disk:
            disk.seek(8192)
            disk.write(b"tampered")
        with self.assertRaisesRegex(verifier.VerificationError, "SHA-256 mismatch: rootfs.raw"):
            self.verify()

    def test_rejects_truncated_artifact(self):
        (self.directory / "kernel").write_bytes(b"ARM\x64")
        with self.assertRaisesRegex(verifier.VerificationError, "too small"):
            self.verify()

    def test_rejects_wrong_kernel_magic_even_with_updated_manifests(self):
        (self.directory / "kernel").write_bytes(b"\x7fELF" + bytes(4092))
        self.refresh_integrity("kernel")
        entry = next(item for item in self.manifest["artifacts"] if item["path"] == "vmlinuz-linux")
        entry.update(self.integrity("kernel", "bytes"))
        self.write_json("guest-manifest.json", self.manifest)
        with self.assertRaisesRegex(verifier.VerificationError, "uncompressed ARM64"):
            self.verify()

    def test_rejects_ext4_filesystem_larger_than_disk(self):
        with (self.directory / "rootfs.raw").open("r+b") as disk:
            disk.seek(1028)
            disk.write(struct.pack("<I", 512))
        self.refresh_integrity("rootfs.raw")
        with self.assertRaisesRegex(verifier.VerificationError, "exceeds rootfs.raw"):
            self.verify()

    def test_rejects_symlink_artifact(self):
        artifact = self.directory / "kernel"
        target = self.directory / "kernel-real"
        artifact.rename(target)
        artifact.symlink_to(target)
        with self.assertRaises(OSError):
            self.verify()

    def test_rejects_symlink_directory(self):
        alias = self.directory.parent / "GuestAlias"
        alias.symlink_to(self.directory, target_is_directory=True)
        with self.assertRaisesRegex(verifier.VerificationError, "real directory"):
            verifier.verify_guest(alias)

    def test_rejects_fifo_without_blocking(self):
        (self.directory / "kernel").unlink()
        os.mkfifo(self.directory / "kernel")
        with self.assertRaisesRegex(verifier.VerificationError, "regular file"):
            self.verify()

    def test_requires_license_and_provenance(self):
        for name in ("LICENSE.omarchy", "provenance.json"):
            with self.subTest(name=name):
                original = self.directory / name
                saved = original.with_suffix(".saved")
                original.rename(saved)
                try:
                    with self.assertRaises(FileNotFoundError):
                        self.verify()
                finally:
                    saved.rename(original)

    def test_rejects_mismatched_upstream_commit(self):
        self.manifest["upstream"]["commit"] = "7" * 40
        self.write_json("guest-manifest.json", self.manifest)
        with self.assertRaisesRegex(verifier.VerificationError, "Upstream commit differs"):
            self.verify()

    def test_rejects_changes_to_each_pinned_source_field(self):
        alternatives = {
            "release": "Unreviewed release",
            "url": "https://example.com/unreviewed.dmg",
            "sha256": "8" * 64,
            "sourceRepository": "https://example.com/unreviewed",
            "sourceCommit": "8" * 40,
            "omarchyRelease": "Unreviewed Omarchy release",
            "omarchyCommit": "8" * 40,
            "kernelVersion": "Unreviewed kernel version",
        }
        for key, value in alternatives.items():
            with self.subTest(key=key):
                metadata = dict(self.metadata, source=dict(self.metadata["source"], **{key: value}))
                with self.assertRaisesRegex(verifier.VerificationError, "pinned Guest/source.json"):
                    verifier.validate_metadata(metadata)

    def test_rejects_internally_consistent_unpinned_source_in_app_bundle(self):
        self.metadata["source"]["omarchyCommit"] = "8" * 40
        self.metadata["source"]["sha256"] = "8" * 64
        self.write_json("metadata.json", self.metadata)
        self.write_json("source.json", self.metadata["source"])
        self.manifest["upstream"]["commit"] = "8" * 40
        documents = {}
        for name in ("provenance.json", "build-spec.json"):
            documents[name] = json.loads((self.directory / name).read_text())
            documents[name]["upstream"]["commit"] = "8" * 40
            self.write_json(name, documents[name])
            entry = next(item for item in self.manifest["artifacts"] if item["path"] == name)
            entry.update(self.integrity(name, "bytes"))
        self.write_json("guest-manifest.json", self.manifest)
        verifier.validate_provenance(self.metadata, self.manifest, documents["provenance.json"], documents["build-spec.json"])
        with self.assertRaisesRegex(verifier.VerificationError, "pinned Guest/source.json"):
            self.verify()

    def test_rejects_duplicate_or_alternative_root_arguments(self):
        for suffix in ("root=/dev/vda", "root=/dev/vdb", 'root="/dev/vda"'):
            with self.subTest(suffix=suffix):
                metadata = dict(self.metadata, commandLine=self.metadata["commandLine"] + " " + suffix)
                with self.assertRaisesRegex(verifier.VerificationError, "exactly one root=/dev/vda"):
                    verifier.validate_metadata(metadata)

    def test_rejects_init_and_rdinit_overrides(self):
        for argument in ("init=/bin/bash", "init=/bin/sh", "init=/sbin/init", "rdinit=/bin/bash", 'rdinit="/bin/sh"'):
            with self.subTest(argument=argument):
                metadata = dict(self.metadata, commandLine=self.metadata["commandLine"] + " " + argument)
                with self.assertRaisesRegex(verifier.VerificationError, "trusted release boot arguments"):
                    verifier.validate_metadata(metadata)

    def test_rejects_maintenance_and_other_boot_overrides(self):
        for argument in ("single", "1", "s", "S", "-s", "emergency", "rescue", "maintenance", "systemd.unit=emergency.target", "systemd.unit=rescue.target", "rd.systemd.unit=emergency.target", "rd.systemd.unit=rescue.target", "rd.break", "rd.shell", "systemd.debug_shell=1", "-- /bin/bash", "rw initcall_blacklist=security_init"):
            with self.subTest(argument=argument):
                metadata = dict(self.metadata, commandLine=self.metadata["commandLine"] + " " + argument)
                with self.assertRaisesRegex(verifier.VerificationError, "trusted release boot arguments"):
                    verifier.validate_metadata(metadata)

    def test_preparation_command_line_is_read_without_executing_source(self):
        repository = Path(self.temporary.name) / "repository"
        scripts = repository / "Scripts"
        scripts.mkdir(parents=True)
        (scripts / "prepare_guest.py").write_text('raise RuntimeError("Must not execute")\ndef main():\n    metadata = {"commandLine": "root=/dev/vda rw"}\n')
        with patch.object(verifier, "ROOT", repository):
            self.assertEqual(verifier.trusted_command_line(), "root=/dev/vda rw")

    def test_rejects_tampered_package_inventory(self):
        (self.directory / "packages.lock.txt").write_text("unexpected 1\n")
        with self.assertRaisesRegex(verifier.VerificationError, "Byte count mismatch: packages.lock.txt"):
            self.verify()

    def test_rejects_modification_to_artifact_after_its_hash_was_checked(self):
        original_verify_hash = verifier.verify_hash

        def change_previously_verified_file(handle, name, expected, count_key="byteCount"):
            original_verify_hash(handle, name, expected, count_key)
            if name == "rootfs.raw":
                with (self.directory / "kernel").open("r+b") as kernel:
                    kernel.write(b"modified")

        with patch.object(verifier, "verify_hash", side_effect=change_previously_verified_file):
            with self.assertRaisesRegex(verifier.VerificationError, "Artifact changed or was replaced"):
                self.verify()

    def test_cli_fails_with_actionable_error_for_missing_directory(self):
        result = subprocess.run([sys.executable, str(SCRIPT), str(self.directory / "missing")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Guest verification failed", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
