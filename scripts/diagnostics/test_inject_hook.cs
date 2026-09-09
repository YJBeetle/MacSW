using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

class TestInjectHook {
    [DllImport("kernel32.dll")]
    static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);

    [DllImport("kernel32.dll")]
    static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr lpAddress, UIntPtr dwSize, uint flAllocationType, uint flProtect);

    [DllImport("kernel32.dll")]
    static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int nSize, out int lpNumberOfBytesWritten);

    [DllImport("kernel32.dll")]
    static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int nSize, out int lpNumberOfBytesRead);

    [DllImport("kernel32.dll")]
    static extern bool VirtualProtectEx(IntPtr hProcess, IntPtr lpAddress, UIntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)]
    static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("user32.dll")]
    static extern bool InvalidateRect(IntPtr hWnd, IntPtr lpRect, bool bErase);

    [DllImport("user32.dll")]
    static extern bool UpdateWindow(IntPtr hWnd);

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")]
    static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);

    const int PROCESS_ALL_ACCESS = 0x1F0FFF;
    const uint MEM_COMMIT = 0x1000;
    const uint MEM_RESERVE = 0x2000;
    const uint PAGE_EXECUTE_READWRITE = 0x40;

    const uint RDW_INVALIDATE = 0x0001;
    const uint RDW_ERASE = 0x0004;
    const uint RDW_ALLCHILDREN = 0x0080;
    const uint RDW_UPDATENOW = 0x0100;
    const uint RDW_FRAME = 0x0400;

    static void Main(string[] args) {
        Process[] procs = Process.GetProcessesByName("SLDWORKS");
        if (procs.Length == 0) {
            Console.WriteLine("SLDWORKS process not found!");
            return;
        }

        Process sw = procs[0];
        Console.WriteLine($"Found SLDWORKS PID: {sw.Id}");

        IntPtr hProc = OpenProcess(PROCESS_ALL_ACCESS, false, sw.Id);
        if (hProc == IntPtr.Zero) {
            Console.WriteLine("OpenProcess failed!");
            return;
        }

        IntPtr hUser32 = GetModuleHandle("user32.dll");
        IntPtr hGdi32 = GetModuleHandle("gdi32.dll");

        IntPtr pDrawFrameControl = GetProcAddress(hUser32, "DrawFrameControl");
        IntPtr pSetDIBitsToDevice = GetProcAddress(hGdi32, "SetDIBitsToDevice");

        Console.WriteLine($"DrawFrameControl: 0x{pDrawFrameControl.ToInt64():X}");
        Console.WriteLine($"SetDIBitsToDevice: 0x{pSetDIBitsToDevice.ToInt64():X}");

        if (pDrawFrameControl == IntPtr.Zero || pSetDIBitsToDevice == IntPtr.Zero) {
            Console.WriteLine("Failed to resolve API pointers!");
            return;
        }

        // Read binary blob
        string binPath = @"Z:\Volumes\Data\Workspace\WineSW\scratch\sw_aero_hook.bin";
        byte[] codeBlob = File.ReadAllBytes(binPath);
        Console.WriteLine($"Loaded code blob: {codeBlob.Length} bytes");

        // Allocate 16KB in SLDWORKS
        UIntPtr allocSize = (UIntPtr)0x4000;
        IntPtr pRemote = VirtualAllocEx(hProc, IntPtr.Zero, allocSize, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
        if (pRemote == IntPtr.Zero) {
            Console.WriteLine("VirtualAllocEx failed!");
            return;
        }
        Console.WriteLine($"Allocated remote memory: 0x{pRemote.ToInt64():X}");

        // Offsets
        long offCtx = 0x0000;
        long offStub = 0x2200;
        long offTramp = 0x2300;
        long offCode = 0x2400;

        IntPtr pCtx = new IntPtr(pRemote.ToInt64() + offCtx);
        IntPtr pStub = new IntPtr(pRemote.ToInt64() + offStub);
        IntPtr pTramp = new IntPtr(pRemote.ToInt64() + offTramp);
        IntPtr pCode = new IntPtr(pRemote.ToInt64() + offCode);

        // 1. Construct Context:
        // +0x00: fn_DrawFrameControl_Orig = pTramp
        // +0x08: fn_SetDIBitsToDevice = pSetDIBitsToDevice
        // +0x10: total_calls = 0
        // +0x14: caption_calls = 0
        byte[] ctxBuf = new byte[0x2000];
        Buffer.BlockCopy(BitConverter.GetBytes(pTramp.ToInt64()), 0, ctxBuf, 0x00, 8);
        Buffer.BlockCopy(BitConverter.GetBytes(pSetDIBitsToDevice.ToInt64()), 0, ctxBuf, 0x08, 8);

        // 2. Construct Hook Stub (45 bytes):
        // sub rsp, 40
        // mov [rsp+32], r9
        // mov r9, r8
        // mov r8, rdx
        // mov rdx, rcx
        // mov rcx, pCtx
        // mov rax, pCode
        // call rax
        // add rsp, 40
        // ret
        byte[] stubBytes = new byte[] {
            0x48, 0x83, 0xEC, 0x28,                         // sub rsp, 0x28
            0x4C, 0x89, 0x4C, 0x24, 0x20,                   // mov [rsp+32], r9
            0x4D, 0x89, 0xC1,                               // mov r9, r8
            0x49, 0x89, 0xD0,                               // mov r8, rdx
            0x48, 0x89, 0xCA,                               // mov rdx, rcx
            0x48, 0xB9, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // mov rcx, pCtx
            0x48, 0xB8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // mov rax, pCode
            0xFF, 0xD0,                                     // call rax
            0x48, 0x83, 0xC4, 0x28,                         // add rsp, 0x28
            0xC3                                            // ret
        };
        Buffer.BlockCopy(BitConverter.GetBytes(pCtx.ToInt64()), 0, stubBytes, 18, 8);
        Buffer.BlockCopy(BitConverter.GetBytes(pCode.ToInt64()), 0, stubBytes, 28, 8);

        // 3. Construct Trampoline (32 bytes):
        // Original prologue of DrawFrameControl (19 bytes):
        // 41 57 41 56 41 55 41 54 55 57 56 53 48 81 EC 28 01 00 00
        // Followed by:
        // mov r11, pDrawFrameControl + 19
        // jmp r11
        byte[] trampBytes = new byte[] {
            0x41, 0x57,                                     // push r15
            0x41, 0x56,                                     // push r14
            0x41, 0x55,                                     // push r13
            0x41, 0x54,                                     // push r12
            0x55,                                           // push rbp
            0x57,                                           // push rdi
            0x56,                                           // push rsi
            0x53,                                           // push rbx
            0x48, 0x81, 0xEC, 0x28, 0x01, 0x00, 0x00,       // sub rsp, 0x128
            0x49, 0xBB, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // mov r11, target
            0x41, 0xFF, 0xE3                                // jmp r11
        };
        long trampTarget = pDrawFrameControl.ToInt64() + 19;
        Buffer.BlockCopy(BitConverter.GetBytes(trampTarget), 0, trampBytes, 21, 8);

        // Write all blocks to remote memory
        int written;
        WriteProcessMemory(hProc, pCtx, ctxBuf, ctxBuf.Length, out written);
        WriteProcessMemory(hProc, pStub, stubBytes, stubBytes.Length, out written);
        WriteProcessMemory(hProc, pTramp, trampBytes, trampBytes.Length, out written);
        WriteProcessMemory(hProc, pCode, codeBlob, codeBlob.Length, out written);
        Console.WriteLine("Written context, stub, trampoline, and code blob to remote memory.");

        // 4. Hook DrawFrameControl:
        // Replace first 19 bytes with:
        // FF 25 00 00 00 00 [pStub] (14 bytes) + 5x NOP (90)
        byte[] jmpPatch = new byte[] {
            0xFF, 0x25, 0x00, 0x00, 0x00, 0x00,             // jmp qword ptr [rip+0]
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // pStub
            0x90, 0x90, 0x90, 0x90, 0x90                    // 5 NOPs
        };
        Buffer.BlockCopy(BitConverter.GetBytes(pStub.ToInt64()), 0, jmpPatch, 6, 8);

        uint oldProtect;
        VirtualProtectEx(hProc, pDrawFrameControl, (UIntPtr)jmpPatch.Length, PAGE_EXECUTE_READWRITE, out oldProtect);
        bool ok = WriteProcessMemory(hProc, pDrawFrameControl, jmpPatch, jmpPatch.Length, out written);
        VirtualProtectEx(hProc, pDrawFrameControl, (UIntPtr)jmpPatch.Length, oldProtect, out oldProtect);

        Console.WriteLine($"Hooked DrawFrameControl: success={ok}, written={written}");
        // Invalidate main window and all children to trigger redraw
        Console.WriteLine("Redrawing windows with RDW_FRAME to trigger WM_NCPAINT...");
    uint rdwFlags = RDW_FRAME | RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN | RDW_ERASE;
    RedrawWindow(sw.MainWindowHandle, IntPtr.Zero, IntPtr.Zero, rdwFlags);
    EnumChildWindows(sw.MainWindowHandle, (c, l) => {
        RedrawWindow(c, IntPtr.Zero, IntPtr.Zero, rdwFlags);
        return true;
    }, IntPtr.Zero);

    Thread.Sleep(1000);

        // Read metrics
        byte[] statBuf = new byte[32];
        int read;
        ReadProcessMemory(hProc, new IntPtr(pCtx.ToInt64() + 0x10), statBuf, 32, out read);
        uint totalCalls = BitConverter.ToUInt32(statBuf, 0);
        uint captionCalls = BitConverter.ToUInt32(statBuf, 4);
        uint lastType = BitConverter.ToUInt32(statBuf, 8);
        uint lastState = BitConverter.ToUInt32(statBuf, 12);
        int rL = BitConverter.ToInt32(statBuf, 16);
        int rT = BitConverter.ToInt32(statBuf, 20);
        int rR = BitConverter.ToInt32(statBuf, 24);
        int rB = BitConverter.ToInt32(statBuf, 28);

        Console.WriteLine($"Stats: TotalCalls={totalCalls}, CaptionCalls={captionCalls}, LastState=0x{lastState:X}, LastRect=({rL},{rT},{rR},{rB})");
    }
}
