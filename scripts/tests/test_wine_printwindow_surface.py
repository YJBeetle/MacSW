"""Offline wiring checks; printwindow-probe provides pixel/message evidence."""
from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH = "0011-win32u-printwindow-surface.patch"


class PrintWindowSurfaceTests(unittest.TestCase):
    def test_upstream_capture_is_recorded_without_retired_patch(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        self.assertFalse((PROJECT / "patches/wine-crossover" / PATCH).exists())
        for script in (build, package, verify):
            self.assertNotIn(PATCH, script)
            self.assertNotIn('WinePrintWindowPatchSHA256', script)
        for script in (package, verify):
            self.assertIn('WinePrintWindowImplementation', script)
            self.assertIn('upstream-surface-copy', script)
            self.assertIn('WineInputModuleSHA256', script)

    def test_installation_keeps_capture_resend_flag_without_retired_opt_in(self):
        registry = (PROJECT / 'macos/Bootstrap/Sources/MacSWCore/Services/RegistryService.swift').read_text()
        self.assertIn('value: "WINE_NOCAPTURERESEND"', registry)
        self.assertNotIn('WINE_PRINTWINDOW_SURFACE', registry)

    def test_diagnostic_is_optional_and_checks_pixels(self):
        self.assertIn('printwindow-probe:', (PROJECT / 'Makefile').read_text())
        self.assertNotIn('wine_printwindow_probe', (PROJECT / 'scripts/package_app.sh').read_text())
        probe = (PROJECT / 'native/wine_printwindow_probe.c').read_text()
        for feature in ('--legacy', '--unaware', 'occluded', 'GetPixel', 'WM_PRINTCLIENT', 'WS_VSCROLL'):
            self.assertIn(feature, probe)


if __name__ == '__main__':
    unittest.main()
