import AppKit
import MacSWCore
import SwiftUI

/// 菜单栏面板：状态胶囊 + 容器进程清单 + 操作列表，不使用任何系统快捷键。
struct MenuBarPanelView: View {
    @ObservedObject var runtime: RuntimeStore
    @ObservedObject var licenseServer: LicenseServerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            chips
            Divider().overlay(MenuBarPalette.divider)
            processCard
            actions
            Divider().overlay(MenuBarPalette.divider)
            footer
        }
        .padding(12)
        .frame(width: 306, alignment: .leading)
        .task { await refresh() }
    }

    private var header: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.71, green: 0.47, blue: 1.0), Color(red: 0.48, green: 0.25, blue: 0.83)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "cube.fill").font(.system(size: 15)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 1) {
                Text("MacSW").font(.system(size: 13.5, weight: .semibold))
                Text("Wine \(BuildInfo.wineVersion) · Mono \(BuildInfo.monoVersion)")
                    .font(.system(size: 11)).foregroundStyle(MenuBarPalette.tertiary)
            }
            Spacer()
            Button { openSettingsWindow() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MenuBarPalette.secondary)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(MenuBarPalette.card))
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.bottom, 11)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            MenuBarStatusChip(title: solidWorksStatus, active: runtime.isRunning)
            if licenseServer.isInstalled {
                MenuBarStatusChip(title: flexNetStatus, active: licenseServer.isRunning, help: licenseServer.addressInput)
            }
        }
        .padding(.bottom, 11)
    }

    private var processCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("容器进程")
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(MenuBarPalette.tertiary)
                .padding(.bottom, 7)
            Group {
                if runtime.processes.isEmpty {
                    Text("未检测到运行中的进程")
                        .font(.system(size: 12))
                        .foregroundStyle(MenuBarPalette.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(runtime.processes, id: \.pid) { process in
                            MenuBarProcessRow(process: process, share: share(of: process))
                        }
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(MenuBarPalette.card))
        }
        .padding(.bottom, 11)
    }

    private var actions: some View {
        VStack(spacing: 5) {
            if runtime.isRunning {
                MenuBarActionRow(
                    title: "退出 SOLIDWORKS",
                    systemImage: "rectangle.portrait.and.arrow.right"
                ) { runtime.requestQuit() }
            } else {
                Button { runtime.launch() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "play.fill").font(.system(size: 11))
                        Text(runtime.state == .starting ? "正在启动…" : "启动 SOLIDWORKS")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.69, green: 0.47, blue: 0.97), Color(red: 0.55, green: 0.30, blue: 0.88)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(!runtime.isInstalled || runtime.state == .starting)
            }
            MenuBarActionRow(title: "刷新状态", systemImage: "arrow.clockwise") { Task { await refresh() } }
        }
        .padding(.bottom, 11)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            MenuBarActionRow(title: "查看日志", systemImage: "doc.text") { openLogs() }
            if runtime.isRunning {
                MenuBarActionRow(title: "强制停止全部进程", systemImage: "stop.fill", destructive: true) {
                    runtime.forceStop()
                }
            }
            MenuBarActionRow(title: "退出 MacSW", systemImage: "power", destructive: true) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func share(of process: WineProcess) -> Double {
        let peak = runtime.processes.map(\.residentKB).max() ?? 1
        guard peak > 0 else { return 0 }
        return min(Double(process.residentKB) / Double(peak), 1)
    }

    private func openLogs() {
        try? FileManager.default.createDirectory(at: runtime.paths.logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(runtime.paths.logs)
    }

    private func openSettingsWindow() {
        AppLifecycleBridge.openLegacySettings()
    }

    private func refresh() async {
        runtime.refresh()
        await licenseServer.refresh()
    }

    private var solidWorksStatus: String {
        switch runtime.state {
        case .unknown: return "SOLIDWORKS 未检测"
        case .unavailable: return "SOLIDWORKS 未安装"
        case .stopped: return "SOLIDWORKS 已停止"
        case .starting: return "SOLIDWORKS 启动中"
        case .running: return "SOLIDWORKS 运行中"
        case .stopping: return "SOLIDWORKS 退出中"
        case .failed: return "SOLIDWORKS 异常"
        }
    }

    private var flexNetStatus: String {
        switch licenseServer.state {
        case .running: return "FlexNet 运行中"
        case .starting: return "FlexNet 启动中"
        case .stopping: return "FlexNet 停止中"
        case .failed: return "FlexNet 异常"
        case .notInstalled: return "FlexNet 未安装"
        case .stopped: return "FlexNet 已停止"
        }
    }
}

enum MenuBarPalette {
    static let card = Color.white.opacity(0.055)
    static let secondary = Color.secondary
    static let tertiary = Color.secondary.opacity(0.75)
    static let divider = Color.white.opacity(0.08)
    static let bar = Color.white.opacity(0.09)
    static let barFill = LinearGradient(
        colors: [Color(red: 0.56, green: 0.36, blue: 0.94), Color(red: 0.78, green: 0.61, blue: 1.0)],
        startPoint: .leading, endPoint: .trailing
    )
}

private struct MenuBarStatusChip: View {
    let title: String
    let active: Bool
    var help: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Color(red: 0.24, green: 0.86, blue: 0.52) : Color.secondary.opacity(0.6))
                .frame(width: 7, height: 7)
            Text(title).font(.system(size: 11.5, weight: .medium)).fixedSize()
        }
        .foregroundStyle(MenuBarPalette.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(MenuBarPalette.card))
        .help(help.isEmpty ? title : help)
    }
}

private struct MenuBarProcessRow: View {
    let process: WineProcess
    let share: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(process.name)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .frame(width: 118, alignment: .leading)
            Text(String(process.pid))
                .font(.system(size: 10.5))
                .foregroundStyle(MenuBarPalette.tertiary)
                .frame(width: 38, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(MenuBarPalette.bar)
                    Capsule().fill(MenuBarPalette.barFill)
                        .frame(width: max(2, geometry.size.width * share))
                }
            }
            .frame(height: 5)
            Text(memoryText)
                .font(.system(size: 11))
                .foregroundStyle(MenuBarPalette.secondary)
                .frame(width: 54, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    private var memoryText: String {
        let megabytes = process.residentMB
        if megabytes >= 1024 {
            return String(format: "%.1f GB", Double(megabytes) / 1024)
        }
        return "\(megabytes) MB"
    }
}

private struct MenuBarActionRow: View {
    let title: String
    let systemImage: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage).font(.system(size: 12)).frame(width: 14)
                Text(title).font(.system(size: 12.5))
                Spacer()
            }
            .foregroundStyle(destructive ? Color(red: 1.0, green: 0.54, blue: 0.50) : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
