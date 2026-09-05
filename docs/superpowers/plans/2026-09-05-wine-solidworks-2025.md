# SolidWorks 2025 on Wine/CrossOver 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 在 Apple Silicon Mac 上使用 CrossOver 26.3 Wine 兼容层，重构并运行已从 Parallels 虚拟机中抽取的 SolidWorks 2025 SP5.0 运行环境。

**架构：** 基于 CrossOver 26.3 64位 Wine 架构建立隔离的 Windows 10 Prefix 容器，对齐虚拟文件系统符号链接，导入虚拟机导出的 UTF-16LE 注册表，注册核心 COM 组件，并对接 FlexNet 25734 授权与 Apple Metal 图形管线。

**技术栈：** CrossOver 26.3.0 (Wine 9/10 系列), Apple Silicon arm64 + Rosetta 2, D3DMetal/DXVK, Bash, Windows Registry (regedit), COM (regsvr32).

---

### 文件结构与职责划分
- `scripts/init_bottle.sh`：创建并初始化 64 位 Windows 10 WINEPREFIX 容器，设置 Windows 版本与基础参数。
- `scripts/setup_filesystem.sh`：在虚拟 `drive_c/` 中对齐 `Program Files`、`ProgramData`、`SOLIDWORKS Data`、`SolidWorks_Flexnet_Server` 的软链接与目录结构。
- `scripts/import_registry.sh`：处理 `SWHKLM.reg` 与 `SWHKCU.reg` 格式适配并利用 Wine regedit 导入容器，注入授权环境变量。
- `scripts/register_components.sh`：批量调用 `regsvr32` 注册 SolidWorks 核心 COM/ActiveX 组件。
- `scripts/manage_license.sh`：管理与验证 FlexNet 25734 许可服务（支持直连 VM 与本地 lmgrd 启动）。
- `run_sw.sh`：主运行入口与调试包装脚本，配置 DXVK/D3DMetal 及日志通道，拉起 `SLDWORKS.exe` 并输出追踪日志。

---

### 任务 1：创建 CrossOver 专用容器并验证基础环境

**文件：**
- 创建：`scripts/init_bottle.sh`
- 测试验证：`bottle/system.reg` 生成状态及 Windows 版本查询

- [ ] **步骤 1：编写容器初始化脚本**

```bash
cat << 'EOF' > scripts/init_bottle.sh
#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WINEPREFIX="${WORKSPACE_ROOT}/bottle"
export WINEARCH="win64"
CROSSOVER_BIN="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"
export PATH="${CROSSOVER_BIN}:${PATH}"

echo "[INFO] 初始化 WINEPREFIX: ${WINEPREFIX}"
mkdir -p "${WINEPREFIX}"

# 仅在未初始化时运行 wineboot
if [ ! -f "${WINEPREFIX}/system.reg" ]; then
    wineboot -i
fi

# 设置系统版本为 win10
wine reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion' /v CurrentVersion /t REG_SZ /d '6.3' /f
wine reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion' /v ProductName /t REG_SZ /d 'Windows 10 Pro' /f
echo "[SUCCESS] Wine 容器初始化完成"
EOF
chmod +x scripts/init_bottle.sh
```

- [ ] **步骤 2：执行初始化并验证**

运行：`./scripts/init_bottle.sh && /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine cmd.exe /c "ver"`
预期输出：包含 `Microsoft Windows [Version 10.0.` 或成功进入 Windows 10 兼容模式。

- [ ] **步骤 3：Commit**

```bash
git add scripts/init_bottle.sh
git commit -m "feat: add container initialization script for win64"
```

---

### 任务 2：对齐虚拟 C 盘文件系统与符号链接

**文件：**
- 创建：`scripts/setup_filesystem.sh`
- 测试验证：检查容器中 `SLDWORKS.exe` 软链接路径的可达性

- [ ] **步骤 1：编写文件系统映射脚本**

```bash
cat << 'EOF' > scripts/setup_filesystem.sh
#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVE_C="${WORKSPACE_ROOT}/bottle/drive_c"

echo "[INFO] 映射 SolidWorks 数据目录到: ${DRIVE_C}"
mkdir -p "${DRIVE_C}/Program Files/SOLIDWORKS Corp"
mkdir -p "${DRIVE_C}/ProgramData"
mkdir -p "${DRIVE_C}/opt"

# 映射 Program Files/SOLIDWORKS Corp/SOLIDWORKS
if [ ! -e "${DRIVE_C}/Program Files/SOLIDWORKS Corp/SOLIDWORKS" ]; then
    ln -s "${WORKSPACE_ROOT}/C/Program Files/SOLIDWORKS Corp/SOLIDWORKS" "${DRIVE_C}/Program Files/SOLIDWORKS Corp/SOLIDWORKS"
fi

# 映射 ProgramData/SOLIDWORKS
if [ ! -e "${DRIVE_C}/ProgramData/SOLIDWORKS" ]; then
    ln -s "${WORKSPACE_ROOT}/C/ProgramData/SOLIDWORKS" "${DRIVE_C}/ProgramData/SOLIDWORKS"
fi

# 映射 SOLIDWORKS Data
if [ ! -e "${DRIVE_C}/SOLIDWORKS Data" ]; then
    ln -s "${WORKSPACE_ROOT}/C/SOLIDWORKS Data" "${DRIVE_C}/SOLIDWORKS Data"
fi

# 映射 SolidWorks_Flexnet_Server
if [ ! -e "${DRIVE_C}/opt/SolidWorks_Flexnet_Server" ]; then
    ln -s "${WORKSPACE_ROOT}/C/opt/SolidWorks_Flexnet_Server" "${DRIVE_C}/opt/SolidWorks_Flexnet_Server"
fi

echo "[SUCCESS] 虚拟 C 盘文件链接映射完成"
EOF
chmod +x scripts/setup_filesystem.sh
```

- [ ] **步骤 2：执行映射并验证**

运行：`./scripts/setup_filesystem.sh && ls -l "${WORKSPACE_ROOT}/bottle/drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe"`
预期输出：指向原 C 盘真实 `SLDWORKS.exe` 的软链接且存在。

- [ ] **步骤 3：Commit**

```bash
git add scripts/setup_filesystem.sh
git commit -m "feat: add virtual filesystem mapping script"
```

---

### 任务 3：注册表格式转换与批量导入

**文件：**
- 创建：`scripts/import_registry.sh`
- 测试验证：查询 Wine 注册表中 SolidWorks 2025 安装路径与版本信息

- [ ] **步骤 1：编写注册表导入脚本**

```bash
cat << 'EOF' > scripts/import_registry.sh
#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WINEPREFIX="${WORKSPACE_ROOT}/bottle"
CROSSOVER_BIN="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"
export PATH="${CROSSOVER_BIN}:${PATH}"

mkdir -p "${WORKSPACE_ROOT}/scratch"

echo "[INFO] 转换并导入 SWHKLM.reg..."
# 将 Windows UTF-16LE 转换成 UTF-8 确保 wine regedit 可靠解析
iconv -f UTF-16LE -t UTF-8 "${WORKSPACE_ROOT}/C/SWHKLM.reg" > "${WORKSPACE_ROOT}/scratch/SWHKLM_utf8.reg" || cp "${WORKSPACE_ROOT}/C/SWHKLM.reg" "${WORKSPACE_ROOT}/scratch/SWHKLM_utf8.reg"
wine regedit "${WORKSPACE_ROOT}/scratch/SWHKLM_utf8.reg"

echo "[INFO] 转换并导入 SWHKCU.reg..."
iconv -f UTF-16LE -t UTF-8 "${WORKSPACE_ROOT}/C/SWHKCU.reg" > "${WORKSPACE_ROOT}/scratch/SWHKCU_utf8.reg" || cp "${WORKSPACE_ROOT}/C/SWHKCU.reg" "${WORKSPACE_ROOT}/scratch/SWHKCU_utf8.reg"
wine regedit "${WORKSPACE_ROOT}/scratch/SWHKCU_utf8.reg"

# 补充 FlexNet 默认环境变量
wine reg add 'HKLM\System\CurrentControlSet\Control\Session Manager\Environment' /v SOLIDWORKS_LICENSE_FILE /t REG_SZ /d '25734@127.0.0.1' /f
echo "[SUCCESS] 注册表导入完成"
EOF
chmod +x scripts/import_registry.sh
```

- [ ] **步骤 2：执行导入并验证查询**

运行：`./scripts/import_registry.sh && /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine reg query "HKLM\Software\SolidWorks"`
预期输出：查询成功返回 SolidWorks 注册表键值。

- [ ] **步骤 3：Commit**

```bash
git add scripts/import_registry.sh
git commit -m "feat: add registry import and licensing config script"
```

---

### 任务 4：COM 组件注册与核心 DLL 注入

**文件：**
- 创建：`scripts/register_components.sh`
- 测试验证：调用 `regsvr32` 注册关键组件并检查状态

- [ ] **步骤 1：编写 COM 注册脚本**

```bash
cat << 'EOF' > scripts/register_components.sh
#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WINEPREFIX="${WORKSPACE_ROOT}/bottle"
CROSSOVER_BIN="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"
export PATH="${CROSSOVER_BIN}:${PATH}"

SW_DIR="${WINEPREFIX}/drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS"

echo "[INFO] 注册关键 COM/ActiveX 组件..."
cd "${SW_DIR}"

for dll in sldotu.dll swsecwrap.dll sldsearchcore.dll; do
    if [ -f "${dll}" ]; then
        echo "注册 ${dll}..."
        wine regsvr32 /s "${dll}" || true
    fi
done

echo "[SUCCESS] COM 注册处理完成"
EOF
chmod +x scripts/register_components.sh
```

- [ ] **步骤 2：执行注册脚本**

运行：`./scripts/register_components.sh`
预期输出：无报错，`[SUCCESS] COM 注册处理完成`。

- [ ] **步骤 3：Commit**

```bash
git add scripts/register_components.sh
git commit -m "feat: add COM registration script for core DLLs"
```

---

### 任务 5：FlexNet 许可服务管理与连通性验证

**文件：**
- 创建：`scripts/manage_license.sh`
- 测试验证：验证 25734 端口监听或可用性

- [ ] **步骤 1：编写许可服务管理脚本**

```bash
cat << 'EOF' > scripts/manage_license.sh
#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WINEPREFIX="${WORKSPACE_ROOT}/bottle"
CROSSOVER_BIN="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"
export PATH="${CROSSOVER_BIN}:${PATH}"

MODE="${1:-status}"
FLEX_DIR="${WINEPREFIX}/drive_c/opt/SolidWorks_Flexnet_Server"

case "${MODE}" in
    start)
        echo "[INFO] 启动本地 FlexNet 守护进程 (lmgrd.exe)..."
        cd "${FLEX_DIR}"
        nohup wine "${FLEX_DIR}/lmgrd.exe" -c "${FLEX_DIR}/sw_d_SSQ.lic" -l "${WORKSPACE_ROOT}/scratch/flexnet.log" >/dev/null 2>&1 &
        sleep 2
        echo "[SUCCESS] FlexNet 启动命令已发出"
        ;;
    point-vm)
        TARGET_IP="${2:?请提供虚拟机 IP，例如: ./scripts/manage_license.sh point-vm 10.211.55.3}"
        echo "[INFO] 将许可服务器指向虚拟机: 25734@${TARGET_IP}"
        wine reg add 'HKLM\System\CurrentControlSet\Control\Session Manager\Environment' /v SOLIDWORKS_LICENSE_FILE /t REG_SZ /d "25734@${TARGET_IP}" /f
        wine reg add 'HKCU\Software\FLEXlm License Manager' /v SW_D_LICENSE_FILE /t REG_SZ /d "25734@${TARGET_IP}" /f
        echo "[SUCCESS] 已更新注册表许可指向为: 25734@${TARGET_IP}"
        ;;
    status)
        echo "[INFO] 检查 25734 端口状态..."
        nc -zv -w 2 127.0.0.1 25734 || echo "[NOTE] 本地 25734 端口未监听，若虚拟机运行请使用 point-vm 模式"
        ;;
    *)
        echo "Usage: $0 {start|point-vm <ip>|status}"
        exit 1
        ;;
esac
EOF
chmod +x scripts/manage_license.sh
```

- [ ] **步骤 2：测试许可脚本**

运行：`./scripts/manage_license.sh status`
预期输出：正常输出状态说明。

- [ ] **步骤 3：Commit**

```bash
git add scripts/manage_license.sh
git commit -m "feat: add FlexNet licensing manager script"
```

---

### 任务 6：构建启动与调试包装器 run_sw.sh 并进行首次启动测试

**文件：**
- 创建：`run_sw.sh`
- 测试验证：执行启动测试，捕获首轮输出与崩溃日志保存到 `scratch/sw_launch.log`

- [ ] **步骤 1：编写启动包装脚本**

```bash
cat << 'EOF' > run_sw.sh
#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WINEPREFIX="${WORKSPACE_ROOT}/bottle"
CROSSOVER_BIN="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"
export PATH="${CROSSOVER_BIN}:${PATH}"

SW_DIR="${WINEPREFIX}/drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS"
mkdir -p "${WORKSPACE_ROOT}/scratch"
LOG_FILE="${WORKSPACE_ROOT}/scratch/sw_launch.log"

# 配置图形后端与 DLL 覆盖
export WINEDLLOVERRIDES="mscoree=d;mshtml=d;d3dcompiler_47=n,b"
export DXVK_LOG_LEVEL="info"
export MVK_CONFIG_LOG_LEVEL="2"

# 调试级别
DEBUG_CHANNELS="${1:-warn+all,fixme-all}"
export WINEDEBUG="${DEBUG_CHANNELS}"

echo "========================================="
echo "启动 SolidWorks 2025 (Wine/CrossOver)"
echo "日志输出至: ${LOG_FILE}"
echo "========================================="

cd "${SW_DIR}"
wine "${SW_DIR}/SLDWORKS.exe" "$@" 2>&1 | tee "${LOG_FILE}"
EOF
chmod +x run_sw.sh
```

- [ ] **步骤 2：进行首轮启动捕获**

运行：`./run_sw.sh`（设定短超时以捕获初次运行输出与缺失依赖）
预期输出：捕获到 `SLDWORKS.exe` 调用的第一个断点/返回码并记录至 `scratch/sw_launch.log`。

- [ ] **步骤 3：Commit**

```bash
git add run_sw.sh
git commit -m "feat: add SolidWorks main launcher and debug harness"
```
