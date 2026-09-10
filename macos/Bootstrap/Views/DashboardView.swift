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
                    Text("由 MacSW 独立 Wine-crossover 引擎驱动")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Segmented Picker
            Picker("", selection: $state.selectedTab) {
                Text("🚀 运行启动").tag(0)
                Text("🔑 激活与许可").tag(1)
                Text("🛠️ 重新安装").tag(2)
            }
            .pickerStyle(.segmented)

            Divider()

            // Tab Content
            ScrollView {
                VStack(spacing: 16) {
                    if state.selectedTab == 0 {
                        launchTab
                    } else if state.selectedTab == 1 {
                        licenseTab
                    } else {
                        installTab
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
            VStack(spacing: 10) {
                HStack {
                    Circle()
                        .fill(state.isLicenseRunning ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
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

    // MARK: - Tab 1: 激活与许可
    private var licenseTab: some View {
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
        }
    }

    // MARK: - Tab 2: 重新安装与维护
    private var installTab: some View {
        VStack(spacing: 14) {
            // Setup Launcher Card
            VStack(alignment: .leading, spacing: 10) {
                Text("SolidWorks 安装管理程序 (setup.exe)")
                    .font(.system(size: 13, weight: .bold))

                Text("点击下方按钮将通过 Wine 唤起官方安装程序，可选择【修改单机安装】或【全新安装】。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button(action: { state.launchSetupExe() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                            Text("启动安装程序 (setup.exe)")
                                .font(.system(size: 13, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("预置序列号") {
                        state.importNetworkSerials()
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

            // Installation Guidance Card
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    Text("重新安装避坑指引 (非常重要)")
                        .font(.system(size: 12, weight: .bold))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("1. 安装类型: 请务必勾选【在此计算机上安装】(单机/网络客户端模式)。")
                    Text("2. 序列号检查: 提示“在激活数据库中找不到序列号”时，直接点【确定/忽略】继续。")
                    Text("3. 许可服务器: 当要求输入端口与服务器时，填入: 25734@localhost")
                        .foregroundColor(.accentColor)
                        .bold()
                    Text("4. 订购到期提醒: 提示“无法确定当前订购服务到期日期”时，点【否】，提示稍后激活点【是】。")
                    Text("5. 完成安装后: 返回本软件，在【🔑 激活与许可】页面点击【一键应用组件补丁】。")
                }
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.3), lineWidth: 1))
        }
    }

    private func launchApp() {
        state.isSolidWorksRunning = true
        WineService.shared.launchSolidWorks(
            exePath: state.sldworksExePath.path,
            winePrefix: state.bottlePath.path
        )
    }
}
