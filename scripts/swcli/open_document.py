"""Finder-only COM bridge. Attach strictly; never create, save, or close a host."""

import json
import ntpath
import os
import sys
import time

DOCUMENT_TYPES = {".sldprt": 1, ".sldasm": 2, ".slddrw": 3}


def com_value(obj, name):
    # pywin32's dynamic dispatch exposes some no-argument COM getters as
    # properties, depending on which type information Wine supplied.
    value = getattr(obj, name)
    return value() if callable(value) else value


def attach(get_active, timeout=120, *, clock=time.monotonic, sleep=time.sleep):
    deadline = clock() + timeout
    while True:
        try:
            return get_active("SldWorks.Application")
        except Exception as error:
            if clock() >= deadline:
                raise RuntimeError("SOLIDWORKS 尚未就绪，未创建第二个实例；请检查启动或许可提示后重试。") from error
            sleep(0.5)


def open_document(app, path, byref):
    kind = DOCUMENT_TYPES.get(ntpath.splitext(path)[1].lower())
    if kind is None:
        raise ValueError("不支持的 SOLIDWORKS 文件类型。")
    app.Visible = True
    app.UserControl = True
    document = app.GetOpenDocumentByName(path)
    reused = document is not None
    errors, warnings = byref(), byref()
    if document is None:
        # Interactive open: preserve SOLIDWORKS' normal file/reference dialogs.
        document = app.OpenDoc6(path, kind, 0, "", errors, warnings)
        if document is None:
            raise RuntimeError(f"SOLIDWORKS 无法打开文件（错误 {errors.value}，警告 {warnings.value}）。")
    activation = byref()
    active = app.ActivateDoc3(com_value(document, "GetTitle"), False, 1, activation)
    if active is None or not os.path.samefile(com_value(active, "GetPathName"), path):
        raise RuntimeError(f"文档已打开，但未能确认激活了目标文件（状态 {activation.value}）；请在 SW 中检查。")
    return {"success": True, "reused": reused, "api_warnings": int(warnings.value)}


def main(path, output):
    # pythonw has no console streams. Some pywin32 diagnostics still write to
    # them; do not let that turn an otherwise valid import into an exception.
    if sys.stdout is None:
        sys.stdout = open(os.devnull, "w")
    if sys.stderr is None:
        sys.stderr = open(os.devnull, "w")
    initialized = False
    try:
        import pythoncom
        import win32com.client

        pythoncom.CoInitialize()
        initialized = True
        app = attach(win32com.client.GetActiveObject)
        result = open_document(app, path, lambda: win32com.client.VARIANT(
            pythoncom.VT_BYREF | pythoncom.VT_I4, 0))
    except Exception as error:
        result = {"success": False, "message": str(error)}
    finally:
        if initialized:
            pythoncom.CoUninitialize()
    with open(output, "w", encoding="utf-8") as stream:
        json.dump(result, stream, ensure_ascii=False)
    return 0 if result["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main(*sys.argv[1:]))
