"""Offline Finder registration/COM bridge tests; never starts Wine or SW."""
import importlib.util
import plistlib
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

PROJECT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("open_document", PROJECT / "scripts/swcli/open_document.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class DocumentOpenTests(unittest.TestCase):
    def app(self, existing=False):
        document = Mock()
        document.GetTitle.return_value = "零件.SLDPRT"
        document.GetPathName.return_value = r"C:\模型 with spaces\零件.SLDPRT"
        app = Mock()
        app.GetOpenDocumentByName.return_value = document if existing else None
        app.OpenDoc6.return_value = document
        app.ActivateDoc3.return_value = document
        return app, document

    def open(self, app):
        return bridge.open_document(app, r"C:\模型 with spaces\零件.SLDPRT", lambda: SimpleNamespace(value=0))

    @patch.object(bridge.os.path, "samefile", return_value=True)
    def test_new_document_is_interactive_visible_and_never_saved_or_closed(self, _):
        app, _ = self.app()
        result = self.open(app)
        self.assertTrue(result["success"])
        self.assertFalse(result["reused"])
        self.assertIs(app.Visible, True)
        self.assertIs(app.UserControl, True)
        self.assertEqual(app.OpenDoc6.call_args.args[:4], (r"C:\模型 with spaces\零件.SLDPRT", 1, 0, ""))
        app.ActivateDoc3.assert_called_once()
        for name in ("Save", "SaveAs", "CloseDoc", "ExitApp"):
            getattr(app, name).assert_not_called()

    @patch.object(bridge.os.path, "samefile", return_value=True)
    def test_already_open_file_only_activates_without_reload(self, _):
        app, _ = self.app(existing=True)
        self.assertTrue(self.open(app)["reused"])
        app.OpenDoc6.assert_not_called()
        app.ActivateDoc3.assert_called_once()

    def test_open_failure_is_not_retried_and_wrong_active_file_is_rejected(self):
        app, _ = self.app()
        app.OpenDoc6.return_value = None
        with self.assertRaisesRegex(RuntimeError, "无法打开"):
            self.open(app)
        app.OpenDoc6.assert_called_once()
        app.ActivateDoc3.assert_not_called()
        app, _ = self.app(existing=True)
        with patch.object(bridge.os.path, "samefile", return_value=False):
            with self.assertRaisesRegex(RuntimeError, "目标文件"):
                self.open(app)

    def test_all_three_document_types_and_unsupported_extension(self):
        for extension, kind in bridge.DOCUMENT_TYPES.items():
            app, _ = self.app()
            with patch.object(bridge.os.path, "samefile", return_value=True):
                bridge.open_document(app, "C:\\model" + extension.upper(), lambda: SimpleNamespace(value=0))
            self.assertEqual(app.OpenDoc6.call_args.args[1], kind)
        app, _ = self.app()
        with self.assertRaises(ValueError):
            bridge.open_document(app, r"C:\model.exe", lambda: SimpleNamespace(value=0))
        app.OpenDoc6.assert_not_called()

    @patch.object(bridge.os.path, "samefile", return_value=True)
    def test_dynamic_com_getters_can_be_properties(self, _):
        app, document = self.app(existing=True)
        document.GetTitle = "零件.SLDPRT"
        document.GetPathName = r"C:\模型 with spaces\零件.SLDPRT"
        self.assertTrue(self.open(app)["success"])
        self.assertEqual(app.ActivateDoc3.call_args.args[:3], ("零件.SLDPRT", False, 1))

    def test_attach_waits_for_rot_and_never_creates_a_host(self):
        host = object()
        active = Mock(side_effect=[RuntimeError("not ready"), host])
        self.assertIs(bridge.attach(active, clock=lambda: 0, sleep=lambda _: None), host)
        self.assertEqual(active.call_count, 2)
        active = Mock(side_effect=RuntimeError("missing"))
        clock = Mock(side_effect=[0, 121])
        with self.assertRaisesRegex(RuntimeError, "未创建第二个实例"):
            bridge.attach(active, clock=clock)
        active.assert_called_once_with("SldWorks.Application")

    def test_manifest_imports_formats_as_alternate_editors_not_defaults(self):
        info = plistlib.loads((PROJECT / "resources/Info.plist.in").read_bytes())
        imported = {item["UTTypeIdentifier"]: item for item in info["UTImportedTypeDeclarations"]}
        self.assertNotIn("UTExportedTypeDeclarations", info)
        extensions = set()
        for declaration in info["CFBundleDocumentTypes"]:
            self.assertEqual(declaration["LSHandlerRank"], "Alternate")
            self.assertEqual(declaration["CFBundleTypeRole"], "Editor")
            for identifier in declaration["LSItemContentTypes"]:
                item = imported[identifier]
                self.assertIn("public.data", item["UTTypeConformsTo"])
                extensions.update(item["UTTypeTagSpecification"]["public.filename-extension"])
        self.assertEqual(extensions, {"sldprt", "sldasm", "slddrw"})

    def test_packaging_includes_and_verifies_the_bridge(self):
        for script in ("scripts/package_app.sh", "scripts/verify_app.sh"):
            self.assertIn("scripts/swcli/open_document.py", (PROJECT / script).read_text())
        app = (PROJECT / "macos/Bootstrap/Sources/MacSWApp/App/MacSWApp.swift").read_text()
        self.assertIn("open urls: [URL]", app)
        self.assertIn("Self.fileOpener?.open(urls)", app)
        self.assertIn("Self.fileOpener?.start()", app)
        controller = (PROJECT / "macos/Bootstrap/Sources/MacSWApp/Support/FileOpenController.swift").read_text()
        self.assertIn("processIdentifier: host.pid", controller)
        self.assertLess(controller.index("try await runtime.openDocument(url)"),
                        controller.index("processIdentifier: host.pid"))


if __name__ == "__main__":
    unittest.main()
