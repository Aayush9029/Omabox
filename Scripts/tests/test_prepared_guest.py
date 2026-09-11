import copy
import errno
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[1] / "fetch-release-guest.py"
SPEC = importlib.util.spec_from_file_location("fetch_release_guest", SCRIPT)
fetcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetcher)

SOURCE_FILES = (
    "Guest/overlay/usr/local/bin/start-desktop",
    "Guest/overlay/etc/systemd/system/display.service",
    "Guest/virtio-sound-source/driver.c",
    "Guest/adapt-guest.sh",
    "Guest/source.json",
    "Scripts/prepare_guest.py",
    "Scripts/prepare-guest.sh",
    "Scripts/GuestBootstrap.swift",
    "Scripts/GuestBootstrap.entitlements",
)
GUEST_FILES = (
    "metadata.json",
    "guest-manifest.json",
    "provenance.json",
    "build-spec.json",
    "packages.lock.txt",
    "LICENSE.omarchy",
    "kernel",
    "initramfs",
    "rootfs.raw",
)


def integrity(content):
    return {"byteCount": len(content), "sha256": hashlib.sha256(content).hexdigest()}


class PreparedGuestFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.root = self.directory / "repository"
        self.root.mkdir()
        self.create_sources(self.root)
        self.image = self.directory / "release.dmg"
        self.image.write_bytes(b"small pinned release image")
        self.metadata = {
            "schemaVersion": 1,
            "architecture": "aarch64",
            "version": "0.4.0",
            "integrationVersion": 4,
            "integrity": {name: integrity(name.encode()) for name in ("kernel", "initramfs", "rootfs.raw")},
        }
        self.manifest = {
            "schemaVersion": 1,
            "sourceHash": {"algorithm": "sha256-tree-v1", "sha256": fetcher.source_hash(self.root)},
            "releaseImage": {"url": "https://example.com/releases/Omabox.dmg", **integrity(self.image.read_bytes())},
            "guest": {
                "version": self.metadata["version"],
                "integrationVersion": self.metadata["integrationVersion"],
                "metadataSHA256": hashlib.sha256(self.metadata_bytes()).hexdigest(),
                "integrity": copy.deepcopy(self.metadata["integrity"]),
            },
        }
        self.manifest_path = self.root / "Guest/prepared-guest.json"
        self.write_manifest()

    def create_sources(self, root, reverse=False):
        for name in reversed(SOURCE_FILES) if reverse else SOURCE_FILES:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name + "\n")
            path.chmod(0o644)

    def metadata_bytes(self):
        return json.dumps(self.metadata).encode()

    def write_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest))

    def create_guest(self, path):
        path.mkdir(parents=True, exist_ok=True)
        for name in GUEST_FILES:
            (path / name).write_bytes(self.metadata_bytes() if name == "metadata.json" else name.encode())
        return path


class SourceHashTests(PreparedGuestFixture):
    def test_is_independent_of_checkout_path_creation_order_and_timestamps(self):
        other = self.directory / "other-checkout"
        self.create_sources(other, reverse=True)
        for path in other.rglob("*"):
            os.utime(path, (123456789, 123456789))
        self.assertEqual(fetcher.source_hash(self.root), fetcher.source_hash(other))

    def test_tracks_content_changes_in_every_declared_source(self):
        original = fetcher.source_hash(self.root)
        for name in SOURCE_FILES:
            with self.subTest(name=name):
                path = self.root / name
                content = path.read_bytes()
                path.write_bytes(content + b"changed")
                self.assertNotEqual(fetcher.source_hash(self.root), original)
                path.write_bytes(content)

    def test_tracks_nested_file_addition_deletion_and_rename(self):
        original = fetcher.source_hash(self.root)
        path = self.root / "Guest/overlay/nested/added"
        path.parent.mkdir()
        path.write_bytes(b"new payload")
        added = fetcher.source_hash(self.root)
        self.assertNotEqual(added, original)
        renamed = path.with_name("renamed")
        path.rename(renamed)
        self.assertNotEqual(fetcher.source_hash(self.root), added)
        renamed.unlink()
        self.assertEqual(fetcher.source_hash(self.root), original)

    def test_tracks_executable_permissions(self):
        path = self.root / "Guest/overlay/usr/local/bin/start-desktop"
        original = fetcher.source_hash(self.root)
        path.chmod(0o755)
        self.assertNotEqual(fetcher.source_hash(self.root), original)
        path.chmod(0o644)
        self.assertEqual(fetcher.source_hash(self.root), original)

    def test_tracks_symlink_target_without_hashing_target_contents(self):
        target = self.directory / "outside-source"
        target.write_bytes(b"outside content")
        link = self.root / "Guest/overlay/link"
        link.symlink_to(target)
        original = fetcher.source_hash(self.root)
        target.write_bytes(b"different outside content")
        self.assertEqual(fetcher.source_hash(self.root), original)
        link.unlink()
        link.symlink_to("different-target")
        self.assertNotEqual(fetcher.source_hash(self.root), original)

    def test_rejects_symlink_build_entry_point(self):
        path = self.root / "Guest/adapt-guest.sh"
        target = self.directory / "adapt-guest.sh"
        path.rename(target)
        path.symlink_to(target)
        with self.assertRaises(ValueError):
            fetcher.source_hash(self.root)

    def test_rejects_symlink_source_tree_ancestor(self):
        guest = self.root / "Guest"
        outside = self.directory / "outside-guest"
        guest.rename(outside)
        guest.symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            fetcher.source_hash(self.root)

    def test_ignores_documentation_tests_caches_and_unrelated_files(self):
        original = fetcher.source_hash(self.root)
        ignored = (
            "README.md", "Docs/Build.md", "Guest/README.md", "Guest/test_runtime.py",
            "Guest/prepared-guest.json", "Scripts/tests/test_prepared_guest.py",
            "Guest/overlay/README", "Guest/overlay/README.md",
            "Guest/overlay/nested/README.notes", "Guest/overlay/test_runtime.py",
            "Guest/overlay/tests/fixture", "Guest/overlay/__pycache__/runtime.pyc",
            "Guest/overlay/runtime.pyc", "Guest/virtio-sound-source/README.md",
            "Guest/virtio-sound-source/tests/fixture", "Guest/virtio-sound-source/test_driver.c",
        )
        for name in ignored:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"ignored content")
        self.assertEqual(fetcher.source_hash(self.root), original)


class PreparedManifestTests(PreparedGuestFixture):
    def load(self):
        return fetcher.load_manifest(self.manifest_path, self.root)

    def test_accepts_complete_matching_manifest(self):
        self.assertEqual(self.load(), self.manifest)

    def test_rejects_unpublished_release_placeholders(self):
        for name in ("url", "byteCount", "sha256"):
            with self.subTest(name=name):
                original = self.manifest["releaseImage"][name]
                self.manifest["releaseImage"][name] = None
                self.write_manifest()
                with self.assertRaises(ValueError):
                    self.load()
                self.manifest["releaseImage"][name] = original

    def test_rejects_invalid_json_and_duplicate_nested_keys(self):
        for content in ('{"schemaVersion":', '[]', '{"schemaVersion":1,"schemaVersion":1}',
                        '{"releaseImage":{"url":"https://example.com/a","url":"https://example.com/b"}}'):
            with self.subTest(content=content):
                self.manifest_path.write_text(content)
                with self.assertRaises(ValueError):
                    self.load()

    def test_rejects_non_https_and_credentialed_urls(self):
        for url in ("http://example.com/guest.dmg", "file:///tmp/guest.dmg", "https:///guest.dmg",
                    "https://user:password@example.com/guest.dmg"):
            with self.subTest(url=url):
                self.manifest["releaseImage"]["url"] = url
                self.write_manifest()
                with self.assertRaises(ValueError):
                    self.load()

    def test_rejects_schema_algorithm_and_integrity_type_errors(self):
        invalid = (
            (("schemaVersion",), True), (("schemaVersion",), 2),
            (("sourceHash", "algorithm"), "sha256"),
            (("releaseImage", "byteCount"), True), (("releaseImage", "byteCount"), 0),
            (("releaseImage", "sha256"), "invalid"), (("releaseImage", "sha256"), "0" * 64),
            (("guest", "version"), ""), (("guest", "integrationVersion"), True),
            (("guest", "metadataSHA256"), "invalid"),
            (("guest", "integrity", "kernel", "byteCount"), -1),
            (("guest", "integrity", "rootfs.raw", "sha256"), "invalid"),
        )
        for keys, value in invalid:
            with self.subTest(keys=keys, value=value):
                document = copy.deepcopy(self.manifest)
                target = document
                for key in keys[:-1]:
                    target = target[key]
                target[keys[-1]] = value
                self.manifest_path.write_text(json.dumps(document))
                with self.assertRaises(ValueError):
                    self.load()

    def test_rejects_missing_or_additional_guest_integrity_entries(self):
        for remove in (True, False):
            document = copy.deepcopy(self.manifest)
            if remove:
                del document["guest"]["integrity"]["kernel"]
            else:
                document["guest"]["integrity"]["other"] = integrity(b"other")
            self.manifest_path.write_text(json.dumps(document))
            with self.assertRaises(ValueError):
                self.load()

    def test_rejects_source_changes_since_release_lock(self):
        (self.root / "Guest/adapt-guest.sh").write_text("changed build input\n")
        with self.assertRaises(ValueError):
            self.load()


class ReleaseImageTests(PreparedGuestFixture):
    def test_accepts_matching_image(self):
        fetcher.verify_image(self.image, self.manifest["releaseImage"])

    def test_rejects_wrong_size_and_same_size_tampering(self):
        for content in (b"truncated", b"x" * self.image.stat().st_size):
            with self.subTest(size=len(content)):
                self.image.write_bytes(content)
                with self.assertRaises(ValueError):
                    fetcher.verify_image(self.image, self.manifest["releaseImage"])

    def test_rejects_symlink_even_when_target_matches(self):
        alias = self.directory / "alias.dmg"
        alias.symlink_to(self.image)
        with self.assertRaises((ValueError, OSError)):
            fetcher.verify_image(alias, self.manifest["releaseImage"])

    def test_rejects_nonregular_image_without_reading_it(self):
        fifo = self.directory / "release.fifo"
        os.mkfifo(fifo)
        with self.assertRaises((ValueError, OSError)):
            fetcher.verify_image(fifo, self.manifest["releaseImage"])


class ReleaseDownloadTests(PreparedGuestFixture):
    def download(self, content, url="https://example.com/releases/Omabox.dmg"):
        response = io.BytesIO(content)
        response.geturl = lambda: url
        opener = Mock()
        opener.open.return_value = response
        destination = self.directory / "download.dmg"
        with patch.object(fetcher, "build_opener", return_value=opener):
            fetcher.download_image(self.manifest["releaseImage"], destination)
        return destination

    def test_downloads_and_verifies_exact_image(self):
        content = self.image.read_bytes()
        self.assertEqual(self.download(content).read_bytes(), content)

    def test_rejects_short_oversized_and_same_size_corrupt_downloads(self):
        content = self.image.read_bytes()
        for value in (content[:-1], content + b"extra", b"x" * len(content)):
            with self.subTest(size=len(value)):
                with self.assertRaises(ValueError):
                    self.download(value)
                (self.directory / "download.dmg").unlink(missing_ok=True)

    def test_rejects_response_that_left_https(self):
        with self.assertRaises(ValueError):
            self.download(self.image.read_bytes(), "http://example.com/guest.dmg")

    def test_rejects_redirect_to_non_https_before_following_it(self):
        handler = fetcher.HTTPSRedirectHandler()
        with self.assertRaises(ValueError):
            handler.redirect_request(None, None, 302, "redirect", {}, "http://example.com/guest.dmg")


class GuestExtractionTests(PreparedGuestFixture):
    def setUp(self):
        super().setUp()
        self.mount = self.directory / "mount"
        self.source = self.create_guest(self.mount / "Omabox.app/Contents/Resources/Guest")
        self.staging = self.directory / "staging"

    def extract(self):
        return fetcher.copy_guest(self.mount, self.staging, self.manifest["guest"])

    def test_copies_only_expected_guest_files(self):
        self.extract()
        self.assertEqual({path.name for path in self.staging.iterdir()}, set(GUEST_FILES))
        for name in GUEST_FILES:
            self.assertEqual((self.staging / name).read_bytes(), (self.source / name).read_bytes())

    def test_rejects_unexpected_files(self):
        (self.source / "unrelated.txt").write_text("not part of the guest")
        with self.assertRaises(ValueError):
            self.extract()

    def test_rejects_missing_expected_file(self):
        (self.source / "LICENSE.omarchy").unlink()
        with self.assertRaises((ValueError, OSError)):
            self.extract()

    def test_rejects_symlink_guest_file(self):
        artifact = self.source / "kernel"
        target = self.directory / "kernel-real"
        artifact.rename(target)
        artifact.symlink_to(target)
        with self.assertRaises((ValueError, OSError)):
            self.extract()

    def test_rejects_symlink_bundle_ancestor(self):
        resources = self.source.parent
        real = resources.with_name("ActualResources")
        resources.rename(real)
        resources.symlink_to(real, target_is_directory=True)
        with self.assertRaises((ValueError, OSError)):
            self.extract()

    def test_rejects_fifo_guest_file_without_blocking(self):
        artifact = self.source / "kernel"
        artifact.unlink()
        os.mkfifo(artifact)
        with self.assertRaises((ValueError, OSError)):
            self.extract()


class StagedGuestTests(PreparedGuestFixture):
    def setUp(self):
        super().setUp()
        self.staging = self.create_guest(self.directory / "staging")

    def verify(self):
        return fetcher.verify_staged_guest(self.staging, self.manifest["guest"], self.root)

    def test_runs_repository_verifier_for_matching_release_metadata(self):
        with patch.object(fetcher, "run") as run:
            self.verify()
        arguments = [str(value) for value in run.call_args.args]
        self.assertIn(str(self.root / "Scripts/verify-guest.py"), arguments)
        self.assertIn(str(self.staging), arguments)

    def test_rejects_metadata_digest_change_before_running_verifier(self):
        (self.staging / "metadata.json").write_bytes(self.metadata_bytes() + b"\n")
        with patch.object(fetcher, "run") as run:
            with self.assertRaises(ValueError):
                self.verify()
        run.assert_not_called()

    def test_rejects_metadata_fields_that_disagree_with_release_lock(self):
        mutations = (
            {"version": "0.5.0"}, {"integrationVersion": 5},
            {"integrationVersion": True},
            {"integrity": {**self.metadata["integrity"], "kernel": integrity(b"different")}},
        )
        for fields in mutations:
            with self.subTest(fields=fields):
                metadata = {**self.metadata, **fields}
                content = json.dumps(metadata).encode()
                (self.staging / "metadata.json").write_bytes(content)
                guest = {**self.manifest["guest"], "metadataSHA256": hashlib.sha256(content).hexdigest()}
                with patch.object(fetcher, "run") as run:
                    with self.assertRaises(ValueError):
                        fetcher.verify_staged_guest(self.staging, guest, self.root)
                run.assert_not_called()

    def test_propagates_repository_verification_failure(self):
        with patch.object(fetcher, "run", side_effect=subprocess.CalledProcessError(1, "verify-guest.py")):
            with self.assertRaises(subprocess.CalledProcessError):
                self.verify()


class GuestFetchTests(PreparedGuestFixture):
    def setUp(self):
        super().setUp()
        self.destination = self.root / "Omabox/Resources/Guest"
        self.events = []
        self.mounted_guest = None
        self.mount = None
        self.mount_mutation = None
        self.fail_attach = False
        self.fail_verifier = False
        self.fail_detach = False
        self.destination_race = False
        self.run_patch = patch.object(fetcher, "run", side_effect=self.run_command)
        self.run = self.run_patch.start()
        self.addCleanup(self.run_patch.stop)
        original_verify = fetcher.verify_image

        def record_image_verification(path, entry):
            self.events.append("verify-image")
            return original_verify(path, entry)

        self.verify_patch = patch.object(fetcher, "verify_image", side_effect=record_image_verification)
        self.verify_patch.start()
        self.addCleanup(self.verify_patch.stop)
        self.rename = Mock(side_effect=self.rename_directory)
        library = Mock(renamex_np=self.rename)
        self.library_patch = patch.object(fetcher.ctypes, "CDLL", return_value=library)
        self.library_patch.start()
        self.addCleanup(self.library_patch.stop)

    def rename_directory(self, source, destination, flags):
        self.assertEqual(flags, 0x00000004)
        self.assertFalse(os.path.lexists(destination))
        os.rename(source, destination)
        return 0

    def run_command(self, *arguments):
        arguments = [str(value) for value in arguments]
        if Path(arguments[0]).name == "hdiutil":
            if arguments[1] == "attach":
                self.events.append("attach")
                self.assertIn("-readonly", arguments)
                self.assertIn("-nobrowse", arguments)
                self.assertIn("-noautoopen", arguments)
                self.mount = Path(arguments[arguments.index("-mountpoint") + 1])
                if self.fail_attach:
                    raise subprocess.CalledProcessError(1, arguments)
                self.mounted_guest = self.create_guest(self.mount / "Omabox.app/Contents/Resources/Guest")
                if self.mount_mutation:
                    self.mount_mutation(self.mounted_guest)
            elif arguments[1] == "detach":
                self.events.append("detach")
                self.assertFalse(os.path.lexists(self.destination))
                if self.destination_race:
                    self.destination.mkdir(parents=True)
                    (self.destination / "keep.txt").write_text("concurrent destination")
                if self.fail_detach:
                    raise subprocess.CalledProcessError(1, arguments)
            else:
                self.fail(f"Unexpected hdiutil operation: {arguments}")
        elif str(self.root / "Scripts/verify-guest.py") in arguments:
            self.events.append("verify-guest")
            self.assertFalse(os.path.lexists(self.destination))
            staging = Path(arguments[-1])
            self.assertEqual({path.name for path in staging.iterdir()}, set(GUEST_FILES))
            if self.fail_verifier:
                raise subprocess.CalledProcessError(1, arguments)
        else:
            self.fail(f"Unexpected command: {arguments}")
        return subprocess.CompletedProcess(arguments, 0)

    def fetch(self, image=None):
        return fetcher.fetch_guest(self.manifest, image=self.image if image is None else image, root=self.root)

    def test_publishes_local_image_only_after_verification_and_detach(self):
        with patch.object(fetcher, "download_image") as download:
            self.fetch()
        download.assert_not_called()
        self.assertEqual(self.events, ["verify-image", "attach", "verify-guest", "detach"])
        self.assertEqual({path.name for path in self.destination.iterdir()}, set(GUEST_FILES))
        self.assertEqual((self.destination / "metadata.json").read_bytes(), self.metadata_bytes())

    def test_downloaded_image_is_verified_before_mount(self):
        downloaded = []

        def download(entry, path):
            self.events.append("download")
            self.assertEqual(entry, self.manifest["releaseImage"])
            Path(path).write_bytes(self.image.read_bytes())
            downloaded.append(Path(path))

        with patch.object(fetcher, "download_image", side_effect=download):
            fetcher.fetch_guest(self.manifest, root=self.root)
        self.assertEqual(self.events, ["download", "verify-image", "attach", "verify-guest", "detach"])
        self.assertTrue(self.destination.is_dir())
        self.assertFalse(downloaded[0].parent.exists())

    def test_removes_partial_download_when_network_request_fails(self):
        downloaded = []

        def download(entry, path):
            Path(path).write_bytes(b"partial download")
            downloaded.append(Path(path))
            raise OSError("download interrupted")

        with patch.object(fetcher, "download_image", side_effect=download):
            with self.assertRaisesRegex(OSError, "download interrupted"):
                fetcher.fetch_guest(self.manifest, root=self.root)
        self.assertFalse(downloaded[0].parent.exists())
        self.assertFalse(os.path.lexists(self.destination))
        self.run.assert_not_called()

    def test_removes_download_that_fails_image_verification(self):
        downloaded = []

        def download(entry, path):
            Path(path).write_bytes(b"x" * entry["byteCount"])
            downloaded.append(Path(path))

        with patch.object(fetcher, "download_image", side_effect=download):
            with self.assertRaises(ValueError):
                fetcher.fetch_guest(self.manifest, root=self.root)
        self.assertFalse(downloaded[0].parent.exists())
        self.assertFalse(os.path.lexists(self.destination))
        self.run.assert_not_called()

    def test_refuses_existing_guest_without_changing_it_or_mounting(self):
        self.destination.mkdir(parents=True)
        marker = self.destination / "user-data"
        marker.write_bytes(b"preserve existing guest")
        with patch.object(fetcher, "download_image") as download:
            with self.assertRaises((ValueError, OSError)):
                self.fetch()
        self.assertEqual(marker.read_bytes(), b"preserve existing guest")
        self.assertEqual(self.events, [])
        download.assert_not_called()
        self.run.assert_not_called()

    def test_refuses_broken_symlink_destination(self):
        self.destination.parent.mkdir(parents=True)
        self.destination.symlink_to(self.directory / "missing", target_is_directory=True)
        with self.assertRaises((ValueError, OSError)):
            self.fetch()
        self.assertTrue(self.destination.is_symlink())
        self.assertEqual(self.events, [])
        self.run.assert_not_called()

    def test_refuses_symlink_destination_ancestors_without_writing_through_them(self):
        outside = self.directory / "outside"
        outside.mkdir()
        for name in ("Omabox", "Omabox/Resources"):
            with self.subTest(name=name):
                ancestor = self.root / name
                ancestor.parent.mkdir(parents=True, exist_ok=True)
                ancestor.symlink_to(outside, target_is_directory=True)
                try:
                    with self.assertRaises(ValueError):
                        self.fetch()
                    self.assertEqual(list(outside.iterdir()), [])
                    self.run.assert_not_called()
                finally:
                    ancestor.unlink()

    def test_tampered_image_never_mounts_or_publishes(self):
        self.image.write_bytes(b"x" * self.image.stat().st_size)
        with self.assertRaises(ValueError):
            self.fetch()
        self.assertEqual(self.events, ["verify-image"])
        self.assertFalse(os.path.lexists(self.destination))
        self.run.assert_not_called()

    def test_copy_failure_detaches_without_publishing(self):
        self.mount_mutation = lambda guest: (guest / "kernel").unlink()
        with self.assertRaises((ValueError, OSError)):
            self.fetch()
        self.assertEqual(self.events, ["verify-image", "attach", "detach"])
        self.assertFalse(os.path.lexists(self.destination))
        self.assertFalse(self.mount.parent.exists())

    def test_attach_failure_attempts_detach_and_removes_unmounted_work(self):
        self.fail_attach = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.fetch()
        self.assertEqual(self.events, ["verify-image", "attach", "detach"])
        self.assertFalse(os.path.lexists(self.destination))
        self.assertFalse(self.mount.parent.exists())

    def test_repository_verification_failure_detaches_without_publishing(self):
        self.fail_verifier = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.fetch()
        self.assertEqual(self.events, ["verify-image", "attach", "verify-guest", "detach"])
        self.assertFalse(os.path.lexists(self.destination))
        self.assertFalse(self.mount.parent.exists())

    def test_detach_failure_does_not_publish_verified_guest(self):
        self.fail_detach = True
        with self.assertRaises((ValueError, OSError, subprocess.CalledProcessError)):
            self.fetch()
        self.assertIn("verify-guest", self.events)
        self.assertEqual(self.events[-1], "detach")
        self.assertFalse(os.path.lexists(self.destination))
        self.assertTrue(self.mount.is_dir())
        self.rename.assert_not_called()

    def test_concurrent_destination_is_preserved_after_detach(self):
        self.destination_race = True
        with self.assertRaises((ValueError, OSError)):
            self.fetch()
        self.assertEqual((self.destination / "keep.txt").read_text(), "concurrent destination")
        self.assertEqual({path.name for path in self.destination.iterdir()}, {"keep.txt"})

    def test_native_exclusive_rename_failure_preserves_racing_destination(self):
        def destination_created_during_rename(source, destination, flags):
            self.assertEqual(flags, 0x00000004)
            self.destination.mkdir()
            (self.destination / "keep.txt").write_text("created at rename")
            return -1

        self.rename.side_effect = destination_created_during_rename
        with patch.object(fetcher.ctypes, "get_errno", return_value=errno.EEXIST):
            with self.assertRaises(FileExistsError):
                self.fetch()
        self.assertEqual((self.destination / "keep.txt").read_text(), "created at rename")
        self.assertEqual({path.name for path in self.destination.iterdir()}, {"keep.txt"})
        self.assertFalse(self.mount.parent.exists())


if __name__ == "__main__":
    unittest.main()
