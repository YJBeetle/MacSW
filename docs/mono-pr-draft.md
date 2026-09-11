# PR draft — not submitted

Proposed repository: `wine-mono/mono` (the runtime, not the packaging repository).

## Title

[interp] Honor stdcall in the x86 Windows fast native call path

## Body

### Summary

The interpreter's fast native call path invokes function pointers using C
calling-convention typedefs. On x86 Windows, a stdcall callee removes its
arguments from the stack, but the C call site also adjusts the stack. This
can corrupt the caller's stack and cause a native crash.

This was initially investigated under Wine on macOS/Apple Silicon, then
reproduced independently under Wine on x86_64 Linux, without Rosetta or any
commercial application. The scope is the Windows x86 interpreter ABI path;
this is not a claim that every Mono platform is affected.

### Discovery context: SOLIDWORKS installation

The issue was discovered while running the SOLIDWORKS 2025 SP05 Windows
installer under Wine on macOS/Apple Silicon. The installer invokes a
32-bit managed Toolbox database utility, so a 64-bit product installation
can still exercise the x86 Mono runtime.

The MSI log shows the following sequence inside its `UpdateBrowserData`
custom action:

1. Read the application/data directories from `CustomActionData`, determine
   the language-specific Toolbox database directory, and check whether it
   is writable and the database is not locked.
2. Launch `DatabaseConverter.exe` with the path to `SWBrowser.mdb` and wait
   synchronously for the child process to finish.
3. Launch `UpdateBrowserDatabase.exe` with the target `.sldedb`, update
   database and template database paths, again waiting for completion.
4. Return from the custom action so the MSI sequence can continue.

For example, the first child command was:

```text
"C:\Program Files\SOLIDWORKS\toolbox\data utilities\DatabaseConverter.exe"
    "C:\SOLIDWORKS Data\lang\english\SWBrowser.mdb"
```

Because this is a synchronous child-process operation, the installer can
appear stuck while the helper is hung or its crash debugger remains open.
This is not evidence that the entire MSI installer is managed code.

On the original macOS setup, x86 JIT startup exhibited a separate hang.
Selecting Wine-Mono's interpreter allowed managed execution to proceed,
but exposed a crash in the WinForms activation-context initialization path:

```text
Application.EnableVisualStyles
  -> ThemingScope.CreateActivationContext
  -> CreateActCtx / CreateActCtxW
  -> interpreter native call
```

The WinForms initialization failure was reproduced without any database
access, and then reduced further to the standalone native-call reproducer
below. The Linux reproduction does not require SOLIDWORKS, its installer,
or its data files.

After the runtime correction, the observed installer log recorded both
database helper processes exiting `0x0` and `UpdateBrowserData` ending with
MSI `Return value 1` (action success). A subsequent installation reached
`SetupCompleteSuccess`. This is application-level corroboration, not a
claim that all database contents, managed COM registration, or SOLIDWORKS
features have been validated. The independent regression test is the
primary evidence for this runtime fix.

### Implementation

- Add stdcall dispatch for the simple signatures already supported by the
  fast native call path, guarded by `HOST_WIN32 && TARGET_X86`.
- Resolve default Winapi signatures for external P/Invoke wrappers without
  globally treating internal default C signatures as stdcall.
- Keep normalized signature copies alive after interpreter transformation:
  they are stored in runtime `data_items`, so a transform-local allocation
  would be invalid after the transform pool is destroyed.
- Preserve the shared last-error and return-value conversion handling.
- Add `test_0_native_pointer_call_conventions` to `pinvoke2.cs` and matching
  native functions to `libtest.c`. The test interleaves cdecl, explicit
  stdcall, and default Winapi pointer calls 256 times.

The signature-lifetime issue was introduced during development of this
patch, not found in the unmodified release; it is not a separate upstream bug.

### Minimal standalone reproducer

Save as `NativeBridge.c`:

```c
#include <windows.h>

__declspec(dllexport) HANDLE __cdecl bridge_cdecl(void *context)
{
    return CreateActCtxW((PCACTCTXW)context);
}

__declspec(dllexport) HANDLE __stdcall bridge_stdcall(void *context)
{
    return CreateActCtxW((PCACTCTXW)context);
}
```

Save as `NativeBridgeProbe.cs`:

```csharp
using System;
using System.Runtime.InteropServices;

class NativeBridgeProbe
{
    [DllImport("NativeBridge.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr bridge_cdecl(IntPtr context);

    [DllImport("NativeBridge.dll", CallingConvention = CallingConvention.StdCall)]
    static extern IntPtr bridge_stdcall(IntPtr context);

    static void Main(string[] args)
    {
        bool stdcall = args.Length > 0 && args[0] == "stdcall";
        Console.WriteLine("Bridge=" + (stdcall ? "stdcall" : "cdecl"));
        Console.Out.Flush();
        IntPtr value = stdcall ? bridge_stdcall(IntPtr.Zero) : bridge_cdecl(IntPtr.Zero);
        Console.WriteLine("RESULT=" + value);
    }
}
```

Both native wrappers call the same API with the same invalid input and
should return `INVALID_HANDLE_VALUE` (`-1`). This intentionally tests the
call boundary; it does not require an activation-context manifest.

On Debian/Ubuntu with Wine's i386 support, MinGW-w64, Mono's C# compiler,
Xvfb, xauth, curl and xz installed:

```sh
i686-w64-mingw32-gcc -shared -O2 -Wl,--kill-at \
    -o NativeBridge.dll NativeBridge.c
mcs -platform:x86 -out:NativeBridgeProbe.exe NativeBridgeProbe.cs
```

These commands compile only the reproducer, not Mono. The original local
bridge matrix used the same C# source compiled with Wine-Mono's `csc`; the
upstream CI regression described below is compiled with `mcs`.

Download the official runtime and the tested candidate DLL into a new work
directory containing the two compiled reproducer files:

```sh
curl -fL https://github.com/wine-mono/wine-mono/releases/download/wine-mono-11.3.0/wine-mono-11.3.0-x86.tar.xz \
    -o runtime.tar.xz
mkdir runtime
tar -xf runtime.tar.xz -C runtime
curl -fL https://github.com/YJBeetle/wine-mono/releases/download/macsw-mono-11.3.0-v4/libmono-2.0-x86.dll \
    -o candidate-x86.dll
echo '1541b5f189664e7f3d09d7e5ee5c3ae9e1c19534b79e8331fb9a51f9c1c21562  candidate-x86.dll' | sha256sum -c -
```

Save as `reproduce.sh`, then run `xvfb-run -a bash reproduce.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
export WINEPREFIX="$PWD/repro-prefix"
export WINEDEBUG=-all
mkdir -p logs
runtime=$(dirname "$(dirname "$(find "$PWD/runtime" -name libmono-2.0-x86.dll -print -quit)")")
test -f "$runtime/lib/mono/4.5/mscorlib.dll"
cp "$runtime/bin/libmono-2.0-x86.dll" baseline-x86.dll
WINEDLLOVERRIDES='mscoree,mshtml=' timeout -k 5 120 wine wineboot -u
wine reg add 'HKCU\Software\Wine\Mono' /v RuntimePath /t REG_SZ \
    /d "$(winepath -w "$runtime")" /f
for variant in baseline candidate; do
    wineserver -k || true
    wineserver -w
    cp "$variant-x86.dll" "$runtime/bin/libmono-2.0-x86.dll"
    sha256sum "$runtime/bin/libmono-2.0-x86.dll"
    for mode in interp none; do
        export WINE_MONO_AOT="$mode"
        for convention in cdecl stdcall; do
            set +e
            timeout -k 5 60 wine "$PWD/NativeBridgeProbe.exe" "$convention" \
                > "logs/$variant-$mode-$convention.log" 2>&1
            result=$?
            set -e
            echo "$variant $mode $convention exit=$result"
            cat "logs/$variant-$mode-$convention.log"
            wineserver -k || true
            wineserver -w
        done
    done
done
```

`WINE_MONO_AOT=none` selects the JIT control. The script's wineserver
operations are scoped by the dedicated `WINEPREFIX`. Use a fresh extraction
for each full run so `baseline-x86.dll` remains the unmodified engine.

### Observed results

Independent host: Debian 13 x86_64, Debian Wine `10.0~repack-6`, amd64/i386
packages, Xvfb, dedicated Wine prefix.

| Engine | Interpreter cdecl | Interpreter stdcall | JIT cdecl | JIT stdcall |
| --- | --- | --- | --- | --- |
| Unmodified 11.3.0 baseline build | Pass | Native crash | Pass | Pass |
| Candidate | Pass | Pass | Pass | Pass |

Successful bridge calls printed `RESULT=-1` and exited 0. The baseline
interpreter reported a page fault executing address `0x028a0080`; the
debugger remained open until the harness timeout (exit 124). Addresses are
run-dependent. The crash report, not the timeout alone, is the evidence.

The Linux bridge baseline was built from the release's pinned Mono commit
`73610cc7350b7b51dd3bde3323a8ae28eaf5f7fc`, with DLL SHA-256
`003255a0ef2a59d47e2052abb883d9925a206a534ee4bcbe8ab8786de5bd3d7b`.
The downloadable candidate above corresponds to runtime commit
`50c8800d806195d7e55813d5cb59fd10b2fb4894`.

### Upstream regression test and CI evidence

The added upstream-style test is committed at
[1b6b7ce575e](https://github.com/YJBeetle/mono/commit/1b6b7ce575ef5eb0aa765a5540c3590d90e95d92).
It does not depend on `CreateActCtxW`: native pointer identity functions
exercise the same ABI boundary without Windows API behavior in the assertion.

CI builds the real `libtest.dll`, compiles `pinvoke2.cs` with the existing
`TestDriver.cs`/`TestHelpers.cs`, and runs:

```sh
wine pinvoke2.exe --run-only native_pointer_call_conventions -v
```

The same test executable, native library and managed class libraries are
used for both engines. The CI negative control uses the unmodified DLL from
the official 11.3.0 archive, rather than the separately built local baseline.

[Full before/after CI run](https://github.com/YJBeetle/wine-mono/actions/runs/34615947382)
([pinned workflow and script](https://github.com/YJBeetle/wine-mono/tree/f2edca421e88f273fcc514c7da810ee3c0522cab/.github)):

```text
baseline interpreter:
  Running 'test_0_native_pointer_call_conventions' ...
  Native Crash Reporting
  wine: Unhandled page fault on execute access to 025802B0
  baseline interp exit=124

baseline JIT:
  Regression tests: 1 ran, 0 failed in Tests
  baseline none exit=0

candidate interpreter:
  Regression tests: 1 ran, 0 failed in Tests
  candidate interp exit=0

candidate JIT:
  Regression tests: 1 ran, 0 failed in Tests
  candidate none exit=0
```

The CI requires the test-start marker and native crash/page-fault evidence
for the baseline interpreter, and an explicit `1 ran, 0 failed` plus exit 0
for the three positive controls. Loader failures and generic timeouts do
not satisfy the negative-control assertion. Logs and engine checksums are
uploaded in the `x86-regression-logs` artifact.

### Scope and limitations

- Reproduced under Wine on both Linux x86_64 and macOS Apple Silicon. Native
  Windows execution has not been tested.
- The new regression covers one pointer argument and a pointer return,
  repeatedly interleaved across calling conventions. It is not exhaustive
  coverage of every supported argument count or marshaling shape.
- This patch does not fix the separate macOS x86 JIT startup hang, add
  arbitrary-signature x86 interpreter P/Invoke support, or establish
  correctness on other architectures.
- Validation is based on the Mono commit pinned by Wine Mono 11.3.0.
  Compatibility with the current upstream target branch must be checked
  before submission.

---

## Local submission checklist (not part of the PR body)

- Await user approval before opening the PR.
- Prepare a clean review branch with the final runtime fix and regression
  test; preserve the experimental branch and CI references.
- Remove incidental end-of-file whitespace changes.
- Inspect the current upstream target diff; rerun CI if adapting code.
- Keep CI infrastructure in the packaging fork, outside the runtime PR.
- The recipe above is assembled from validated steps; execute it verbatim
  in a fresh directory before describing it as a tested copy/paste recipe.
