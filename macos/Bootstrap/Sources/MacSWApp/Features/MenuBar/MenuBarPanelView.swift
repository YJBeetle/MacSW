import AppKit
import MacSWCore
import SwiftUI

/// 菜单栏面板：顶部强调色状态卡 + 紧凑操作行 + 底部会变化的进程条。
/// 只用系统语义色与原生按钮样式，高亮与材质交给系统（含后续液态玻璃）；不注册任何快捷键。
struct MenuBarPanelView: View {
    @ObservedObject var runtime: RuntimeStore
    @ObservedObject var licenseServer: LicenseServerStore
    @State private var panelVisible = false

    private static let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusCard
            actions
            Divider()
            processSection
        }
        .padding(10)
        .frame(width: 296, alignment: .leading)
        .onAppear { panelVisible = true }
        .onDisappear { panelVisible = false }
        .task { await refresh() }
        .onReceive(Self.tick) { _ in
            // 面板收起后停止轮询，避免后台一直起 ps 子进程。
            guard panelVisible else { return }
            Task { await refresh() }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("MacSW").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Wine \(BuildInfo.wineVersion) · Mono \(BuildInfo.monoVersion)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.72))
            }
            statusLine(solidWorksStatus, active: runtime.isRunning)
            if licenseServer.isInstalled {
                statusLine(flexNetStatus, active: licenseServer.isRunning, detail: licenseServer.addressInput)
            }
            HStack {
                Spacer()
                MenuBarSettingsButton {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.16)))
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(
                LinearGradient(
                    colors: [Color(red: 0.55, green: 0.32, blue: 0.93), Color(red: 0.40, green: 0.20, blue: 0.72)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
        )
        .foregroundStyle(.white)
    }

    private func statusLine(_ title: String, active: Bool, detail: String = "") -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(active ? Color(red: 0.36, green: 0.96, blue: 0.64) : Color.white.opacity(0.45))
                .frame(width: 6, height: 6)
            Text(title).font(.system(size: 11.5, weight: .medium))
            if !detail.isEmpty {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
        }
    }

    private var actions: some View {
        VStack(spacing: 1) {
            if runtime.isRunning {
                MenuBarActionRow(
                    title: "退出 SOLIDWORKS",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    prominent: true
                ) { runtime.requestQuit() }
            } else {
                MenuBarActionRow(
                    title: runtime.state == .starting ? "正在启动…" : "启动 SOLIDWORKS",
                    systemImage: "play.fill",
                    prominent: true
                ) { runtime.launch() }
                .disabled(!runtime.isInstalled || runtime.state == .starting)
            }
            MenuBarActionRow(title: "刷新状态", systemImage: "arrow.clockwise") { Task { await refresh() } }
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

    /// 进程数量会变化，放在最底部，避免上面的操作行位置跳动。
    private var processSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("容器进程")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.tertiary)
            if runtime.processes.isEmpty {
                Text("未检测到运行中的进程")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(runtime.processes, id: \.pid) { process in
                        MenuBarProcessRow(process: process, share: share(of: process))
                    }
                }
                Text("合计 \(formattedTotalMemory) · 已运行 \(uptimeText)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    private func share(of process: WineProcess) -> Double {
        let peak = runtime.processes.map(\.residentKB).max() ?? 1
        guard peak > 0 else { return 0 }
        return min(Double(process.residentKB) / Double(peak), 1)
    }

    private var formattedTotalMemory: String {
        let megabytes = ProcessInventory.totalResidentMB(runtime.processes)
        if megabytes >= 1024 { return String(format: "%.1f GB", Double(megabytes) / 1024) }
        return "\(megabytes) MB"
    }

    private var uptimeText: String {
        guard let primary = runtime.processes.first(where: { $0.name == ProcessInventory.primaryProcess }) else {
            return "—"
        }
        return ProcessInventory.formatElapsed(primary.elapsed)
    }

    private func openLogs() {
        try? FileManager.default.createDirectory(at: runtime.paths.logs, withIntermediateDirectories: true)
        NSWorkspace.shared.open(runtime.paths.logs)
    }

    /// 面板可见时每两秒刷新；只用 ps 与本机端口探测，不启动 Wine。
    private func refresh() async {
        async let running: Void = runtime.refreshNow()
        async let licensing: Void = licenseServer.refreshRunningState()
        _ = await (running, licensing)
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

/// macOS 14+ 走系统的 openSettings，更早版本回退 AppKit 动作。
private struct MenuBarSettingsButton<Label: View>: View {
    @ViewBuilder let label: () -> Label

    var body: some View {
        if #available(macOS 14.0, *) {
            MenuBarSettingsShortcut(label: label)
        } else {
            Button { AppLifecycleBridge.openLegacySettings() } label: { label() }
                .buttonStyle(.plain)
        }
    }
}

@available(macOS 14.0, *)
private struct MenuBarSettingsShortcut<Label: View>: View {
    @Environment(\.openSettings) private var openSettings
    let label: () -> Label

    var body: some View {
        Button {
            openSettings()
            AppLifecycleBridge.bringSettingsToFront()
        } label: { label() }
        .buttonStyle(.plain)
    }
}

private struct MenuBarActionRow: View {
    let title: String
    let systemImage: String
    var prominent = false
    var destructive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 11)).frame(width: 13)
                Text(title).font(.system(size: 12, weight: prominent ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(rowTint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(rowBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var rowTint: Color {
        if destructive { return .red }
        if prominent { return .white }
        return .primary
    }

    private var rowBackground: AnyShapeStyle {
        if prominent {
            return AnyShapeStyle(Color.accentColor.opacity(isHovering ? 1 : 0.86))
        }
        return isHovering
            ? AnyShapeStyle(Color.primary.opacity(0.09))
            : AnyShapeStyle(Color.clear)
    }
}

private struct MenuBarProcessRow: View {
    let process: WineProcess
    let share: Double

    var body: some View {
        HStack(spacing: 7) {
            Text(process.name)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .frame(width: 112, alignment: .leading)
            Text(String(process.pid))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor).frame(width: max(2, geometry.size.width * share))
                }
            }
            .frame(height: 4)
            Text(memoryText)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private var memoryText: String {
        let megabytes = process.residentMB
        if megabytes >= 1024 { return String(format: "%.1f GB", Double(megabytes) / 1024) }
        return "\(megabytes) MB"
    }
}
