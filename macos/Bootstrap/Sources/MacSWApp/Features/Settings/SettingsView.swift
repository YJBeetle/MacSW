import AppKit
import MacSWCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var runtime: RuntimeStore
    @ObservedObject var licenseServer: LicenseServerStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("MacSW.autoLaunchSolidWorks") private var autoLaunchSolidWorks = true
    @FocusState private var addressFocused: Bool
    @State private var confirmUninstall = false

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("通用", systemImage: "gearshape") }
            licenseSettings
                .tabItem { Label("许可服务器", systemImage: "server.rack") }
            advancedSettings
                .tabItem { Label("Wine 工具", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560, height: 390)
        .padding(16)
        .task { await licenseServer.refresh() }
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
                Text("如果安装了托管 FlexNet 且地址指向 localhost，会先确保许可服务运行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("状态") {
                LabeledContent("SOLIDWORKS", value: runtime.isInstalled ? "已安装" : "未安装")
                Text(runtime.statusMessage).font(.caption).foregroundStyle(.secondary)
            }
            Section("安装与部署") {
                Button("安装或重新安装 SOLIDWORKS…") {
                    AppLifecycleBridge.showBootstrap(openWindow: openWindow)
                }
                Text("打开独立的 Bootstrap 窗口；全新安装选项只在现有容器存在时显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var licenseSettings: some View {
        Form {
            Section("服务器地址") {
                TextField("25734@license.example.com", text: $licenseServer.addressInput)
                    .focused($addressFocused)
                    .onSubmit { licenseServer.saveAddress() }
                    .onChange(of: addressFocused) { focused in
                        if !focused, !licenseServer.addressInput.isEmpty {
                            _ = licenseServer.normalizeAddressInput()
                        }
                    }
                Text("优先使用 port@host；也接受 host:port 与 [IPv6]:port，多个服务器以分号分隔。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !licenseServer.addressNotice.isEmpty {
                    Text(licenseServer.addressNotice)
                        .font(.caption)
                        .foregroundStyle(licenseServer.addressHasError ? .red : .secondary)
                }
                Button("保存到 Wine 注册表") { licenseServer.saveAddress() }
                    .disabled(licenseServer.isOperating)
            }

            Section("托管 FlexNet") {
                LabeledContent("安装位置", value: "C:\\opt\\FlexNet")
                HStack {
                    if licenseServer.isInstalled {
                        Button("启动") { licenseServer.start() }
                        Button("停止") { licenseServer.stop() }
                        Button("卸载…", role: .destructive) { confirmUninstall = true }
                    } else {
                        Button("安装目录或压缩包…") {
                            if let url = OpenPanelService.chooseFlexNetPackage() { licenseServer.install(from: url) }
                        }
                    }
                }
                .disabled(licenseServer.isOperating)
                Text(licenseServer.statusMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var advancedSettings: some View {
        Form {
            Section("Wine") {
                HStack {
                    Button("注册表编辑器") { runtime.openWineTool("regedit") }
                    Button("Wine 配置") { runtime.openWineTool("winecfg") }
                    Button("浏览虚拟 C 盘") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: runtime.paths.bottle.appendingPathComponent("drive_c").path)
                    }
                }
            }
            Section("故障处理") {
                Button("强制终止 SOLIDWORKS", role: .destructive) { runtime.forceStop() }
                Text("仅在 SOLIDWORKS 无法正常退出时使用，未保存的内容可能丢失。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
