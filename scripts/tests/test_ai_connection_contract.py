"""Offline source contracts for the copy-only agent entry point."""

from pathlib import Path
import re
import unittest

PROJECT = Path(__file__).resolve().parents[2]
SOURCES = PROJECT / "macos/Bootstrap/Sources"


class AIConnectionContractTests(unittest.TestCase):
    def test_copy_action_is_between_solidworks_and_logs_without_dismissing_panel(self):
        view = (SOURCES / "MacSWApp/Features/MenuBar/MenuBarPanelView.swift").read_text()
        self.assertLess(view.index('"启动 SOLIDWORKS"'), view.index('"复制 AI 接入信息"'))
        self.assertLess(view.index('"复制 AI 接入信息"'), view.index('"查看日志"'))
        action = view.split("private func copyAIConnectionInfo()", 1)[1].split("private var summaryText", 1)[0]
        self.assertIn("AIConnectionClipboard.copy(paths: runtime.paths)", action)
        self.assertNotIn("dismissPanel()", action)
        self.assertIn('"已复制"', view)

    def test_copy_feedback_uses_one_shot_common_mode_timer_not_view_task(self):
        view = (SOURCES / "MacSWApp/Features/MenuBar/MenuBarPanelView.swift").read_text()
        action = view.split("private func copyAIConnectionInfo()", 1)[1].split("private var summaryText", 1)[0]
        self.assertIn("copyFeedbackTimer?.invalidate()", action)
        self.assertIn("Timer(timeInterval: 2, repeats: false)", action)
        self.assertIn("MainActor.assumeIsolated", action)
        self.assertIn("copySucceeded = nil", action)
        self.assertIn("copyFeedbackTimer = nil", action)
        self.assertIn("RunLoop.main.add(timer, forMode: .common)", action)
        self.assertLess(action.index("copyFeedbackTimer?.invalidate()"), action.index("let timer = Timer("))
        self.assertNotIn("copyFeedbackID", view)
        self.assertNotIn("Task.sleep", view)

    def test_clipboard_bridge_only_reads_resources_and_copies_plain_text(self):
        bridge = (SOURCES / "MacSWApp/Support/AIConnectionClipboard.swift").read_text()
        self.assertIn("@MainActor", bridge)
        self.assertIn("Bundle.main.bundleURL", bridge)
        self.assertIn("NSPasteboard.general", bridge)
        self.assertIn("pasteboard.setString(information.text, forType: .string)", bridge)
        self.assertLess(bridge.index("throw CopyError.missingResource"), bridge.index("pasteboard.clearContents()"))
        for forbidden in ("WineService", "createDirectory", "Process(", "CommandRunner", "AppPaths.live"):
            self.assertNotIn(forbidden, bridge)

    def test_pure_info_does_not_read_bottle_or_start_processes(self):
        info = (SOURCES / "MacSWCore/Models/AIConnectionInfo.swift").read_text()
        launcher = (PROJECT / "scripts/swcli/sw-cli").read_text()
        endpoint = re.search(r'defaultEndpoint = "([^"]+)"', info).group(1)
        self.assertIn("${SWCLI_ENDPOINT:-" + endpoint + "}", launcher)
        for forbidden in ("AppKit", "FileManager", "Process(", "CommandRunner", "AppPaths.live"):
            self.assertNotIn(forbidden, info)

    def test_advertised_skill_is_checked_against_current_pinned_source(self):
        info = (SOURCES / "MacSWCore/Models/AIConnectionInfo.swift").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        relative = re.search(r'"runtime/PythonNative/([^"]+/skills/swcli)"', info).group(1)
        for document in ("SKILL.md", "references/usage.md"):
            packaged = "${SWCLI_NATIVE_RUNTIME}/" + relative + "/" + document
            self.assertIn('test -s "' + packaged + '"', verify)
            self.assertIn('cmp "${WORKSPACE_ROOT}/Dependencies/SWCLI/src/swcli/skills/swcli/' + document + '"', verify)


if __name__ == "__main__":
    unittest.main()
