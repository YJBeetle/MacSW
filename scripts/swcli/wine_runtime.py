"""Explicit, recoverable upgrades for MacSW's managed Wine bottle.

No Wine process is used to discover the installed runtime. A migration holds
the same launch lock as the App/CLI, stops only this prefix, clones it on APFS,
and keeps both the old App and the original bottle. No backups are auto-pruned.
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
    return values


def fingerprint(values):
    return hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()


def verify_app(contents, values):
    for key, relative in MODULES.items():
        path = contents / "Frameworks/wine" / relative.format(**values)
        with path.open("rb") as stream:
            hasher = hashlib.sha256()
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                hasher.update(block)
            digest = hasher.hexdigest()
        if digest != values[key]:
            raise RuntimeError(f"Wine/Mono 模块校验失败：{key}；未升级容器。")


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
    if old.get("format") != 1 or not marker.exists() or marker.read_text().strip() != old.get("prefix_id"):
        return "baseline"
    matches_path = not old.get("active_app") or old["active_app"] == str(contents.parent.resolve())
    return "ready" if old["identity"] == identity(contents) and matches_path else "upgrade"


def require_ready(contents, prefix):
    value = status(contents, prefix)
    if value not in ("ready", "fresh", "unmanaged"):
        raise RuntimeError("Wine 容器需要版本确认、升级或恢复；请在 MacSW 设置 → 维护中处理，未启动新版 Wine。")


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


def clone(source, destination):
    if destination.exists() or destination.is_symlink():
        raise RuntimeError("备份目标已存在，拒绝覆盖。")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.stat().st_dev == destination.parent.stat().st_dev:
        command = ["/bin/cp", "-cR", str(source), str(destination)]
    else:
        # The App may live on an external/Data volume. Cross-volume archive
        # copies need real space; do not follow bottle links into user folders.
        size = 0
        for directory, _, files in os.walk(source, followlinks=False):
            for name in files:
                file = Path(directory) / name
                if not file.is_symlink():
                    size += file.stat().st_size
        if shutil.disk_usage(destination.parent).free < size + 256 * 1024 * 1024:
            raise RuntimeError("跨卷备份可用空间不足，已拒绝复制。")
        command = ["/usr/bin/ditto", "--noqtn", str(source), str(destination)]
    with tempfile.TemporaryFile() as errors:
        result = subprocess.run(command, stdout=errors, stderr=errors, timeout=600)
        if result.returncode:
            errors.seek(0)
            detail = errors.read(2048).decode(errors="replace")
            raise RuntimeError("容器/App 备份或复制失败，已有备份保留：" + detail)


def archive(contents, root, values):
    if contents.parent.is_symlink():
        raise RuntimeError("App 归档源不能是符号链接。")
    target = root / "apps" / fingerprint(values) / "MacSW.app"
    if not target.exists():
        stage = target.parent / ("staging-" + str(uuid.uuid4()) + ".app")
        clone(contents.parent, stage)
        verify_app(stage / "Contents", values)
        stage.rename(target)
    verify_app(target / "Contents", values)
    if identity(target / "Contents") != values:
        raise RuntimeError("归档 App 的构建身份不匹配。")
    return target


def baseline(contents, prefix):
    with launch_lock(prefix, exclusive=True) as root:
        if (root / "pending.json").exists():
            raise RuntimeError("存在未完成的迁移，请先恢复。")
        if not (prefix / "drive_c").is_dir():
            raise RuntimeError("请先完成容器安装。")
        values = identity(contents)
        receipt = root / "receipt.json"
        marker = prefix / ".macsw-wine-prefix-id"
        if receipt.exists() and marker.exists():
            old = read_json(receipt)
            if old["identity"] != values or (old.get("active_app") and old["active_app"] != str(contents.parent.resolve())):
                raise RuntimeError("不能用记录基线绕过 Wine 版本升级。")
        verify_app(contents, values)
        old_app = archive(contents, root, values)
        if marker.is_symlink():
            raise RuntimeError("容器身份标记不能是符号链接。")
        prefix_id = marker.read_text().strip() if marker.exists() else str(uuid.uuid4())
        marker.write_text(prefix_id, encoding="utf-8")
        write_json(receipt, {"format": 1, "prefix_id": prefix_id,
                             "identity": values, "app": str(old_app), "active_app": str(contents.parent.resolve())})
        print("已记录当前可用 Wine/Mono，并保留完整旧 App。", flush=True)


def environment(contents, prefix):
    result = dict(os.environ)
    for key in ("WINEDLLPATH", "CX_ROOT", "CX_BOTTLE", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH",
                "WINEDLLOVERRIDES", "MONO_ENV_OPTIONS"):
        result.pop(key, None)
    wine = contents / "Frameworks/wine"
    result.update(WINEPREFIX=str(prefix), WINELOADER=str(wine / "lib/wine/x86_64-unix/MacSW"),
                  WINESERVER=str(wine / "bin/wineserver"), WINEDEBUG="-all", WINE_MONO_AOT="none",
                  LANG="zh_CN.UTF-8", LC_ALL="zh_CN.UTF-8")
    return result


def run(contents, prefix, arguments, log, *, server=False):
    env = environment(contents, prefix)
    binary = env["WINESERVER" if server else "WINELOADER"]
    with log.open("ab") as output:
        subprocess.run([binary, *arguments], env=env, stdout=output, stderr=output,
                       timeout=120, check=True)


def stop(contents, prefix, log):
    # -k may report no server (1); still require a successful bounded -w.
    try:
        run(contents, prefix, ["-k"], log, server=True)
    except subprocess.CalledProcessError as error:
        if error.returncode != 1:
            raise
    run(contents, prefix, ["-w"], log, server=True)


def boot(contents, prefix, log):
    values = identity(contents)
    verify_app(contents, values)
    run(contents, prefix, [r"C:\windows\system32\wineboot.exe", "-u"], log)
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


def restore(root, prefix, log):
    journal = read_json(root / "pending.json")
    backup = Path(journal["backup"])
    # Journal paths are untrusted input. Never rename/delete arbitrary paths.
    if (backup.parent.parent != root / "backups" or backup.name != "bottle" or backup.is_symlink()
            or not backup.resolve().is_relative_to(root.resolve())):
        raise RuntimeError("恢复记录中的备份路径不安全。")
    old = journal["previous"]
    if (backup / ".macsw-wine-prefix-id").read_text().strip() != old["prefix_id"]:
        raise RuntimeError("备份容器身份不匹配，拒绝恢复。")
    old_contents = Path(old["app"]) / "Contents"
    expected = root / "apps" / fingerprint(old["identity"]) / "MacSW.app/Contents"
    if old_contents != expected or identity(old_contents) != old["identity"]:
        raise RuntimeError("旧 App 身份不匹配，保留备份等待人工恢复。")
    verify_app(old_contents, old["identity"])
    new_contents = Path(journal["new_app"]) / "Contents"
    if new_contents.parent.parent.parent != root / "apps":
        raise RuntimeError("新版 App 归档路径无效。")
    verify_app(new_contents, identity(new_contents))
    stop(new_contents, prefix, log)
    stop(old_contents, prefix, log)
    if journal.get("phase") != "restored":
        if not backup.is_dir():
            raise RuntimeError("缺少原容器备份，拒绝恢复。")
        failed = backup.parent / "failed-bottle"
        # Make restoration idempotent after interruption between the renames.
        if prefix.exists():
            if failed.exists():
                failed = backup.parent / ("interrupted-restore-" + str(uuid.uuid4()))
            prefix.rename(failed)
        if not prefix.exists():
            clone(backup, prefix)
        journal["phase"] = "restored"
        write_json(root / "pending.json", journal)
    # Builtin DLL links and Mono RuntimePath may refer to the overwritten App.
    # Rebind them to the archived old App before declaring recovery complete.
    if not (prefix / "drive_c").is_dir() or (prefix / ".macsw-wine-prefix-id").read_text().strip() != old["prefix_id"]:
        raise RuntimeError("已恢复容器的身份不匹配，保留备份等待恢复。")
    boot(old_contents, prefix, log)
    stop(old_contents, prefix, log)
    write_json(root / "receipt.json", {**old, "active_app": str(old_contents.parent.resolve())})
    (root / "pending.json").unlink()
    return old["app"]


def migrate(contents, prefix):
    with launch_lock(prefix, exclusive=True) as root:
        if status(contents, prefix) == "ready":
            print("Wine/Mono 未变化，无需迁移。")
            return
        if status(contents, prefix) != "upgrade":
            raise RuntimeError("请先记录已知可用版本，或恢复未完成的迁移。")
        old = read_json(root / "receipt.json")
        old_contents = Path(old["app"]) / "Contents"
        if (old_contents != root / "apps" / fingerprint(old["identity"]) / "MacSW.app/Contents"
                or identity(old_contents) != old["identity"]):
            raise RuntimeError("旧 App 归档路径无效。")
        verify_app(old_contents, old["identity"])
        values = identity(contents)
        verify_app(contents, values)
        new_app = archive(contents, root, values)
        log = root / "migration.log"
        print("正在停止选定容器并建立 APFS 完整备份…", flush=True)
        stop(old_contents, prefix, log)
        backup = root / "backups" / str(uuid.uuid4()) / "bottle"
        clone(prefix, backup)
        journal = {"format": 1, "previous": old, "backup": str(backup),
                   "new_app": str(new_app), "new_identity": values, "phase": "upgrading"}
        write_json(root / "pending.json", journal)
        try:
            print("正在更新 Wine、Mono 和 COM 注册工具并检查依赖…", flush=True)
            boot(contents, prefix, log)
            stop(contents, prefix, log)
            write_json(root / "last-upgrade.json", journal)
            write_json(root / "receipt.json", {**old, "identity": values, "app": str(new_app),
                                               "active_app": str(contents.parent.resolve())})
            (root / "pending.json").unlink()
            print(f"迁移及依赖检查完成；请启动 SOLIDWORKS 验收。备份：{backup}", flush=True)
        except Exception as error:
            try:
                app = restore(root, prefix, log)
            except Exception as recovery_error:
                raise RuntimeError(f"迁移失败：{error}；恢复未完成：{recovery_error}；备份：{backup}") from error
            raise RuntimeError(f"迁移失败，已恢复旧容器。请退出新版并打开：{app}。日志：{log}") from error


def rollback(prefix):
    with launch_lock(prefix, exclusive=True) as root:
        if (root / "pending.json").exists():
            raise RuntimeError("存在未完成的迁移，请先恢复。")
        journal = read_json(root / "last-upgrade.json")
        receipt = read_json(root / "receipt.json")
        marker = (prefix / ".macsw-wine-prefix-id").read_text().strip()
        if (receipt["identity"] != journal["new_identity"] or marker != receipt["prefix_id"]
                or journal["previous"]["prefix_id"] != receipt["prefix_id"]):
            raise RuntimeError("回退记录与当前容器不匹配，拒绝恢复。")
        write_json(root / "pending.json", {**journal, "phase": "upgrading"})
        app = restore(root, prefix, root / "migration.log")
        print("已恢复升级前的容器；请退出新版并打开：" + app, flush=True)


def shutdown(contents, prefix):
    with launch_lock(prefix, exclusive=True) as root:
        if (root / "receipt.json").exists():
            receipt = read_json(root / "receipt.json")
            contents = root / "apps" / fingerprint(receipt["identity"]) / "MacSW.app/Contents"
            verify_app(contents, receipt["identity"])
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
            rollback(prefix)
        elif args.command == "stop":
            shutdown(contents, prefix)
        elif args.command == "recover":
            with launch_lock(prefix, exclusive=True) as root:
                print("已恢复旧容器，请退出新版并打开：" + restore(root, prefix, root / "migration.log"))
        else:
            return launch(contents, prefix, command[1:] if command[:1] == ["--"] else command)
    except Exception as error:
        print(str(error), file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
