import AppKit
import MacSWCore
import SwiftUI

/// 菜单栏面板：朴素的标题与状态行 + 菜单式操作行 + 底部会变化的进程条。
/// 整块面板保持系统语义色，只有鼠标经过的行才用强调色底与白字，与系统菜单一致；不注册任何快捷键。
struct MenuBarPanelView: View {
    @ObservedObject var runtime: RuntimeStore
    @ObservedObject var licenseServer: LicenseServerStore
    @State private var isRefreshing = false
    @State private var panelWindow: NSWindow?

    private static let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            chips
            if let reason = failureReason {
                // "运行异常"不能只有一个词，原因要看得见，不然只能去猜或翻日志。
                Text(reason)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Divider()
            actions
            Divider()
            processSection
        }
        .padding(10)
        .frame(width: 296, alignment: .leading)
        .background(MenuBarWindowReader { panelWindow = $0 })
        .task { await refresh() }
        .onReceive(Self.tick) { _ in
            // 面板收起即停止轮询：直接看承载窗口的可见性，
            // MenuBarExtra 的窗口关闭不保证会触发 onDisappear。
            guard panelWindow?.isVisible == true, !isRefreshing else { return }
            Task { await refresh() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("MacSW").font(.system(size: 13, weight: .semibold))
            Text("Wine \(BuildInfo.wineVersion) · Mono \(BuildInfo.monoVersion)")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
            MenuBarSettingsButton {
                Image(systemName: "gearshape").font(.system(size: 11.5))
            }
            .simultaneousGesture(TapGesture().onEnded { dismissPanel() })
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            MenuBarStatusChip(title: solidWorksStatus, active: runtime.isRunning)
            if licenseServer.isInstalled {
                MenuBarStatusChip(title: flexNetStatus, active: licenseServer.isRunning, help: licenseServer.addressInput)
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
                    large: true
                ) { runtime.requestQuit() }
            } else {
                MenuBarActionRow(
                    title: runtime.state == .starting ? "正在启动…" : "启动 SOLIDWORKS",
                    systemImage: "play.fill",
                    large: true
                ) { runtime.launch() }
                .disabled(!runtime.isInstalled || runtime.state == .starting)
            }
            MenuBarActionRow(title: "查看日志", systemImage: "doc.text") {
                LogReveal.open(runtime.paths.logs)
                dismissPanel()
            }
            if !runtime.processes.isEmpty {
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
                    ForEach(runtime.processes.prefix(Self.visibleProcessLimit), id: \.pid) { process in
                        MenuBarProcessRow(process: process, share: share(of: process))
                    }
                }
                Text(summaryText)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
    }

    private static let visibleProcessLimit = 8

    private var summaryText: String {
        let hidden = runtime.processes.count - Self.visibleProcessLimit
        let suffix = hidden > 0 ? "（另有 \(hidden) 个未列出）" : ""
        return "合计 \(ProcessInventory.formatMegabytes(ProcessInventory.totalResidentMB(runtime.processes))) · 已运行 \(uptimeText)\(suffix)"
    }

    private func share(of process: WineProcess) -> Double {
        let peak = runtime.processes.map(\.residentKB).max() ?? 1
        guard peak > 0 else { return 0 }
        return min(Double(process.residentKB) / Double(peak), 1)
    }

    private var uptimeText: String {
        guard let primary = runtime.processes.first(where: { $0.name == ProcessInventory.primaryProcess }) else {
            return "—"
        }
        return ProcessInventory.formatElapsed(primary.elapsed)
    }

    /// 面板由系统托管，先按 Escape 的语义让它自己收起；仍可见时再隐藏。
    private func dismissPanel() {
        guard let panel = panelWindow else { return }
        panel.cancelOperation(nil)
        DispatchQueue.main.async {
            if panel.isVisible { panel.orderOut(nil) }
        }
    }

    /// 面板可见时每两秒刷新；只用 ps 与本机端口探测，不启动 Wine。
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        async let running: Void = runtime.refreshNow()
        async let licensing: Void = licenseServer.refreshRunningState()
        _ = await (running, licensing)
    }

    /// 面板上的"异常"要能把原因一起说出来。
    private var failureReason: String? {
        if case .failed(let reason) = runtime.state { return reason }
        if case .failed(let reason) = licenseServer.state { return reason }
        return nil
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

/// 取到承载面板的窗口，用于操作完成后收起它。
private struct MenuBarWindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(view.window) }
    }
}

private struct MenuBarStatusChip: View {
    let title: String
    let active: Bool
    var help: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Color(red: 0.24, green: 0.86, blue: 0.52) : Color.secondary.opacity(0.55))
                .frame(width: 7, height: 7)
            Text(title).font(.system(size: 11.5, weight: .medium)).fixedSize()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.quaternary))
        .help(help.isEmpty ? title : help)
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
    var destructive = false
    var large = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: large ? 13 : 11))
                    .frame(width: large ? 16 : 13)
                Text(title).font(.system(size: large ? 13 : 12, weight: large ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(rowTint)
            .padding(.horizontal, large ? 10 : 8)
            .padding(.vertical, large ? 9 : 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(rowBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    // 选中态用系统语义色，窗口非激活时会自动降级为灰色选中态。
    private var rowTint: Color {
        if isHovering { return Color(nsColor: .selectedTextColor) }
        return destructive ? .red : .primary
    }

    private var rowBackground: AnyShapeStyle {
        isHovering
            ? AnyShapeStyle(Color(nsColor: .selectedTextBackgroundColor))
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
