#!/usr/bin/env python3

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).parent / "overlay/usr/local/libexec/omabox-desktop-environment.sh"


class EnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="omabox-env-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.guest = self.directory / "guest.env"
        self.host = self.directory / "host.env"
        self.guest.write_text("")
        self.host.write_text("")

    def load(self, setup="", after=""):
        script = """
set -euo pipefail
source "$1"
export OMABOX_DISPLAY_SCALE=auto
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export LP_NUM_THREADS=8
""" + setup + """
omabox_load_desktop_environment "$2" "$3"
""" + after + """
"$4" -c 'import json, os; print(json.dumps(dict(os.environ)))'
"""
        result = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", script, "environment-test", str(HELPER), str(self.guest), str(self.host), sys.executable],
            env={"PATH": "/usr/bin:/bin", "HOME": str(self.directory / "original-home"), "LC_ALL": "C"},
            capture_output=True,
            text=True,
            timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)

    def test_host_overrides_guest_and_guest_overrides_defaults(self):
        self.guest.write_text("OMABOX_DISPLAY_SCALE=1\nLP_NUM_THREADS=4\nGUEST_ONLY=guest\n")
        self.host.write_text("LP_NUM_THREADS=2\nHOST_ONLY=host\n")
        environment = self.load()
        self.assertEqual(environment["OMABOX_DISPLAY_SCALE"], "1")
        self.assertEqual(environment["LP_NUM_THREADS"], "2")
        self.assertEqual(environment["GUEST_ONLY"], "guest")
        self.assertEqual(environment["HOST_ONLY"], "host")
        self.assertEqual(environment["LIBGL_ALWAYS_SOFTWARE"], "1")
        self.assertEqual(environment["GALLIUM_DRIVER"], "llvmpipe")

    def test_missing_or_empty_host_preserves_guest_settings(self):
        self.guest.write_text("LP_NUM_THREADS=3\n")
        self.assertEqual(self.load()["LP_NUM_THREADS"], "3")
        self.host.unlink()
        self.assertEqual(self.load()["LP_NUM_THREADS"], "3")

    def test_missing_inputs_preserve_defaults(self):
        self.guest.unlink()
        self.host.unlink()
        environment = self.load()
        self.assertEqual(environment["OMABOX_DISPLAY_SCALE"], "auto")
        self.assertEqual(environment["LP_NUM_THREADS"], "8")

    def test_directory_input_is_ignored(self):
        self.host.unlink()
        self.host.mkdir()
        self.assertEqual(self.load()["LP_NUM_THREADS"], "8")

    def test_values_are_literal_and_never_execute(self):
        sentinel = self.directory / "executed"
        values = {
            "COMMAND": f"$(/usr/bin/touch {sentinel})",
            "BACKTICKS": f"`/usr/bin/touch {sentinel}`",
            "PARAMETER": "${HOME}",
            "QUOTES": "'single' and \"double\"",
            "BACKSLASHES": r"one\two\nthree",
            "SPACES": "  padded value  ",
            "EQUALS": "first=second=third",
            "INLINE_COMMENT": "value # literal suffix",
            "SEMICOLON": f"value; /usr/bin/touch {sentinel}",
        }
        self.host.write_text("\n".join(f"{key}={value}" for key, value in values.items()) + "\n")
        environment = self.load()
        for key, expected in values.items():
            with self.subTest(key=key):
                self.assertEqual(environment[key], expected)
        self.assertFalse(sentinel.exists())

    def test_malformed_lines_are_ignored(self):
        self.host.write_text("\n# comment=value\nMISSING_EQUALS\n INVALID=x\nexport EXPORTED=x\n1INVALID=x\nDASH-KEY=x\nKEY SPACE=x\n=empty-key\nVALID=value\n")
        environment = self.load()
        self.assertEqual(environment["VALID"], "value")
        for name in ("INVALID", "EXPORTED", "1INVALID", "DASH-KEY", "KEY SPACE", ""):
            self.assertNotIn(name, environment)

    def test_crlf_empty_values_and_unterminated_final_line(self):
        self.guest.write_bytes(b"EMPTY=guest\r\nGDK_SCALE=1\r\n")
        self.host.write_bytes(b"EMPTY=\r\nGDK_SCALE=2\r\nLAST=without-newline")
        environment = self.load()
        self.assertEqual(environment["EMPTY"], "")
        self.assertEqual(environment["GDK_SCALE"], "2")
        self.assertEqual(environment["OMABOX_GDK_SCALE"], "2")
        self.assertEqual(environment["LAST"], "without-newline")

    def test_host_without_gdk_scale_preserves_guest_marker(self):
        self.guest.write_text("GDK_SCALE=2\n")
        self.host.write_text("HOST_ONLY=value\n")
        self.assertEqual(self.load()["OMABOX_GDK_SCALE"], "2")

    def test_home_path_and_internal_names_cannot_redirect_inputs(self):
        self.guest.write_text("HOME=/different-home\nPATH=/different-bin\nOMABOX_GUEST_PREFERENCES=/different-config\n_omabox_env_host_path=/missing.env\n_omabox_env_path=/missing.env\n_omabox_env_entry=ignored\n_omabox_env_key=ignored\n")
        self.host.write_text("FROM_HOST=expected\n")
        environment = self.load()
        self.assertEqual(environment["HOME"], "/different-home")
        self.assertEqual(environment["PATH"], "/different-bin")
        self.assertEqual(environment["FROM_HOST"], "expected")
        self.assertNotIn("OMABOX_GUEST_PREFERENCES", environment)
        self.assertFalse(any(key.startswith("_omabox_env_") for key in environment))

    def test_readonly_and_arithmetic_targets_do_not_abort_or_execute(self):
        sentinel = self.directory / "arithmetic-executed"
        payload = f"array[$(/usr/bin/touch {sentinel})]"
        self.host.write_text(f"UID={payload}\nRANDOM={payload}\nINTEGER={payload}\nINDEXED={payload}\nLOCKED=changed\nVALID=after\n")
        environment = self.load(setup="readonly LOCKED=original\ndeclare -i INTEGER=7\ndeclare -a INDEXED=(original)\nexport LOCKED INTEGER\n")
        self.assertEqual(environment["LOCKED"], "original")
        self.assertEqual(environment["INTEGER"], "7")
        self.assertEqual(environment["VALID"], "after")
        self.assertFalse(sentinel.exists())

    def test_shell_startup_hooks_are_not_exported(self):
        sentinel = self.directory / "startup-executed"
        startup = self.directory / "startup.sh"
        startup.write_text(f"/usr/bin/touch '{sentinel}'\n")
        self.host.write_text(f"BASH_ENV={startup}\nENV={startup}\nPROMPT_COMMAND=/usr/bin/touch {sentinel}\nPS4=$(/usr/bin/touch {sentinel})\nBASH_XTRACEFD=1\nVALID=after\n")
        environment = self.load(after="/bin/bash --noprofile --norc -c true\n")
        for key in ("BASH_ENV", "ENV", "PROMPT_COMMAND", "PS4", "BASH_XTRACEFD"):
            self.assertNotIn(key, environment)
        self.assertEqual(environment["VALID"], "after")
        self.assertFalse(sentinel.exists())

    def test_inputs_are_not_modified(self):
        self.guest.write_bytes(b"GUEST=original\r\n")
        self.host.write_bytes(b"HOST=original\n")
        before = [(path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_mode) for path in (self.guest, self.host)]
        self.load()
        after = [(path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_mode) for path in (self.guest, self.host)]
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
