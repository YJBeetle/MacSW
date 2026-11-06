"""Offline source contracts for the copy-only agent entry point."""

from pathlib import Path
import re
import unittest

PROJECT = Path(__file__).resolve().parents[2]
SOURCES = PROJECT / "macos/Bootstrap/Sources"


class AIConnectionContractTests(unittest.TestCase):
    def test_menu_status_polls_only_while_visible_and_refreshes_on_reopening(self):
        view = (SOURCES / "MacSWApp/Features/MenuBar/MenuBarPanelView.swift").read_text()
        self.assertIn("Timer.publish(every: 2", view)
        tick = view.split(".onReceive(Self.tick)", 1)[1].split("private var header", 1)[0]
        self.assertIn("panelWindow?.isVisible == true", tick)
        self.assertLess(tick.index("panelWindow?.isVisible == true"), tick.index("await refresh()"))
        self.assertIn("NSWindow.didBecomeKeyNotification", view)
        self.assertIn("window === panelWindow, window.isVisible", view)
        self.assertIn("swcliDaemon.refresh()", view)

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
        launcher = (PROJECT / "scripts/swcli/swcli").read_text()
        endpoint = re.search(r'defaultEndpoint = "([^"]+)"', info).group(1)
        self.assertIn("${SWCLI_ENDPOINT:-" + endpoint + "}", launcher)
        for forbidden in ("AppKit", "FileManager", "Process(", "CommandRunner", "AppPaths.live"):
            self.assertNotIn(forbidden, info)

    def test_current_cli_resource_layout_has_no_legacy_entry(self):
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        self.assertTrue((PROJECT / "scripts/swcli/swcli").is_file())
        self.assertFalse((PROJECT / "scripts/swcli/sw-cli").exists())
        self.assertIn('"${RESOURCES_DIR}/SWCLI/bin/swcli"', package)
        self.assertIn('ln -s ../Resources/SWCLI/bin/swcli "${MAC_OS_DIR}/swcli"', package)
        self.assertNotIn('"${RESOURCES_DIR}/swcli"', package)
        for path in ("MacOS/sw-cli", "Resources/sw-cli"):
            self.assertIn('test ! -e "${CONTENTS_DIR}/' + path + '"', verify)
            self.assertIn('test ! -L "${CONTENTS_DIR}/' + path + '"', verify)

    def test_advertised_skill_and_pinned_guide_are_packaged_and_verified(self):
        info = (SOURCES / "MacSWCore/Models/AIConnectionInfo.swift").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        verify = (PROJECT / "scripts/verify_app.sh").read_text()
        self.assertIn('"skills/macsw"', info)
        self.assertIn('"${WORKSPACE_ROOT}/resources/skills/macsw" "${RESOURCES_DIR}/SWCLI/skills/"', package)
        self.assertIn('"${SWCLI_DIR}/skills/macsw"', verify)
        for document in ("SKILL.md", "references/solidworks-api.md"):
            self.assertTrue((PROJECT / "resources/skills/macsw" / document).is_file())
            self.assertIn('cmp "${WORKSPACE_ROOT}/resources/skills/macsw/' + document + '"', verify)
        self.assertIn('"${SWCLI_NATIVE_SITE_PACKAGES}/swcli/skills/swcli/references/usage.md"', package)
        self.assertIn('"${MACSW_SKILL}/references/usage.md"', verify)


if __name__ == "__main__":
    unittest.main()
