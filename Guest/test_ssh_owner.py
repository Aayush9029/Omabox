#!/usr/bin/env python3

import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).parent / "overlay/usr/local/libexec/omabox-record-owner.py"
SPEC = importlib.util.spec_from_file_location("omabox_record_owner", SOURCE)
OWNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(OWNER)


class OwnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="omabox-owner-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.uid = os.getuid()
        self.autologin = self.root / "etc/sddm.conf.d/autologin.conf"
        self.autologin.parent.mkdir(parents=True)
        self.provisioning = self.root / "var/lib/omarchy/provisioning"
        self.provisioning.mkdir(parents=True)
        self.autologin.write_text("[Autologin]\nUser=owner\nSession=omarchy.desktop\n")
        self.marker = self.root / "var/lib/omabox/owner.json"
        self.account = SimpleNamespace(pw_name="owner", pw_uid=1000, pw_shell="/bin/bash")

    def record(self):
        return OWNER.record_owner(self.root, self.uid, lambda user: self.account)

    def test_capture_survives_autologin_cleanup_without_replacing_identity(self):
        self.assertTrue(self.record())
        self.assertEqual(json.loads(self.marker.read_text()), {"user": "owner", "uid": 1000})
        self.assertEqual(stat.S_IMODE(self.marker.stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE(self.marker.parent.stat().st_mode), 0o755)
        self.assertFalse(self.record())
        self.autologin.unlink()
        self.assertEqual(OWNER.read_saved_owner(self.marker, self.root, self.uid), {"user": "owner", "uid": 1000})
        self.assertEqual(list(self.marker.parent.glob(".owner-*")), [])

    def test_incomplete_and_wipe_pending_never_publish(self):
        for name in ("pending", "wipe-pending"):
            with self.subTest(name=name):
                pending = self.provisioning / name
                pending.touch()
                with self.assertRaises(OWNER.OwnerError):
                    self.record()
                self.assertFalse(self.marker.exists())
                pending.unlink()

    def test_dangling_pending_symlink_blocks_capture(self):
        (self.provisioning / "pending").symlink_to("missing")
        with self.assertRaises(OWNER.OwnerError):
            self.record()
        self.assertFalse(self.marker.exists())

    def test_missing_autologin_does_not_guess_an_account(self):
        self.autologin.unlink()
        with self.assertRaises(FileNotFoundError):
            self.record()
        self.assertFalse(self.marker.exists())

    def test_symlink_and_writable_sources_are_rejected(self):
        original = self.autologin.read_text()
        self.autologin.chmod(0o666)
        with self.assertRaises(OWNER.OwnerError):
            self.record()
        self.autologin.unlink()
        alternate = self.root / "other.conf"
        alternate.write_text(original)
        self.autologin.symlink_to(alternate)
        with self.assertRaises(OSError):
            self.record()
        self.assertFalse(self.marker.exists())

    def test_writable_or_symlink_parent_is_rejected(self):
        self.autologin.parent.chmod(0o777)
        with self.assertRaises(OWNER.OwnerError):
            self.record()
        self.autologin.parent.chmod(0o755)
        original = self.autologin.parent
        replacement = original.with_name("real-sddm")
        original.rename(replacement)
        original.symlink_to(replacement, target_is_directory=True)
        with self.assertRaises(OWNER.OwnerError):
            self.record()
        self.assertFalse(self.marker.exists())

    def test_foreign_file_owner_is_rejected(self):
        with self.assertRaises(OWNER.OwnerError):
            OWNER.record_owner(self.root, self.uid + 1, lambda user: self.account)

    def test_ambiguous_and_injected_autologin_is_rejected(self):
        invalid = [
            "[Autologin]\nUser=owner\nUser=other\nSession=omarchy.desktop\n",
            "[DEFAULT]\nUser=owner\n[Autologin]\nSession=omarchy.desktop\n",
            "[Autologin]\nUser=owner\nSession=other.desktop\n",
            "[Autologin]\nUser=owner\nSession=omarchy.desktop\n[Other]\nUser=other\n",
            "[Autologin]\nUser=owner\n  other\nSession=omarchy.desktop\n",
            "[Autologin]\nUser=root\nSession=omarchy.desktop\n",
            "[Autologin]\nUser=owner;id\nSession=omarchy.desktop\n",
            "[Autologin]\nUser=owner\x00\nSession=omarchy.desktop\n",
        ]
        for contents in invalid:
            with self.subTest(contents=contents), self.assertRaises(OWNER.OwnerError):
                OWNER.owner_from_autologin(contents, lambda user: self.account)

    def test_upstream_trailing_dollar_username_is_supported(self):
        account = SimpleNamespace(pw_name="owner$", pw_uid=1001, pw_shell="/bin/bash")
        contents = "[Autologin]\nUser=owner$\nSession=omarchy.desktop\n"
        self.assertEqual(OWNER.owner_from_autologin(contents, lambda user: account), {"user": "owner$", "uid": 1001})

    def test_non_owner_accounts_are_rejected(self):
        for account in [
            SimpleNamespace(pw_name="other", pw_uid=1000, pw_shell="/bin/bash"),
            SimpleNamespace(pw_name="owner", pw_uid=0, pw_shell="/bin/bash"),
            SimpleNamespace(pw_name="owner", pw_uid=999, pw_shell="/bin/bash"),
            SimpleNamespace(pw_name="owner", pw_uid=65534, pw_shell="/bin/bash"),
            SimpleNamespace(pw_name="owner", pw_uid=1000, pw_shell="/usr/bin/nologin"),
            SimpleNamespace(pw_name="owner", pw_uid=1000, pw_shell="/bin/false"),
        ]:
            self.account = account
            with self.subTest(account=account), self.assertRaises(OWNER.OwnerError):
                self.record()
            self.assertFalse(self.marker.exists())

    def test_existing_owner_cannot_be_reassigned(self):
        self.record()
        original = self.marker.read_bytes()
        self.account.pw_uid = 1001
        with self.assertRaises(OWNER.OwnerError):
            self.record()
        self.assertEqual(self.marker.read_bytes(), original)

    def test_malformed_existing_markers_cannot_be_replaced(self):
        self.marker.parent.mkdir(mode=0o755)
        for contents in [
            '{"user":"owner","uid":true}',
            '{"user":"owner","uid":1000,"uid":1001}',
            '{"user":"owner","uid":1000,"extra":true}',
            '[]',
            '{"user":"root","uid":1000}',
        ]:
            self.marker.write_text(contents)
            with self.subTest(contents=contents), self.assertRaises(OWNER.OwnerError):
                self.record()
            self.assertEqual(self.marker.read_text(), contents)

    def test_concurrent_owner_publication_is_not_overwritten(self):
        original_link = os.link

        def competing_link(source, target, **options):
            self.marker.write_text('{"user":"other","uid":1001}\n')
            return original_link(source, target, **options)

        with patch.object(OWNER.os, "link", side_effect=competing_link), self.assertRaises(OWNER.OwnerError):
            self.record()
        self.assertEqual(json.loads(self.marker.read_text()), {"user": "other", "uid": 1001})
        self.assertEqual(list(self.marker.parent.glob(".owner-*")), [])

    def test_new_provisioning_before_publication_aborts_capture(self):
        original_sync = os.fsync

        def start_provisioning(descriptor):
            original_sync(descriptor)
            (self.provisioning / "pending").touch()

        with patch.object(OWNER.os, "fsync", side_effect=start_provisioning), self.assertRaises(OWNER.OwnerError):
            self.record()
        self.assertFalse(self.marker.exists())
        self.assertEqual(list(self.marker.parent.glob(".owner-*")), [])

    def test_oversized_source_is_rejected(self):
        self.autologin.write_text("x" * (OWNER.MAX_FILE_BYTES + 1))
        with self.assertRaises(OWNER.OwnerError):
            self.record()
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
