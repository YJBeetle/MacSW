import SwiftUI

/// 安装结果保留到用户确认，不能因收到完成通知就消失。
struct InstallationCompletionView: View {
    let autoLaunch: Bool
    let warnings: [String]
    let onRevealLogs: () -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 5) {
                    Text("安装成功").font(.title2.bold())
                    Text("SOLIDWORKS 已安装完成。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            Text(autoLaunch
                ? "点击“完成”关闭安装窗口并启动 SOLIDWORKS。"
                : "点击“完成”关闭安装窗口。之后可从菜单栏启动 SOLIDWORKS。")
                .foregroundStyle(.secondary)

            if !warnings.isEmpty {
                GroupBox("安装提示") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(warnings.indices, id: \.self) { index in
                                Label(warnings[index], systemImage: "exclamationmark.triangle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: 120)
                }
            }

            HStack {
                Button("查看日志", action: onRevealLogs)
                Spacer()
                Button("完成", action: onFinish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
