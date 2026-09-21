import AppKit
import MacSWCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var runtime: RuntimeStore
    @ObservedObject var licenseServer: LicenseServerStore
    @AppStorage(AppPreferences.autoLaunchSolidWorksKey) private var autoLaunchSolidWorks = AppPreferences.autoLaunchSolidWorksDefault
    @FocusState private var addressFocused: Bool
    @State private var confirmUninstall = false
    @State private var maintainsVisibility = false
    /// nil 表示还没手工选过，此时按容器里的真实状态推导。
    @State private var chosenLicenseMode: BootstrapLicenseMode?

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("通用", systemImage: "gearshape") }
            maintenanceSettings
                .tabItem { Label("维护", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
        .alert("卸载托管 FlexNet？", isPresented: $confirmUninstall) {
            Button("取消", role: .cancel) { }
            Button("停止并卸载", role: .destructive) { licenseServer.uninstall() }
        } message: {
            Text("只会删除 C:\\opt\\FlexNet，并从服务器列表移除对应的 localhost 地址；其他地址会保留。")
        }
    }

    private var generalSettings: some View {
        Form {
            Section("启动") {
                Toggle("启动 MacSW 时自动启动 SOLIDWORKS", isOn: $autoLaunchSolidWorks)
                Text("打开时自动启动前，若托管 FlexNet 的地址指向 localhost 会先尝试拉起它；起不来只提示，不阻止 SOLIDWORKS 启动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            licenseSection
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var licenseSection: some View {
        Section("许可服务器") {
            HStack(spacing: 8) {
                Picker("许可服务器", selection: licenseMode) {
                    ForEach(BootstrapLicenseMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                // 写入注册表期间整块锁住，顺便转个菊花表示"在做事"。
                if licenseServer.isOperating {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .disabled(licenseServer.isOperating)
            switch licenseMode.wrappedValue {
            case .unconfigured:
                Text(BootstrapLicenseMode.unconfigured.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .remoteServer:
                addressEditor
            case .managedFlexNet:
                managedFlexNetEditor
            }
        }
    }

    private var addressEditor: some View {
        Group {
            HStack(spacing: 8) {
                Text("服务器地址")
                TextField("25734@license.example.com", text: $licenseServer.addressInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .onSubmit { commitAddressIfNeeded() }
                    .onChange(of: addressFocused) { focused in
                        if !focused { commitAddressIfNeeded() }
                    }
            }
            .disabled(licenseServer.isOperating)
            Text("port@host，也接受 host:port 与 [IPv6]:port；多个地址用分号分隔，写入后下次启动 SOLIDWORKS 生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if licenseServer.isInstalled {
                Text("容器里还装着托管 FlexNet；一旦启动它，这份列表会被覆盖成那一条地址。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !licenseServer.addressNotice.isEmpty {
                Text(licenseServer.addressNotice)
                    .font(.caption)
                    .foregroundStyle(licenseServer.addressHasError ? .red : .secondary)
            }
        }
    }

    private var managedFlexNetEditor: some View {
        Group {
            Text(BootstrapLicenseMode.managedFlexNet.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("运行状态") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(flexNetStateColor)
                        .frame(width: 7, height: 7)
                    Text(flexNetStateText)
                }
            }
            HStack {
                if licenseServer.isInstalled {
                    Button("启动") { licenseServer.start() }
                        .disabled(licenseServer.isOperating || licenseServer.isRunning)
                    Button("停止") { licenseServer.stop() }
                        .disabled(licenseServer.isOperating || !licenseServer.isRunning)
                    Button("卸载…", role: .destructive) { confirmUninstall = true }
                        .disabled(licenseServer.isOperating)
                } else {
                    Button("安装目录或压缩包…") {
                        if let url = OpenPanelService.chooseFlexNetPackage() { licenseServer.install(from: url) }
                    }
                    .disabled(licenseServer.isOperating)
                }
            }
        }
    }

    /// 地址只有真的改过才再写一次，避免每次失焦都起一个 reg 进程。
    private func commitAddressIfNeeded() {
        guard licenseServer.appliedAddress != licenseServer.addressInput else { return }
        licenseServer.apply(mode: .remoteServer)
    }

    private var maintenanceSettings: some View {
        Form {
            Section("Wine 工具") {
                HStack(spacing: 10) {
                    wineToolButton("注册表编辑器", name: "regedit")
                    wineToolButton("Wine 配置", name: "winecfg")
                    Button("浏览虚拟 C 盘") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: runtime.paths.bottle.appendingPathComponent("drive_c").path)
                    }
                }
            }
            Section("容器进程") {
                ProcessTable(processes: runtime.processes)
                HStack {
                    Text("合计 \(ProcessInventory.totalResidentMB(runtime.processes)) MB · \(runtime.processes.count) 个进程")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("容器操作") {
                Button("重启容器") { runtime.restartContainer() }
                Button("强制终止全部进程", role: .destructive) { runtime.forceStop() }
                Text("重启容器会结束 wineserver；若 SOLIDWORKS 正在运行会重新拉起。强制终止只杀进程，不结束 wineserver。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !runtime.statusMessage.isEmpty {
                    Text(runtime.statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("安装") {
                Button("安装或重新安装 SOLIDWORKS…") {
                    AppShell.shared.showBootstrapWindow()
                }
                Text("打开独立的 Bootstrap 窗口；全新安装选项只在现有容器存在时显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { maintainsVisibility = true }
        .onDisappear { maintainsVisibility = false }
        .task(id: maintainsVisibility) {
            guard maintainsVisibility else { return }
            while !Task.isCancelled {
                // 只在设置窗口真的在前台时跑 ps，切到别的 App 就停。
                if NSApp.isActive { await runtime.refreshNow() }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Wine 工具窗口不是瞬间出现：点下去之后按钮变灰并转菊花，直到进程真的起来。
    private func wineToolButton(_ title: String, name: String) -> some View {
        HStack(spacing: 6) {
            Button(title) { runtime.openWineTool(name) }
                .disabled(runtime.pendingWineTool != nil)
            if runtime.pendingWineTool == name {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    /// 单选未手工选过时，按容器里的真实配置推导当前模式。
    private var licenseMode: Binding<BootstrapLicenseMode> {
        Binding {
            if let chosenLicenseMode { return chosenLicenseMode }
            if licenseServer.isInstalled { return .managedFlexNet }
            return licenseServer.addressInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .unconfigured : .remoteServer
        } set: { mode in
            chosenLicenseMode = mode
            // 离开"托管"就等于不再用它，正在跑的服务器先停掉，别留个后台进程。
            if mode != .managedFlexNet, licenseServer.isRunning { licenseServer.stop() }
            licenseServer.apply(mode: mode)
        }
    }

    private var flexNetStateText: String {
        switch licenseServer.state {
        case .notInstalled:
            return "未安装"
        case .stopped:
            return "已停止"
        case .starting:
            return "正在启动…"
        case let .running(port):
            return "运行中 · 端口 \(port)"
        case .stopping:
            return "正在停止…"
        case .failed:
            return "运行异常"
        }
    }

    private var flexNetStateColor: Color {
        switch licenseServer.state {
        case .running:
            return .green
        case .starting, .stopping:
            return .orange
        case .failed:
            return .red
        case .notInstalled, .stopped:
            return .secondary
        }
    }
}

/// 活动监视器同款控件：可点表头排序、隔行底色、固定高度内嵌滚动。
private struct ProcessTable: View {
    let processes: [WineProcess]

    @State private var sortOrder: [KeyPathComparator<WineProcess>] = [KeyPathComparator(\WineProcess.name)]

    var body: some View {
        Table(processes.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("进程名称", value: \.name)
            TableColumn("PID", value: \.pid) { process in
                Text(Self.grouping.string(from: NSNumber(value: process.pid)) ?? "\(process.pid)")
            }
            TableColumn("内存", value: \.residentMB) { process in
                Text("\(process.residentMB) MB")
            }
            TableColumn("已运行", value: \.elapsedSeconds) { process in
                Text(ProcessInventory.formatElapsed(process.elapsed))
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(height: 176)
        .overlay {
            if processes.isEmpty {
                Text("未检测到运行中的进程")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private static let grouping: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
