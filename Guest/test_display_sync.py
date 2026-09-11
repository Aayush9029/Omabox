import importlib.util
import math
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch


MODULE_PATH = Path(__file__).parent / "overlay/usr/local/libexec/omabox-display-sync.py"
SPEC = importlib.util.spec_from_file_location("omabox_display_sync", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Cannot load the display synchronization service")
display_sync = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = display_sync
SPEC.loader.exec_module(display_sync)


def preferred_mode(**changes):
    mode = {
        "clock": 65000,
        "hdisplay": 1024,
        "hsync_start": 1048,
        "hsync_end": 1184,
        "htotal": 1344,
        "hskew": 0,
        "vdisplay": 768,
        "vsync_start": 771,
        "vsync_end": 777,
        "vtotal": 806,
        "vscan": 0,
        "vrefresh": 60,
        "flags": 10,
        "type": 8,
    }
    mode.update(changes)
    return mode


class DisplayPreferencesTests(unittest.TestCase):
    def test_dynamic_resolution_defaults_to_enabled(self):
        for text in ("", "# Personal desktop settings\n", "LP_NUM_THREADS=2\n"):
            with self.subTest(text=text):
                self.assertIs(display_sync.parse_dynamic_resolution(text), True)

    def test_explicit_values_and_last_valid_assignment(self):
        cases = {
            "OMABOX_DYNAMIC_RESOLUTION=0": False,
            "OMABOX_DYNAMIC_RESOLUTION=1": True,
            "OMABOX_DYNAMIC_RESOLUTION=0\nOMABOX_DYNAMIC_RESOLUTION=1": True,
            "OMABOX_DYNAMIC_RESOLUTION=1\nOMABOX_DYNAMIC_RESOLUTION=0": False,
            "OMABOX_DYNAMIC_RESOLUTION=0\nOMABOX_DYNAMIC_RESOLUTION=invalid": False,
        }
        for text, expected in cases.items():
            with self.subTest(text=text):
                self.assertIs(display_sync.parse_dynamic_resolution(text), expected)

    def test_nonliteral_values_cannot_change_the_setting(self):
        for value in ("true", "false", "2", "-1", "", '"0"', "'0'", "$(echo 0)", "0; echo ignored"):
            with self.subTest(value=value):
                self.assertIs(
                    display_sync.parse_dynamic_resolution(f"OMABOX_DYNAMIC_RESOLUTION={value}"),
                    True,
                )
        for text in ("# OMABOX_DYNAMIC_RESOLUTION=0", "OTHER_OMABOX_DYNAMIC_RESOLUTION=0"):
            with self.subTest(text=text):
                self.assertIs(display_sync.parse_dynamic_resolution(text), True)

    def test_host_dynamic_resolution_overrides_guest_and_empty_host_preserves_guest(self):
        with tempfile.TemporaryDirectory() as directory:
            guest = Path(directory) / "guest.env"
            host = Path(directory) / "host.env"
            guest.write_text("OMABOX_DYNAMIC_RESOLUTION=0\n")
            self.assertFalse(display_sync.dynamic_resolution_enabled(guest, host))
            host.write_text("")
            self.assertFalse(display_sync.dynamic_resolution_enabled(guest, host))
            host.write_text("OMABOX_DYNAMIC_RESOLUTION=1\n")
            self.assertTrue(display_sync.dynamic_resolution_enabled(guest, host))
            guest.write_text("OMABOX_DYNAMIC_RESOLUTION=1\n")
            host.write_text("OMABOX_DYNAMIC_RESOLUTION=0\r\n")
            self.assertFalse(display_sync.dynamic_resolution_enabled(guest, host))
            host.write_text("OMABOX_DYNAMIC_RESOLUTION=invalid\n")
            self.assertTrue(display_sync.dynamic_resolution_enabled(guest, host))
            self.assertEqual(guest.read_text(), "OMABOX_DYNAMIC_RESOLUTION=1\n")

    def test_scale_accepts_finite_numbers_including_endpoints(self):
        for value in (0.25, 0.5, 1, 1.25, 2, 4):
            with self.subTest(value=value):
                result = display_sync.validated_scale(value)
                self.assertIsInstance(result, float)
                self.assertEqual(result, float(value))

    def test_scale_rejects_nonfinite_out_of_range_and_nonnumeric_values(self):
        for value in (True, False, None, "1", [], {}, math.nan, math.inf, -math.inf, 0, 0.249, 4.001, 10**1000, -(10**1000)):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    display_sync.validated_scale(value)


class AutomaticScaleTests(unittest.TestCase):
    def test_presets_scale_the_logical_workspace(self):
        for width, height, expected in [(512,320,0.5),(960,600,0.75),(1280,800,1),(1440,900,1.25),(1920,1200,1.5),(2560,1600,2),(4096,2560,3.2)]:
            with self.subTest(width=width, height=height):
                self.assertEqual(display_sync.automatic_scale(width, height), expected)

    def test_arbitrary_fit_sizes_always_have_integral_logical_dimensions(self):
        for width, height in [(1278,744),(1552,1024),(1427,888),(1918,1078),(2304,1438),(8192,8192),(64,64)]:
            with self.subTest(width=width, height=height):
                scale = display_sync.automatic_scale(width, height)
                self.assertGreaterEqual(scale, 0.5)
                self.assertLessEqual(scale, 4)
                self.assertAlmostEqual(width / scale, round(width / scale))
                self.assertAlmostEqual(height / scale, round(height / scale))

    def test_scale_comparison_accounts_for_hyprctl_decimal_rounding(self):
        self.assertTrue(display_sync.scales_match(1.07, 128 / 120))
        self.assertFalse(display_sync.scales_match(1.08, 128 / 120))

    def test_rejects_invalid_geometry(self):
        for width, height in [(0,800),(800,8193),(True,800),(800,2.5)]:
            with self.assertRaises(ValueError):
                display_sync.automatic_scale(width, height)

    def synchronizer(self, directory):
        root = Path(directory)
        connector = root / "card0-Virtual-1"
        connector.mkdir()
        (connector / "status").write_text("connected")
        mode = preferred_mode(hdisplay=1280,hsync_start=1300,hsync_end=1320,htotal=1440,vdisplay=800,vsync_start=805,vsync_end=810,vtotal=850)
        synchronizer = display_sync.DisplaySynchronizer(root / "desktop.env", root, Mock(preferred_mode=Mock(return_value=mode)))
        synchronizer.environment = {}
        synchronizer.monitors = Mock(side_effect=[
            [{"name":"Virtual-1","description":"","width":1280,"height":800,"scale":2}],
            [{"name":"Virtual-1","description":"","width":1280,"height":800,"scale":1}],
        ])
        return synchronizer

    def test_scale_updates_even_when_pixel_dimensions_already_match(self):
        with tempfile.TemporaryDirectory() as directory:
            synchronizer = self.synchronizer(directory)
            with patch.object(display_sync, "dynamic_resolution_enabled", return_value=True), patch.object(display_sync, "display_policy", return_value=("automatic",None)), patch.object(display_sync, "hyprctl", return_value="ok") as control:
                synchronizer.update()
                self.assertIn("scale = 1", control.call_args.args[1])
                self.assertIn("omabox_apply_display", control.call_args.args[1])

    def test_manual_monitor_policy_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            synchronizer = self.synchronizer(directory)
            with patch.object(display_sync, "dynamic_resolution_enabled", return_value=True), patch.object(display_sync, "display_policy", return_value=("manual",None)), patch.object(display_sync, "hyprctl") as control:
                synchronizer.update()
                control.assert_not_called()


class ModelineTests(unittest.TestCase):
    def test_preserves_complete_geometry_and_sync_polarity(self):
        self.assertEqual(
            display_sync.modeline(preferred_mode()),
            "modeline 65 1024 1048 1184 1344 768 771 777 806 -hsync -vsync",
        )

    def test_nonstandard_width_is_preserved(self):
        mode = preferred_mode(
            hdisplay=1278, hsync_start=1302, hsync_end=1438, htotal=1598,
            vdisplay=744, vsync_start=747, vsync_end=753, vtotal=782,
        )
        self.assertEqual(
            display_sync.modeline(mode),
            "modeline 65 1278 1302 1438 1598 744 747 753 782 -hsync -vsync",
        )

    def test_pixel_clock_rounds_to_integer_mhz(self):
        for clock, expected in ((65000, "65"), (74250, "74"), (74499, "74"), (74500, "75")):
            with self.subTest(clock=clock):
                self.assertEqual(display_sync.modeline(preferred_mode(clock=clock)).split()[1], expected)

    def test_supported_sync_polarities(self):
        for flags, polarity in ((5, "+hsync +vsync"), (6, "-hsync +vsync"), (9, "+hsync -vsync"), (10, "-hsync -vsync")):
            with self.subTest(flags=flags):
                self.assertTrue(display_sync.modeline(preferred_mode(flags=flags)).endswith(polarity))

    def test_geometry_bounds_are_inclusive(self):
        for size in (64, 8192):
            with self.subTest(size=size):
                mode = preferred_mode(
                    hdisplay=size, hsync_start=size + 8, hsync_end=size + 16, htotal=size + 24,
                    vdisplay=size, vsync_start=size + 3, vsync_end=size + 6, vtotal=size + 9,
                )
                self.assertIn(f" {size} ", display_sync.modeline(mode))

    def test_rejects_dimensions_outside_shipping_bounds(self):
        for field in ("hdisplay", "vdisplay"):
            for value in (0, 63, 8193, 16384):
                with self.subTest(field=field, value=value):
                    with self.assertRaises(ValueError):
                        display_sync.modeline(preferred_mode(**{field: value}))

    def test_rejects_invalid_sync_timing_relationships(self):
        changes = (
            {"hsync_start": 1024}, {"hsync_start": 1023}, {"hsync_end": 1048},
            {"htotal": 1183}, {"htotal": 65536}, {"vsync_start": 768},
            {"vsync_start": 767}, {"vsync_end": 771}, {"vtotal": 776}, {"vtotal": 65536},
        )
        for change in changes:
            with self.subTest(change=change):
                with self.assertRaises(ValueError):
                    display_sync.modeline(preferred_mode(**change))

    def test_rejects_invalid_clocks_and_unsupported_scan_flags(self):
        for clock in (0, 999, 4_000_001):
            with self.subTest(clock=clock):
                with self.assertRaises(ValueError):
                    display_sync.modeline(preferred_mode(clock=clock))
        for flags in (0, 1, 2, 3, 4, 7, 8, 11, 12, 13, 14, 15, 10 | 16, 10 | 32):
            with self.subTest(flags=flags):
                with self.assertRaises(ValueError):
                    display_sync.modeline(preferred_mode(flags=flags))
        for change in ({"hskew": 1}, {"vscan": 2}):
            with self.subTest(change=change):
                with self.assertRaises(ValueError):
                    display_sync.modeline(preferred_mode(**change))


class HotplugDebouncerTests(unittest.TestCase):
    def setUp(self):
        self.debouncer = display_sync.HotplugDebouncer()

    def feed_event(self, now, *properties):
        for line in properties:
            self.debouncer.feed(line, now)
        self.debouncer.feed("", now)

    def relevant_event(self, now):
        self.feed_event(now, "ACTION=change", "HOTPLUG=1")

    def test_requires_a_complete_relevant_event(self):
        self.assertIsNone(self.debouncer.deadline)
        self.debouncer.feed("ACTION=change", 1)
        self.debouncer.feed("HOTPLUG=1", 1)
        self.assertIsNone(self.debouncer.deadline)
        self.debouncer.feed("", 1)
        self.assertAlmostEqual(self.debouncer.deadline, 1.12)

    def test_ignores_irrelevant_events_and_resets_event_properties(self):
        for properties in (
            (), ("ACTION=change",), ("HOTPLUG=1",),
            ("ACTION=add", "HOTPLUG=1"), ("ACTION=change", "HOTPLUG=0"),
            ("ACTION=change", "HOTPLUG=10"), ("OTHER_ACTION=change", "HOTPLUG=1"),
        ):
            with self.subTest(properties=properties):
                self.feed_event(1, *properties)
                self.assertIsNone(self.debouncer.deadline)

    def test_accepts_properties_in_either_order_with_udev_header(self):
        self.feed_event(1, "UDEV  [1.000] change /devices/platform/virtio/drm/card0 (drm)",
                        "HOTPLUG=1", "DEVPATH=/devices/platform/virtio/drm/card0", "ACTION=change")
        self.assertAlmostEqual(self.debouncer.deadline, 1.12)

    def test_latency_budget_starts_at_event_completion(self):
        self.debouncer.feed("ACTION=change", 0)
        self.debouncer.feed("HOTPLUG=1", 0.5)
        self.debouncer.feed("", 1)
        self.assertAlmostEqual(self.debouncer.deadline, 1.12)

    def test_pop_due_retains_pending_deadline_until_it_fires_once(self):
        self.assertFalse(self.debouncer.pop_due(1))
        self.relevant_event(1)
        deadline = self.debouncer.deadline
        self.assertFalse(self.debouncer.pop_due(deadline - 0.001))
        self.assertEqual(self.debouncer.deadline, deadline)
        self.assertTrue(self.debouncer.pop_due(deadline))
        self.assertIsNone(self.debouncer.deadline)
        self.assertFalse(self.debouncer.pop_due(deadline + 1))

    def test_short_burst_waits_after_the_last_complete_event(self):
        self.relevant_event(1)
        self.relevant_event(1.08)
        self.assertAlmostEqual(self.debouncer.deadline, 1.20)
        self.assertFalse(self.debouncer.pop_due(1.13))

    def test_continuous_burst_cannot_postpone_beyond_half_a_second(self):
        for now in (0, 0.1, 0.2, 0.3, 0.4, 0.49):
            self.relevant_event(now)
        self.assertAlmostEqual(self.debouncer.deadline, 0.5)
        self.assertTrue(self.debouncer.pop_due(0.5))

    def test_irrelevant_event_does_not_extend_a_pending_deadline(self):
        self.relevant_event(1)
        deadline = self.debouncer.deadline
        self.feed_event(1.1, "ACTION=change", "HOTPLUG=0")
        self.assertEqual(self.debouncer.deadline, deadline)

    def test_next_burst_gets_a_fresh_latency_budget(self):
        for now in (1, 1.1, 1.2, 1.3, 1.4, 1.49):
            self.relevant_event(now)
        self.assertTrue(self.debouncer.pop_due(1.5))
        self.relevant_event(2)
        self.assertAlmostEqual(self.debouncer.deadline, 2.12)
        self.relevant_event(2.45)
        self.assertAlmostEqual(self.debouncer.deadline, 2.5)


if __name__ == "__main__":
    unittest.main()
