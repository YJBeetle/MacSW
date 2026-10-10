# ASM 保存失败：MSXML SchemaCache 命名空间兼容

本修复独立于 Toolbox 的 Mono CCW Release 补丁。DockerSW 可移植
`patches/wine-crossover/0014-msxml-schema-cache-namespace.patch`，无需同步
Mono 引擎或 macOS 驱动改动。

## 根因与行为

原运行时在新空白装配体上也能复现 `SaveAs3` 错误码 1、0 字节文件，恢复原版
Mono 后同样失败，排除了 CCW 修改导致保存故障的解释。

SW 将没有 `targetNamespace` 的官方 `data/xmlschema/sw2005plusSchema.xsd` 加到
SchemaCache60 的 `http://www.solidworks.com/sw2003/schema` 命名空间下。
Wine 没有把该 XSD 绑定到缓存命名空间，保存 XML 因此验证失败；错误原因字符串
又为空，SW 的失败分支还可能在 `sldmoasmu.dll+0x23dd6` 读取空指针。

补丁仅对非空缓存 URI、未声明目标命名空间的 XSD，在缓存的私有 DOM 副本上补齐
`targetNamespace`，调整需采用该命名空间的未限定 QName。保留已有命名空间、
显式前缀、局部 form、XPath 与调用者 DOM，跳过 annotation，失败时清理私有副本。
没有关闭 XML 验证、篡改官方 XSD 或把保存错误强行改成成功。

## 部署与实测

Wine 中 MSXML6 的工厂转发到 `dlls/msxml3/schema.c`，实际需构建并部署匹配运行时
及架构的 `msxml3.dll`，不能只替换 `msxml6.dll`。Linux/Wine 可将补丁应用到自己的
Wine 源码并重新构建该模块；MacSW 的完整提交另含本项目的构建、打包与身份校验
接线，不必直接移植这些 macOS 专用脚本。部署时先正常退出 SW，避免继续使用旧模块。

MacSW 正式主实例已验证：三个组件保存／重开成功；用户手动配置和确认新规格后，
五组件 ASM 保存错误码 0、文件 174,664 字节，重开错误码 0，配置、实体数及包围盒
一致（最大差值 4.34e-19 米）。重开警告 2 经官方类型库确认是只读警告。
该主实例同时含独立 CCW 修复，因此不能把这次 GUI 结果当成“仅 MSXML”对勾证据。
仅 MSXML 候选的新空白 ASM 保存／重开也已通过，文件 35,664 字节、错误和警告均为 0。

保存不是 Pack and Go，重开仍依赖可访问的组件文件；测试应使用副本并保持 Toolbox
副本路径，避免 SW 自动重映射到原库生成配置。DockerSW 需在自己的实际宿主复测。
