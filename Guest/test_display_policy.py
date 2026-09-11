import os
from pathlib import Path
import shutil
import subprocess
import unittest

LUA = shutil.which('lua')
POLICY = Path(__file__).parent / 'overlay/usr/local/share/omabox/display-policy.lua'


@unittest.skipUnless(LUA, 'Lua is required for display policy tests')
class DisplayPolicyTests(unittest.TestCase):
    def run_policy(self, assertions, requested='auto'):
        setup = 'applied = {}; hl = { monitor = function(rule) assert(type(rule)=="table"); applied[#applied+1]=rule end }; dofile(arg[1]); '
        subprocess.run([LUA, '-', str(POLICY)], input=setup + assertions, text=True,
                       capture_output=True, check=True, timeout=5,
                       env={**os.environ, 'OMABOX_DISPLAY_SCALE': requested})

    def test_numeric_environment_is_fixed_and_auto_is_adaptive(self):
        for value in ['1','2','1.25']:
            self.run_policy('assert(omabox_display_policy("Virtual-1","")=="fixed:' + value + '")', value)
        self.run_policy('assert(omabox_display_policy("Virtual-1","")=="automatic")')

    def test_later_explicit_scale_overrides_environment_and_auto_restores_adaptation(self):
        self.run_policy('hl.monitor({output="",scale=1.5}); assert(omabox_display_policy("Virtual-1","")=="fixed:1.5"); hl.monitor({output="",scale="auto"}); assert(omabox_display_policy("Virtual-1","")=="automatic")','2')

    def test_manual_modes_stop_synchronization_until_explicitly_restored(self):
        self.run_policy('hl.monitor({output="",mode="1024x768",scale=1}); assert(omabox_display_policy("Virtual-1","")=="manual"); hl.monitor({output="",scale="auto"}); assert(omabox_display_policy("Virtual-1","")=="manual"); hl.monitor({output="",mode="preferred"}); assert(omabox_display_policy("Virtual-1","")=="automatic")')

    def test_unrelated_monitor_rules_do_not_disable_virtual_monitor(self):
        self.run_policy('hl.monitor({output="DP-1",mode="1920x1080",scale=2}); assert(omabox_display_policy("Virtual-1","")=="automatic"); assert(omabox_display_policy("DP-1","")=="manual")')

    def test_matching_named_and_description_rules_take_precedence(self):
        self.run_policy('hl.monitor({output="",scale="auto"}); hl.monitor({output="Virtual-1",scale=2}); assert(omabox_display_policy("Virtual-1","")=="fixed:2"); hl.monitor({output="desc:Test panel",mode="1024x768"}); assert(omabox_display_policy("Virtual-2","Test panel 123")=="manual")')

    def test_managed_updates_do_not_change_user_policy(self):
        self.run_policy('omabox_apply_display("Virtual-1","","automatic",{output="",mode="modeline fixture",scale=1.25}); assert(#applied==1); assert(omabox_display_policy("Virtual-1","")=="automatic")')

    def test_policy_change_between_query_and_apply_blocks_stale_update(self):
        self.run_policy('hl.monitor({output="",mode="1024x768",scale=1}); local count=#applied; omabox_apply_display("Virtual-1","","automatic",{output="",scale=2}); assert(#applied==count); assert(omabox_display_policy("Virtual-1","")=="manual")')


if __name__ == '__main__':
    unittest.main()
