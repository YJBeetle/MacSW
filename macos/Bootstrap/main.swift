import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        let contentView = MainView(state: appState)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 520, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "MacSW"
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setupMenuBar() {
        let mainMenu = NSMenu()

        // 1. App 菜单
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "MacSW")

        let aboutItem = NSMenuItem(title: "关于 MacSW", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())

        let rerunItem = NSMenuItem(title: "重新执行设置向导", action: #selector(rerunSetupWizard), keyEquivalent: "r")
        rerunItem.keyEquivalentModifierMask = [.command, .shift]
        rerunItem.target = self
        appMenu.addItem(rerunItem)

        let browseCItem = NSMenuItem(title: "浏览虚拟 C 盘", action: #selector(browseDriveC), keyEquivalent: "o")
        browseCItem.keyEquivalentModifierMask = [.command]
        browseCItem.target = self
        appMenu.addItem(browseCItem)

        appMenu.addItem(NSMenuItem.separator())

        let hideItem = NSMenuItem(title: "隐藏 MacSW", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        let showAllItem = NSMenuItem(title: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")

        appMenu.addItem(hideItem)
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(showAllItem)
        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 MacSW", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 2. 工具菜单
        let toolsMenuItem = NSMenuItem()
        let toolsMenu = NSMenu(title: "工具")

        let launchSwItem = NSMenuItem(title: "启动 SolidWorks", action: #selector(launchSolidWorksAction), keyEquivalent: "\r")
        launchSwItem.keyEquivalentModifierMask = [.command]
        launchSwItem.target = self
        toolsMenu.addItem(launchSwItem)

        let termSwItem = NSMenuItem(title: "终止 SolidWorks", action: #selector(terminateSolidWorksAction), keyEquivalent: ".")
        termSwItem.keyEquivalentModifierMask = [.command]
        termSwItem.target = self
        toolsMenu.addItem(termSwItem)

        toolsMenu.addItem(NSMenuItem.separator())
        let setupExeItem = NSMenuItem(title: "启动官方安装程序 (setup.exe)", action: #selector(launchSetupAction), keyEquivalent: "")
        setupExeItem.target = self
        toolsMenu.addItem(setupExeItem)

        toolsMenu.addItem(NSMenuItem.separator())

        let restartLicItem = NSMenuItem(title: "重启 FlexNet 许可服务", action: #selector(restartLicenseAction), keyEquivalent: "")
        restartLicItem.target = self
        toolsMenu.addItem(restartLicItem)

        let applyPatchItem = NSMenuItem(title: "应用组件补丁", action: #selector(applyPatchAction), keyEquivalent: "")
        applyPatchItem.target = self
        toolsMenu.addItem(applyPatchItem)

        toolsMenu.addItem(NSMenuItem.separator())

        let regeditItem = NSMenuItem(title: "注册表编辑器 (regedit)", action: #selector(openRegeditAction), keyEquivalent: "")
        regeditItem.target = self
        toolsMenu.addItem(regeditItem)

        let winecfgItem = NSMenuItem(title: "Wine 配置 (winecfg)", action: #selector(openWinecfgAction), keyEquivalent: "")
        winecfgItem.target = self
        toolsMenu.addItem(winecfgItem)

        toolsMenuItem.submenu = toolsMenu
        mainMenu.addItem(toolsMenuItem)

        // 3. 窗口菜单
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc func rerunSetupWizard() {
        appState.isInstalled = false
    }

    @objc func browseDriveC() {
        let driveC = appState.bottlePath.appendingPathComponent("drive_c").path
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: driveC)
    }

    @objc func launchSolidWorksAction() {
        guard !appState.isSolidWorksRunning else { return }
        appState.isSolidWorksRunning = true
        WineService.shared.launchSolidWorks(
            exePath: appState.sldworksExePath.path,
            winePrefix: appState.bottlePath.path
        )
    }

    @objc func terminateSolidWorksAction() {
        appState.terminateSolidWorks()
    }

    @objc func launchSetupAction() {
        appState.launchSetupExe()
    }

    @objc func restartLicenseAction() {
        appState.restartLicenseServer()
    }

    @objc func applyPatchAction() {
        appState.applyComponentPatch()
    }

    @objc func openRegeditAction() {
        appState.openRegedit()
    }

    @objc func openWinecfgAction() {
        appState.openWinecfg()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
