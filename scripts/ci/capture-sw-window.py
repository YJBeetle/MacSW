"""Capture a selected SW window locally, or the primary desktop on hosted CI.

Caller verifies daemon ownership. This helper returns numeric window identity
and a hashed PNG receipt; no window titles or command lines are logged. Desktop
capture is explicitly restricted to disposable GitHub-hosted runners.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess


def choose_window(windows, pid):
    candidates = [w for w in windows if w["pid"] == pid and w["layer"] == 0
                  and w["width"] >= 250 and w["height"] >= 150 and w["id"] > 0]
    return candidates[0] if candidates else None


def visible_windows():
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    ptr = ctypes.c_void_p
    cf.CFStringCreateWithCString.argtypes = [ptr, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFStringCreateWithCString.restype = ptr
    cf.CFArrayGetCount.argtypes = [ptr]
    cf.CFArrayGetCount.restype = ctypes.c_long
    cf.CFArrayGetValueAtIndex.argtypes = [ptr, ctypes.c_long]
    cf.CFArrayGetValueAtIndex.restype = ptr
    cf.CFDictionaryGetValue.argtypes = [ptr, ptr]
    cf.CFDictionaryGetValue.restype = ptr
    cf.CFNumberGetValue.argtypes = [ptr, ctypes.c_int, ptr]
    cf.CFNumberGetValue.restype = ctypes.c_bool
    cf.CFRelease.argtypes = [ptr]
    cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    cg.CGWindowListCopyWindowInfo.restype = ptr
    keys = {name: cf.CFStringCreateWithCString(None, name.encode(), 0x08000100)
            for name in ("kCGWindowOwnerPID", "kCGWindowNumber", "kCGWindowLayer",
                         "kCGWindowBounds", "Width", "Height")}
    windows = cg.CGWindowListCopyWindowInfo(1, 0)  # on-screen, front-to-back
    try:
        def value(dictionary, name, floating=False):
            number = cf.CFDictionaryGetValue(dictionary, keys[name])
            result = ctypes.c_double() if floating else ctypes.c_longlong()
            if not number or not cf.CFNumberGetValue(number, 13 if floating else 4,
                                                    ctypes.byref(result)):
                raise ValueError("Missing numeric window metadata")
            return result.value
        output = []
        for i in range(cf.CFArrayGetCount(windows) if windows else 0):
            window = cf.CFArrayGetValueAtIndex(windows, i)
            bounds = cf.CFDictionaryGetValue(window, keys["kCGWindowBounds"])
            if not bounds:
                continue
            output.append({"pid": value(window, "kCGWindowOwnerPID"),
                           "id": value(window, "kCGWindowNumber"),
                           "layer": value(window, "kCGWindowLayer"),
                           "width": value(bounds, "Width", True),
                           "height": value(bounds, "Height", True)})
        return output
    finally:
        if windows:
            cf.CFRelease(windows)
        for key in keys.values():
            if key:
                cf.CFRelease(key)


def capture(pid, path, scope="window"):
    if type(pid) is not int or pid < 0 or path.exists() or path.is_symlink():
        raise ValueError("Invalid PID or nonempty screenshot target")
    if path.with_suffix(".json").exists() or path.with_suffix(".json").is_symlink():
        raise ValueError("Nonempty screenshot receipt target")
    if scope not in ("window", "desktop"):
        raise ValueError("Unknown screenshot scope")
    if scope == "desktop" and not (os.environ.get("GITHUB_ACTIONS") == "true"
                                    and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted"):
        raise ValueError("Desktop capture requires a GitHub-hosted CI runner")
    window = None
    if scope == "window":
        if pid <= 0:
            raise ValueError("Window capture requires an owner PID")
        window = choose_window(visible_windows(), pid)
        if window is None:
            return {"success": False, "reason": "owned-visible-window-unavailable", "unix_pid": pid}
    arguments = ["/usr/sbin/screencapture", "-x", "-o"]
    # Hosted runners have one virtual display; select it explicitly so multiple
    # displays cannot produce unreceipted sibling PNGs. Never use desktop locally.
    arguments += ["-D", "1"] if scope == "desktop" else ["-l", str(window["id"])]
    try:
        result = subprocess.run([*arguments, str(path)], capture_output=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        if path.is_file() and not path.is_symlink():
            path.unlink()
        raise
    receipt = {"source": "github-hosted-desktop" if scope == "desktop" else "owned-sw-window",
               "file": path.name, "exit_code": result.returncode}
    if scope == "desktop":
        receipt.update(display_id=1)
    else:
        receipt.update(unix_pid=pid, window_id=window["id"])
    if result.returncode or not path.is_file():
        if path.is_file():
            path.unlink()  # Only this invocation's partial capture.
        receipt.update(success=False, reason="capture-tool-failed")
        return receipt
    data = path.read_bytes()
    if len(data) < 24 or len(data) > 25 * 1024 * 1024 or data[:8] != b"\x89PNG\r\n\x1a\n":
        path.unlink()
        raise ValueError("Invalid or oversized screenshot PNG")
    width, height = struct.unpack(">II", data[16:24])
    if not 1 <= width <= 16384 or not 1 <= height <= 16384:
        path.unlink()
        raise ValueError("Invalid screenshot dimensions")
    receipt.update(success=True, size_bytes=len(data), width=width, height=height,
                   sha256=hashlib.sha256(data).hexdigest())
    try:
        with path.with_suffix(".json").open("x") as stream:
            stream.write(json.dumps(receipt, indent=2) + "\n")
    except OSError:
        path.unlink()
        raise
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, default=0)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scope", choices=("window", "desktop"), default="window")
    args = parser.parse_args()
    try:
        record = capture(args.pid, args.output, args.scope)
    except Exception as error:
        record = {"success": False, "diagnostic_error": type(error).__name__}
    print(json.dumps(record))
