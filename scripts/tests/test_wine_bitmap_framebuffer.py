"""Offline patch/build contract; live drawing is checked by the native probe."""

from pathlib import Path
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH_NAME = "0008-winemac-bitmap-framebuffer.patch"


class BitmapFramebufferTests(unittest.TestCase):
    def test_patch_is_built_cached_packaged_and_verified(self):
        build = (PROJECT / "scripts/build_winemac.sh").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        self.assertIn(PATCH_NAME, build)
        self.assertIn('${BITMAP_PATCH_SHA256}', build.split('BUILD_KEY=', 1)[1].split('\n', 1)[0])
        self.assertIn('git -C "${SOURCE_DIR}" apply --check "${BITMAP_PATCH}"', build)
        self.assertIn(PATCH_NAME, package)
        self.assertIn(PATCH_NAME, verify)
        for script in (package, verify):
            self.assertIn("WineMacBitmapPatchSHA256", script)

    def test_upstream_fbo_implementation_is_retained(self):
        patch = (PROJECT / "patches/wine-crossover" / PATCH_NAME).read_text()
        self.assertNotIn("+++ b/dlls/winemac.drv/opengl.c", patch)
        self.assertIn("if (drawable->draw_fbo || drawable->read_fbo)", patch)
        self.assertIn("GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME", patch)
        self.assertIn("p_glTexSubImage2D", patch)
        self.assertIn("p_glReadPixels", patch)

    def test_memory_dc_conversion_is_confined_to_framebuffer_targets(self):
        patch = (PROJECT / "patches/wine-crossover" / PATCH_NAME).read_text()
        self.assertIn("+            if (drawable->draw_fbo || drawable->read_fbo)", patch)
        self.assertIn("convert_bitmapinfo( info, bits, &src, &buffer_info, buffer )", patch)
        self.assertIn("convert_bitmapinfo( &buffer_info, buffer, &src, info, bits )", patch)
        for state in ("alignment", "row_length", "skip_rows", "skip_pixels"):
            self.assertIn(f"p_glGetIntegerv( {state}, &old_{state} )", patch)
            self.assertIn(f"p_glPixelStorei( {state}, old_{state} )", patch)
        self.assertIn("p_glBindBuffer( buffer_target, old_buffer )", patch)
        self.assertIn("free( buffer )", patch)


if __name__ == "__main__":
    unittest.main()
