import AppKit
import MacSWCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var runtime: RuntimeStore
    @ObservedObject var licenseServer: LicenseServerStore
    @ObservedObject var resourceMonitor: SolidWorksResourceMonitorStore
    @AppStorage(AppPreferences.autoLaunchSolidWorksKey) private var autoLaunchSolidWorks = AppPreferences.autoLaunchSolidWorksDefault
    @FocusState private var addressFocused: Bool
    @State private var confirmUninstall = false
    @State private var maintainsVisibility = false
    @State private var generalVisible = false
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
        .background(SettingsWindowLifecycle())
        .padding(16)
        .alert("卸载托管 FlexNet？", isPresented: $confirmUninstall) {
            Button("取消", role: .cancel) { }
            Button("停止并卸载", role: .destructive) { licenseServer.uninstall() }
        } message: {
            Text("会停止并删除 \(AppPaths.managedFlexNetWindowsPath)，并清空许可服务器列表——托管时它就是唯一一条地址。")
        }
        .alert("无法安装 FlexNet 服务器", isPresented: installProblemShown) {
            Button("好", role: .cancel) { licenseServer.dismissInstallProblem() }
        } message: {
            Text(licenseServer.installProblem ?? "")
        }
    }

    /// 安装失败直接弹窗，别只把原因写在状态行里等人去发现。
    private var installProblemShown: Binding<Bool> {
        Binding(
            get: { licenseServer.installProblem != nil },
            set: { shown in if !shown { licenseServer.dismissInstallProblem() } }
        )
    }

    private var generalSettings: some View {
        Form {
            personalizationSection
            licenseSection
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            generalVisible = true
            resourceMonitor.refresh()
        }
        .onDisappear { generalVisible = false }
        // 打开设置才去容器里读一次真实配置：App 启动路径上不起 wine 进程。
        .task(id: generalVisible) {
            guard generalVisible else { return }
            await licenseServer.syncFromContainer()
            while !Task.isCancelled {
                // 之后只读清单 + 探端口（不起 wine），所以能像面板一样两秒一轮；
                // 不然从面板或命令行启停的服务器，会在这一页一直挂着旧状态。
                if NSApp.isActive { await licenseServer.refreshRunningState() }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
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
                Spacer()
                // 写入注册表期间整块锁住，顺便转个菊花表示"在做事"。
                if licenseServer.isOperating {
                    ProgressView()
                        .controlSize(.small)
                }
                // 手工改过注册表（维护页就能打开注册表编辑器）之后用这个把真实配置读回来。
                Button {
                    Task {
                        await licenseServer.syncFromContainer(force: true)
                        // 手工选过的模式要让位给读回来的真实状态。
                        chosenLicenseMode = nil
                    }
                } label: {
                    Label("重新读取容器配置", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("从容器注册表读回许可服务器地址，需要几秒钟")
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

    private var personalizationSection: some View {
        Section("个性化") {
            Toggle("启动 MacSW 时自动启动 SOLIDWORKS", isOn: $autoLaunchSolidWorks)
            Text("打开时自动启动前，若托管 FlexNet 的地址指向 localhost 会先尝试拉起它；起不来只提示，不阻止 SOLIDWORKS 启动。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("禁用 sldProcMon", isOn: resourceMonitorDisabled)
                .disabled(!resourceMonitor.canChange)
            Text("阻止 SOLIDWORKS Resource Monitor 启动。开启后将 sldProcMon.exe 重命名为 sldProcMon.exe.disable，关闭时恢复；若 SOLIDWORKS 正在运行，将在下次启动时生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !resourceMonitor.statusMessage.isEmpty {
                Text(resourceMonitor.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resourceMonitorDisabled: Binding<Bool> {
        Binding(
            get: { resourceMonitor.isDisabled },
            set: { resourceMonitor.setDisabled($0) }
        )
    }

    private var addressEditor: some View {
        Group {
            HStack(spacing: 8) {
                Text("服务器地址")
                TextField("", text: $licenseServer.addressInput, prompt: Text("25734@license.example.com"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .onSubmit { commitAddressIfNeeded() }
                    .onChange(of: addressFocused) { focused in
                        if !focused { commitAddressIfNeeded() }
                    }
            }
            .disabled(licenseServer.isOperating)
            Text("port@host，也接受 host:port 与 [IPv6]:port；多个地址用分号分隔。回车或点到别处即写入注册表，下次启动 SOLIDWORKS 生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            // 状态紧跟标签，不用眼睛横穿整行去找它属于谁。
            HStack(spacing: 6) {
                Text("运行状态")
                Circle()
                    .fill(flexNetStateColor)
                    .frame(width: 7, height: 7)
                Text(flexNetStateText)
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
                    wineToolButton("CMD", name: "cmd")
                    Button("浏览虚拟 C 盘") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: runtime.paths.bottle.appendingPathComponent("drive_c").path)
                    }
                }
            }
            Section("容器进程") {
                ProcessTable(processes: runtime.processes)
                HStack {
                    Text("合计 \(ProcessInventory.formatMegabytes(ProcessInventory.totalResidentMB(runtime.processes))) · \(runtime.processes.count) 个进程")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("容器操作") {
                // 两个动作各占一行，说明写在各自按钮右边，读的人不用再去下面找对应关系。
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button("重启容器") { runtime.restartContainer() }
                    Text("结束 wineserver；若 SOLIDWORKS 正在运行会重新拉起。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button(role: .destructive) { runtime.forceStop() } label: {
                        // macOS 的 Form 按钮不会因为 role 变红（只在告警里生效），所以标签自己上色。
                        Text("强制终止全部进程").foregroundStyle(.red)
                    }
                    Text("终止容器里的全部进程，并在必要时结束 wineserver。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    @State private var sortOrder: [KeyPathComparator<WineProcess>] = []

    var body: some View {
        Table(sortedProcesses, sortOrder: $sortOrder) {
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

    private var sortedProcesses: [WineProcess] {
        guard !sortOrder.isEmpty else {
            return processes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return processes.sorted(using: sortOrder)
    }

    private static let grouping: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}
