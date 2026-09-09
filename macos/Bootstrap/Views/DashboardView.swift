import SwiftUI
import AppKit

struct DashboardView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 24) {
            // Header
            HStack(spacing: 16) {
                Image(systemName: "cube.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("SolidWorks 2025 for macOS")
                        .font(.system(size: 18, weight: .bold))
                    Text("由 MacSW 独立 Wine-crossover 引擎驱动")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            // Main Launch Card
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("主程序就绪")
                            .font(.system(size: 14, weight: .semibold))
                        Text(state.sldworksExePath.path)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }

                Button(action: launchApp) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("启动 SolidWorks")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

            // Services Status
            VStack(spacing: 12) {
                HStack {
                    Circle()
                        .fill(state.isLicenseRunning ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text("FlexNet 许可服务 (端口 25734): \(state.isLicenseRunning ? "运行中" : "未检测到服务")")
                        .font(.system(size: 12))
                    Spacer()
                    Button("刷新状态") {
                        state.checkLicenseStatus()
                    }
                    .font(.system(size: 11))
                }

                HStack {
                    Image(systemName: "sparkles")
                        .foregroundColor(.yellow)
                        .font(.system(size: 12))
                    Text("Aero 质感标题栏与 UI 优化守护已内建")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))

            Spacer()

            // Bottom Actions
            HStack {
                Button("浏览虚拟 C 盘") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: state.bottlePath.appendingPathComponent("drive_c").path)
                }
                .font(.system(size: 11))
                Spacer()
                Button("重新配置介质...") {
                    state.isInstalled = false
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func launchApp() {
        WineService.shared.launchSolidWorks(
            exePath: state.sldworksExePath.path,
            winePrefix: state.bottlePath.path
        )
    }
}
