import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


RUNTIME = Path(__file__).parent / 'overlay/usr/local/share/omabox/runtime.lua'
LUA = shutil.which('lua')
HARNESS = '''
settings = {}
hl = { monitor = function() end, env = function() end }
local original_dofile = dofile
dofile = function(path)
  return original_dofile(path == '/mnt/omabox-config/hyprland.lua' and arg[2] or path)
end
original_dofile(arg[1])
print(settings.value)
'''


@unittest.skipUnless(LUA, 'Lua is required for configuration runtime tests')
class ConfigurationLuaTests(unittest.TestCase):
    def apply(self, host):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            guest = root / 'hyprland.lua'
            guest.write_text('settings.value = 3\n')
            host_file = root / 'host.lua'
            if host is not None:
                host_file.write_text(host)
            harness = root / 'harness.lua'
            harness.write_text(HARNESS)
            environment = {**os.environ, 'OMABOX_GUEST_PREFERENCES': str(root)}
            result = subprocess.run([LUA, str(harness), str(RUNTIME), str(host_file)], env=environment,
                                    check=True, text=True, capture_output=True, timeout=5)
            self.assertEqual(guest.read_text(), 'settings.value = 3\n')
            if host is not None:
                self.assertEqual(host_file.read_text(), host)
            return result.stdout.strip()

    def test_host_configuration_applies_after_guest(self):
        self.assertEqual(self.apply('settings.value = settings.value + 4\n'), '7')

    def test_empty_and_missing_host_configuration_preserve_guest(self):
        self.assertEqual(self.apply(''), '3')
        self.assertEqual(self.apply(None), '3')

    def test_malformed_host_lua_does_not_interrupt_runtime(self):
        self.assertEqual(self.apply('invalid Lua { broken'), '3')

    def test_host_runtime_error_does_not_interrupt_runtime(self):
        self.assertEqual(self.apply('error("invalid Mac preference")'), '3')


if __name__ == '__main__':
    unittest.main()
