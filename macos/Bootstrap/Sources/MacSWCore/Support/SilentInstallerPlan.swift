import Foundation

/// 官方 SOLIDWORKS MSI 在 Wine 下静默安装所需的参数与属性集合。
public enum SilentInstallerPlan {
    public static let coreMSIRelativePath = "swwi/data/solidworks.msi"

    /// SOLIDWORKS 的核心特性树定义在 INSTALLLEVEL 100；静默安装没有交互式
    /// 特性选择界面，必须显式列出嵌套依赖，否则单靠 ADDLOCAL=SolidWorks 装不全。
    public static let defaultMSIProperties = [
        "INSTALLLEVEL=100",
        "ADDLOCAL=SolidWorks,ProgramFiles,i386_ProgramFiles,i386_ThirdPtyFiles,i386_DCubeFiles,i386_SWFiles,i386_VistaFiles",
        "ENABLEPERFORMANCE=0",
        "OFFICEOPTION=3",
        // MSI 的默认值是相对路径，Wine 下会让 InstallFinalize 阶段的
        // WriteToolboxStandardsXML 失败，改用无空格的绝对路径。
        "TOOLBOXFOLDER=C:\\SWData"
    ]

    public static func coreInstallArguments(msi: URL, log: URL, serials: InstallSerials) -> [String] {
        msiexecArguments(msi: msi, log: log, properties: defaultMSIProperties + serials.msiProperties)
    }

    public static func languageInstallArguments(msi: URL, log: URL) -> [String] {
        msiexecArguments(msi: msi, log: log, properties: [])
    }

    /// 关闭静默安装时只带日志参数，其余交给官方安装向导。
    public static func interactiveInstallArguments(msi: URL, log: URL) -> [String] {
        ["msiexec", "/i", msi.path, "DISABLEROLLBACK=1", "/l*v", log.path]
    }

    static func msiexecArguments(msi: URL, log: URL, properties: [String]) -> [String] {
        var arguments = [
            "msiexec", "/i", msi.path, "/qb", "/norestart", "DISABLEROLLBACK=1",
            "/l*v", log.path
        ]
        arguments.append(contentsOf: properties)
        return arguments
    }
}
