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
events = {}
commands = {}
hl = {
  monitor = function() end,
  env = function() end,
  on = function(event, callback) events[event] = callback end,
  exec_cmd = function(command) commands[#commands + 1] = command end,
}
local original_dofile = dofile
dofile = function(path)
  if path == '/mnt/omabox-config/hyprland.lua' then return original_dofile(arg[2]) end
  if path == '/usr/local/share/omabox/display-policy.lua' then return original_dofile(arg[3]) end
  return original_dofile(path)
end
original_dofile(arg[1])
'''


@unittest.skipUnless(LUA, 'Lua is required for configuration runtime tests')
class ConfigurationLuaTests(unittest.TestCase):
    def apply(self, host, assertions=''):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            guest = root / 'hyprland.lua'
            guest.write_text('settings.value = 3\n')
            host_file = root / 'host.lua'
            if host is not None:
                host_file.write_text(host)
            harness = root / 'harness.lua'
            harness.write_text(HARNESS + assertions + '\nprint(settings.value)\n')
            environment = {**os.environ, 'OMABOX_GUEST_PREFERENCES': str(root)}
            result = subprocess.run([LUA, str(harness), str(RUNTIME), str(host_file), str(RUNTIME.with_name('display-policy.lua'))], env=environment,
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

    def test_resynchronization_waits_for_reload_and_preserves_user_policy(self):
        self.assertEqual(self.apply('hl.monitor({output="",mode="1024x768",scale=1.25})', '''
assert(#commands == 0)
assert(type(events["config.reloaded"]) == "function")
assert(omabox_display_policy("Virtual-1", "") == "manual")
events["config.reloaded"]()
assert(#commands == 1)
assert(commands[1] == "systemctl --user --no-block try-restart omabox-display-sync.service")
assert(omabox_display_policy("Virtual-1", "") == "manual")
'''), '3')


if __name__ == '__main__':
    unittest.main()
