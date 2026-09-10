import SwiftUI
import AppKit

struct DashboardView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 14) {
                Image(systemName: "cube.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 42, height: 42)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SolidWorks for macOS")
                        .font(.system(size: 17, weight: .bold))
                    Text("由 WineHQ 强力驱动")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Segmented Picker
            Picker("", selection: $state.selectedTab) {
                Text("🚀 运行启动").tag(0)
                Text("🔑 激活与维护").tag(1)
            }
            .pickerStyle(.segmented)

            Divider()

            // Tab Content
            ScrollView {
                VStack(spacing: 16) {
                    if state.selectedTab == 0 {
                        launchTab
                    } else {
                        maintenanceTab
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            // Status Bar & Bottom Actions
            HStack {
                if !state.statusMessage.isEmpty {
                    Text(state.statusMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    Text("系统就绪")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("浏览虚拟 C 盘") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: state.bottlePath.appendingPathComponent("drive_c").path)
                }
                .font(.system(size: 11))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tab 0: 运行启动
    private var launchTab: some View {
        VStack(spacing: 14) {
            // Main Launch Card
            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("主程序就绪")
                            .font(.system(size: 13, weight: .semibold))
                        Text(state.sldworksExePath.path)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }

                HStack(spacing: 10) {
                    Button(action: launchApp) {
                        HStack(spacing: 8) {
                            if state.isSolidWorksRunning {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 14, height: 14)
                                Text("SolidWorks 运行中...")
                                    .font(.system(size: 14, weight: .bold))
                            } else {
                                Image(systemName: "play.fill")
                                Text("启动 SolidWorks")
                                    .font(.system(size: 14, weight: .bold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(state.isSolidWorksRunning ? Color.gray : Color.purple)
                    .disabled(state.isSolidWorksRunning)

                    if state.isSolidWorksRunning {
                        Button(action: {
                            state.terminateSolidWorks()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle.fill")
                                Text("终止")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .frame(width: 80, height: 38)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.red)
                    }
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

            // Status Card
            VStack(spacing: 8) {
                HStack {
                    Circle()
                        .fill(state.isLicenseRunning ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text("FlexNet 许可服务 (端口 25734): \(state.isLicenseRunning ? "运行中" : "未运行")")
                        .font(.system(size: 11))
                    Spacer()
                    if !state.isLicenseRunning {
                        Button("启动服务") {
                            state.startLicenseServer()
                        }
                        .controlSize(.small)
                        .font(.system(size: 10))
                    } else {
                        Button("刷新") {
                            state.checkLicenseStatus()
                        }
                        .controlSize(.small)
                        .font(.system(size: 10))
                    }
                }

                Divider()

                HStack {
                    Circle()
                        .fill(state.isPatchApplied ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text("SolidWorks 授权补丁: \(state.isPatchApplied ? "已应用 (SSQ 破解补丁已注入)" : "未应用 (未检测到补丁)")")
                        .font(.system(size: 11))
                    Spacer()
                    if !state.isPatchApplied {
                        Button("应用补丁") {
                            state.applyComponentPatch()
                        }
                        .controlSize(.small)
                        .font(.system(size: 10))
                    }
                }

                Divider()

                HStack {
                    Circle()
                        .fill(state.isWpfThemeInjected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text("WPF 原版主题运行库: \(state.isWpfThemeInjected ? "已就绪 (免虚拟机防闪退)" : "未补齐 (缺少主题库)")")
                        .font(.system(size: 11))
                    Spacer()
                    if !state.isWpfThemeInjected {
                        Button("抽取注入") {
                            state.extractAndInjectWpfThemes()
                        }
                        .controlSize(.small)
                        .font(.system(size: 10))
                    }
                }

                Divider()

                HStack {
                    Circle()
                        .fill(state.isVcRedistInjected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text("VC++ 2015-2022 运行库: \(state.isVcRedistInjected ? "已就绪 (mfc140u 等官方 64位 DLL)" : "未补齐 (缺少 mfc140u 等)")")
                        .font(.system(size: 11))
                    Spacer()
                    if !state.isVcRedistInjected {
                        Button("抽取注入") {
                            state.extractAndInjectVcRedist()
                        }
                        .controlSize(.small)
                        .font(.system(size: 10))
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15), lineWidth: 1))

            // Quick Tools Card
            VStack(alignment: .leading, spacing: 10) {
                Text("高级 Wine 工具")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button(action: { state.openRegedit() }) {
                        Label("注册表 (regedit)", systemImage: "pencil.and.outline")
                            .font(.system(size: 11))
                    }
                    Button(action: { state.openWinecfg() }) {
                        Label("Wine 配置 (winecfg)", systemImage: "gearshape")
                            .font(.system(size: 11))
                    }
                    Spacer()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
        }
    }

    // MARK: - Tab 1: 激活与维护
    private var maintenanceTab: some View {
        VStack(spacing: 14) {
            // License Server Config
            VStack(alignment: .leading, spacing: 10) {
                Text("许可服务器配置")
                    .font(.system(size: 12, weight: .bold))

                HStack(spacing: 8) {
                    Text("地址:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextField("25734@localhost", text: $state.licenseServerAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))

                    Button("写入注册表") {
                        state.saveLicenseServerAddress(address: state.licenseServerAddress)
                    }
                    .controlSize(.small)
                    .font(.system(size: 11))

                    Button("测试连通") {
                        state.testLicenseConnection()
                    }
                    .controlSize(.small)
                    .font(.system(size: 11))
                }

                if !state.licenseTestResult.isEmpty {
                    Text(state.licenseTestResult)
                        .font(.system(size: 10))
                        .foregroundColor(.primary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            // Service Controls
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle()
                        .fill(state.isLicenseRunning ? Color.green : Color.red)
                        .frame(width: 9, height: 9)
                    Text("服务状态: \(state.isLicenseRunning ? "已运行 (监听端口 25734)" : "已停止")")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }

                HStack(spacing: 10) {
                    Button(action: { state.startLicenseServer() }) {
                        Label("启动服务", systemImage: "play.circle")
                            .font(.system(size: 11))
                    }
                    .disabled(state.isLicenseRunning)

                    Button(action: { state.restartLicenseServer() }) {
                        Label("重启服务", systemImage: "arrow.clockwise")
                            .font(.system(size: 11))
                    }

                    Button(action: { state.stopLicenseServer() }) {
                        Label("停止服务", systemImage: "stop.circle")
                            .font(.system(size: 11))
                    }
                    .disabled(!state.isLicenseRunning)

                    Button(action: { state.openFlexnetLog() }) {
                        Label("查看日志", systemImage: "doc.text")
                            .font(.system(size: 11))
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15), lineWidth: 1))

            // Component Patch Box
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "wand.and.stars")
                        .foregroundColor(.purple)
                    Text("运行环境与组件补丁助手")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                }

                Text("若提示运行库缺失或配置异常，可同步应用组件补丁。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                HStack(spacing: 10) {
                    Button(action: { state.importNetworkSerials() }) {
                        Label("预置网络序列号", systemImage: "key.fill")
                            .font(.system(size: 11))
                    }

                    Button(action: { state.applyComponentPatch() }) {
                        Label("应用组件补丁", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                }

                if !state.patchStatusMessage.isEmpty {
                    Text(state.patchStatusMessage)
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.08)))

            // Reinstall & Setup Wizard Action Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundColor(.blue)
                    Text("重新安装或重置环境")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                }

                Text("如需选择新安装镜像、重新安装 SolidWorks 或完整清理并重新初始化 Wine 独立容器，请打开配置向导。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                HStack {
                    Button(action: {
                        state.isInstalled = false
                    }) {
                        Label("打开部署与配置向导...", systemImage: "sparkles")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                    Text("快捷键: ⇧⌘R")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
        }
    }

    private func launchApp() {
        if !state.isVcRedistInjected {
            state.extractAndInjectVcRedist { _ in
                DispatchQueue.main.async {
                    self.state.isSolidWorksRunning = true
                    WineService.shared.launchSolidWorks(
                        exePath: self.state.sldworksExePath.path,
                        winePrefix: self.state.bottlePath.path
                    )
                }
            }
            return
        }
        state.isSolidWorksRunning = true
        WineService.shared.launchSolidWorks(
            exePath: state.sldworksExePath.path,
            winePrefix: state.bottlePath.path
        )
    }
}
