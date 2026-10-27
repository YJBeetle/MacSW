"""Explicit, in-place upgrades for MacSW's managed Wine bottle.

No Wine process is used to discover the installed runtime. A migration holds
the same launch lock as the App/CLI, stops only this prefix,
and updates the selected bottle without making App or container backups.
Failed upgrades stay blocked until explicitly retried or reinstalled.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid

MODULES = {
    "WineMacModuleSHA256": "lib/wine/x86_64-unix/winemac.so",
    "WineInputModuleSHA256": "lib/wine/x86_64-unix/win32u.so",
    "WineCOMBaseModuleSHA256": "lib/wine/x86_64-windows/combase.dll",
    "WineComctl32V6ModuleSHA256": "lib/wine/x86_64-windows/comctl32_v6.dll",
    "WineNtdllModuleSHA256": "lib/wine/x86_64-unix/ntdll.so",
    "WineLoaderSHA256": "lib/wine/x86_64-unix/MacSW",
    "MonoPatchSHA256": "share/wine/mono/wine-mono-{MonoVersion}/bin/libmono-2.0-x86.dll",
    "MonoMscorlibSHA256": "share/wine/mono/wine-mono-{MonoVersion}/lib/mono/4.5/mscorlib.dll",
    "MonoRegAsmX86SHA256": "lib/wine/i386-windows/regasm.exe",
    "MonoRegAsmX64SHA256": "lib/wine/x86_64-windows/regasm.exe",
}

MSXML_MODULES = {
    "WineMSXML3ModuleSHA256": "lib/wine/x86_64-windows/msxml3.dll",
}
MSXML_IDENTITY_KEYS = ("WineMSXMLSchemaPatchSHA256", *MSXML_MODULES)

FILE_MANAGER_MODULES = {
    "WineShell32X64ModuleSHA256": "lib/wine/x86_64-windows/shell32.dll",
    "WineShell32X86ModuleSHA256": "lib/wine/i386-windows/shell32.dll",
    "WineExplorerX64ModuleSHA256": "lib/wine/x86_64-windows/explorer.exe",
    "WineExplorerX86ModuleSHA256": "lib/wine/i386-windows/explorer.exe",
}
FILE_MANAGER_IDENTITY_KEYS = ("WineNativeFileManagerPatchSHA256", *FILE_MANAGER_MODULES)

# Older baseline receipts predate these modules. New manifests must bind the
# entire extension group; partial declarations never weaken verification.
TOOLBOX_MODULES = {
    "MonoCCWModuleSHA256": "share/wine/mono/wine-mono-{MonoVersion}/bin/libmono-2.0-x86_64.dll",
    "MonoBTLSModuleSHA256": "share/wine/mono/wine-mono-{MonoVersion}/lib/x86_64/libmono-btls-shared.dll",
}


def state_root(prefix):
    if prefix.is_symlink() or prefix.name in ("", ".", "..") or len(prefix.parts) < 3:
        raise RuntimeError("容器路径不安全，拒绝迁移。")
    return prefix.parent / ("." + prefix.name + ".wine-runtime")


def identity(contents):
    with (contents / "Resources/BuildManifest.plist").open("rb") as stream:
        manifest = plistlib.load(stream)
    values = {key: value for key, value in manifest.items()
              if key.startswith(("Wine", "Mono")) and isinstance(value, str)}
    if not all(values.get(key) for key in ("WineVersion", "MonoVersion", *MODULES)):
        raise RuntimeError("App 的 Wine/Mono 构建身份不完整，请重新下载完整 App。")
    if any(key in values for key in MSXML_IDENTITY_KEYS) and not all(values.get(key) for key in MSXML_IDENTITY_KEYS):
        raise RuntimeError("App 的 MSXML 运行时身份不完整。")
    if any(key in values for key in TOOLBOX_MODULES) and not all(values.get(key) for key in TOOLBOX_MODULES):
        raise RuntimeError("App 的 Toolbox 运行时身份不完整。")
    if any(key in values for key in FILE_MANAGER_IDENTITY_KEYS) and not all(values.get(key) for key in FILE_MANAGER_IDENTITY_KEYS):
        raise RuntimeError("App 的 Finder 桥接运行时身份不完整。")
    return values


def verify_app(contents, values):
    modules = dict(MODULES)
    if any(key in values for key in MSXML_IDENTITY_KEYS):
        if not all(values.get(key) for key in MSXML_IDENTITY_KEYS):
            raise RuntimeError("App 的 MSXML 运行时身份不完整。")
        modules.update(MSXML_MODULES)
    if any(key in values for key in TOOLBOX_MODULES):
        if not all(values.get(key) for key in TOOLBOX_MODULES):
            raise RuntimeError("App 的 Toolbox 运行时身份不完整。")
        modules.update(TOOLBOX_MODULES)
    if any(key in values for key in FILE_MANAGER_IDENTITY_KEYS):
        if not all(values.get(key) for key in FILE_MANAGER_IDENTITY_KEYS):
            raise RuntimeError("App 的 Finder 桥接运行时身份不完整。")
        modules.update(FILE_MANAGER_MODULES)
    for key, relative in modules.items():
        path = contents / "Frameworks/wine" / relative.format(**values)
        with path.open("rb") as stream:
            hasher = hashlib.sha256()
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                hasher.update(block)
            digest = hasher.hexdigest()
        if digest != values[key]:
            raise RuntimeError(f"Wine/Mono 模块校验失败：{key}；未升级容器。")


def verify_seal(contents):
    # Unsigned source-build fixtures have no resource seal. Keep this separate
    # from verify_app: packaging checks module hashes before the outer re-sign.
    if not (contents / "_CodeSignature/CodeResources").exists():
        return
    try:
        result = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(contents.parent)],
            capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"无法验证 App 签名，已停止迁移，未执行 Wine：{contents.parent}") from error
    if result.returncode:
        raise RuntimeError(
            f"App 签名校验失败，已停止迁移，未执行 Wine：{contents.parent}。"
            "请重新下载完整 App；未修改容器，勿跳过安全检查。")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path, value):
    # fsync before publication so a power loss cannot expose a partial receipt.
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        json.dump(value, stream, ensure_ascii=False, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def managed(prefix):
    main = Path.home() / "Library/Application Support/MacSW/bottle"
    return prefix.absolute() == main or state_root(prefix).exists()


def status(contents, prefix):
    root = state_root(prefix)
    if (root / "pending.json").exists():
        return "recovery"
    if not managed(prefix):
        return "unmanaged"
    if not (prefix / "drive_c").exists():
        return "fresh"
    receipt = root / "receipt.json"
    if not receipt.exists():
        return "baseline"
    old = read_json(receipt)
    marker = prefix / ".macsw-wine-prefix-id"
    if old.get("format") not in (1, 2):
        return "invalid"
    if not marker.exists() or marker.read_text().strip() != old.get("prefix_id"):
        return "baseline"
    matches_path = not old.get("active_app") or old["active_app"] == str(contents.parent.resolve())
    return "ready" if old["identity"] == identity(contents) and matches_path else "upgrade"


def require_ready(contents, prefix):
    value = status(contents, prefix)
    if value not in ("ready", "fresh", "unmanaged"):
        raise RuntimeError("Wine 容器需要版本确认、升级或重试；请在 MacSW 设置 → 维护中处理，未启动新版 Wine。")


@contextmanager
def launch_lock(prefix, exclusive=False):
    root = state_root(prefix)
    root.mkdir(parents=True, exist_ok=True)
    if root.is_symlink():
        raise RuntimeError("Wine 升级状态目录不能是符号链接。")
    descriptor = os.open(root / "launch.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w") as lock:
        os.set_inheritable(descriptor, False)
        try:
            fcntl.flock(lock, (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("Wine 容器升级或启动正在执行，请稍后重试。") from error
        yield root


def launch(contents, prefix, arguments):
    # Lock only the check + spawn boundary. The upgrader can stop a running
    # SOLIDWORKS after explicit confirmation, without deadlocking on its lease.
    if not managed(prefix):
        process = subprocess.Popen(arguments)
    else:
        with launch_lock(prefix):
            require_ready(contents, prefix)
            process = subprocess.Popen(arguments)
    return process.wait()


def baseline(contents, prefix):
    with launch_lock(prefix, exclusive=True) as root:
        if (root / "pending.json").exists():
            raise RuntimeError("存在未完成的迁移，请先重试升级或重新安装。")
        if not (prefix / "drive_c").is_dir():
            raise RuntimeError("请先完成容器安装。")
        verify_seal(contents)
        values = identity(contents)
        receipt = root / "receipt.json"
        marker = prefix / ".macsw-wine-prefix-id"
        if receipt.exists() and marker.exists():
            old = read_json(receipt)
            if old["identity"] != values or (old.get("active_app") and old["active_app"] != str(contents.parent.resolve())):
                raise RuntimeError("不能用记录基线绕过 Wine 版本升级。")
        verify_app(contents, values)
        if marker.is_symlink():
            raise RuntimeError("容器身份标记不能是符号链接。")
        prefix_id = marker.read_text().strip() if marker.exists() else str(uuid.uuid4())
        marker.write_text(prefix_id, encoding="utf-8")
        write_json(receipt, {"format": 2, "prefix_id": prefix_id,
                             "identity": values, "active_app": str(contents.parent.resolve())})
        print("已记录当前可用 Wine/Mono。", flush=True)


def environment(contents, prefix):
    result = dict(os.environ)
    for key in ("WINEDLLPATH", "CX_ROOT", "CX_BOTTLE", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH",
                "WINEDLLOVERRIDES", "MONO_ENV_OPTIONS"):
        result.pop(key, None)
    wine = contents / "Frameworks/wine"
    result.update(WINEPREFIX=str(prefix), WINELOADER=str(wine / "lib/wine/x86_64-unix/MacSW"),
                  WINESERVER=str(wine / "bin/wineserver"), WINEDEBUG="-all", WINE_MONO_AOT="none",
                  LANG="zh_CN.UTF-8", LC_ALL="zh_CN.UTF-8")
    result["MACSW_NATIVE_FILE_MANAGER"] = "1"
    return result


def run(contents, prefix, arguments, log, *, server=False):
    env = environment(contents, prefix)
    binary = env["WINESERVER" if server else "WINELOADER"]
    with log.open("ab") as output:
        subprocess.run([binary, *arguments], env=env, stdout=output, stderr=output,
                       timeout=120, check=True)


def stop(contents, prefix, log):
    verify_seal(contents)
    # -k may report no server (1); still require a successful bounded -w.
    try:
        run(contents, prefix, ["-k"], log, server=True)
    except subprocess.CalledProcessError as error:
        if error.returncode != 1:
            raise
    run(contents, prefix, ["-w"], log, server=True)


def deploy_file_manager(contents, prefix):
    # wineboot -u can retain builtin files with the same Wine version. Publish
    # these explicitly while this prefix's server is stopped, never in place.
    for arch, directory in (("x86_64-windows", "system32"), ("i386-windows", "syswow64")):
        for module in ("shell32.dll", "explorer.exe"):
            source = contents / "Frameworks/wine/lib/wine" / arch / module
            targets = [prefix / "drive_c/windows" / directory / module]
            if arch == "x86_64-windows" and module == "explorer.exe":
                targets.append(prefix / "drive_c/windows/explorer.exe")
            for target in targets:
                if not target.parent.resolve().is_relative_to(prefix.resolve()):
                    raise RuntimeError("Finder 桥接目标目录指向容器外部。")
                target.parent.mkdir(parents=True, exist_ok=True)
                with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as stream:
                    staging = Path(stream.name)
                try:
                    shutil.copy2(source, staging)
                    with staging.open("rb") as stream:
                        os.fsync(stream.fileno())
                    os.replace(staging, target)
                finally:
                    staging.unlink(missing_ok=True)


def boot(contents, prefix, log):
    verify_seal(contents)
    values = identity(contents)
    verify_app(contents, values)
    run(contents, prefix, [r"C:\windows\system32\wineboot.exe", "-u"], log)
    if all(values.get(key) for key in FILE_MANAGER_IDENTITY_KEYS):
        stop(contents, prefix, log)
        deploy_file_manager(contents, prefix)
    runtime = contents / "Frameworks/wine"
    mono = runtime / f"share/wine/mono/wine-mono-{values['MonoVersion']}"
    run(contents, prefix, [r"C:\windows\system32\reg.exe", "add", r"HKCU\Software\Wine\Mono",
                          "/v", "RuntimePath", "/t", "REG_SZ", "/d",
                          "Z:" + str(mono).replace("/", "\\"), "/f"], log)
    for arch, framework in (("i386-windows", "Framework"), ("x86_64-windows", "Framework64")):
        target = prefix / f"drive_c/windows/Microsoft.NET/{framework}/v4.0.30319/regasm.exe"
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.parent.resolve().is_relative_to(prefix.resolve()):
            raise RuntimeError("RegAsm 目标目录指向容器外部。")
        with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as stream:
            staging = Path(stream.name)
        shutil.copy2(runtime / f"lib/wine/{arch}/regasm.exe", staging)
        os.replace(staging, target)
    # Check protocol dependencies, not just wineboot's exit status. CAD modeling
    # and visible rendering remain an explicit post-upgrade acceptance step.
    run(contents, prefix, [r"C:\windows\system32\reg.exe", "query", r"HKCR\SldWorks.Application\CLSID"], log)
    run(contents, prefix, [r"C:\MacSW\Python311\python.exe", "-c",
                          "import pythoncom, win32com.client, swcli; print('backend imports OK')"], log)
    run(contents, prefix, [r"C:\windows\system32\reg.exe", "query",
                          r"HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontLink\SystemLink",
                          "/v", "Tahoma"], log)


def migrate(contents, prefix, *, retry=False):
    with launch_lock(prefix, exclusive=True) as root:
        current = status(contents, prefix)
        if current == "ready":
            print("Wine/Mono 未变化，无需迁移。")
            return
        if current != ("recovery" if retry else "upgrade"):
            raise RuntimeError("请先记录已知可用版本，或重试未完成的升级。")
        old = read_json(root / "receipt.json")
        marker = prefix / ".macsw-wine-prefix-id"
        if (old.get("format") not in (1, 2) or marker.is_symlink()
                or marker.read_text().strip() != old.get("prefix_id")):
            raise RuntimeError("容器身份不匹配，拒绝升级。")
        verify_seal(contents)
        values = identity(contents)
        verify_app(contents, values)
        active_app = str(contents.parent.resolve())
        journal = {"format": 2, "mode": "in-place", "prefix_id": old["prefix_id"],
                   "identity": values, "active_app": active_app}
        if retry and read_json(root / "pending.json") != journal:
            raise RuntimeError("未完成升级的版本或容器不匹配；旧版备份记录请用旧版处理，或重新安装。")
        log = root / "migration.log"
        print("正在停止选定容器…", flush=True)
        # Wine 11.16 -k/-w operate only on this prefix's server lock; they do
        # not start a server, run wineboot, or load old container DLLs. Use the
        # current verified bundle, never an old archived executable.
        stop(contents, prefix, log)
        write_json(root / "pending.json", journal)
        try:
            print("正在更新 Wine、Mono 和 COM 注册工具并检查依赖…", flush=True)
            boot(contents, prefix, log)
            stop(contents, prefix, log)
            write_json(root / "last-upgrade.json", journal)
            write_json(root / "receipt.json", {"format": 2, "prefix_id": old["prefix_id"],
                                               "identity": values, "active_app": active_app})
            (root / "pending.json").unlink()
            print("升级及依赖检查完成；请启动 SOLIDWORKS 验收。", flush=True)
        except Exception as error:
            raise RuntimeError(f"原地升级失败，未备份且未自动回退。请重试升级或重新安装；日志：{log}；原因：{error}") from error


def shutdown(contents, prefix):
    with launch_lock(prefix, exclusive=True) as root:
        verify_app(contents, identity(contents))
        # Only wineserver: shutting down must not boot the new runtime.
        stop(contents, prefix, root / "migration.log")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "baseline", "upgrade", "recover", "rollback", "stop", "launch"))
    parser.add_argument("--contents", type=Path, required=True)
    parser.add_argument("--prefix", type=Path, required=True)
    args, command = parser.parse_known_args()
    if command and args.command != "launch":
        parser.error("unexpected arguments: " + " ".join(command))
    contents, prefix = args.contents.absolute(), args.prefix.absolute()
    try:
        if args.command == "check":
            require_ready(contents, prefix)
        elif args.command == "baseline":
            baseline(contents, prefix)
        elif args.command == "upgrade":
            migrate(contents, prefix)
        elif args.command == "rollback":
            raise RuntimeError("已取消自动备份与回退；请重试升级或重新安装。旧备份未删除。")
        elif args.command == "stop":
            shutdown(contents, prefix)
        elif args.command == "recover":
            migrate(contents, prefix, retry=True)
        else:
            return launch(contents, prefix, command[1:] if command[:1] == ["--"] else command)
    except Exception as error:
        print(str(error), file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
