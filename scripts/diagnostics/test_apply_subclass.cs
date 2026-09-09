using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

class TestApplySubclass {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr lpAddress, UIntPtr dwSize, uint flAllocationType, uint flProtect);
    [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int nSize, out int lpNumberOfBytesWritten);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int nSize, out int lpNumberOfBytesRead);
    [DllImport("kernel32.dll")] static extern IntPtr CreateRemoteThread(IntPtr hProcess, IntPtr lpThreadAttributes, UIntPtr dwStackSize, IntPtr lpStartAddress, IntPtr lpParameter, uint dwCreationFlags, out uint lpThreadId);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeThread(IntPtr hThread, out IntPtr lpExitCode);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr hObject);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr hModule, string procName);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string lpModuleName);
    [DllImport("user32.dll")] static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);

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
            Console.WriteLine("SLDWORKS not found!");
            return;
        }
        int pid = procs[0].Id;
        Console.WriteLine($"Target PID: {pid}");

        IntPtr hProc = OpenProcess(PROCESS_ALL_ACCESS, false, pid);
        if (hProc == IntPtr.Zero) {
            Console.WriteLine("OpenProcess failed!");
            return;
        }

        IntPtr hUser32 = GetModuleHandle("user32.dll");
        IntPtr hGdi32 = GetModuleHandle("gdi32.dll");

        IntPtr pCallWindowProcW = GetProcAddress(hUser32, "CallWindowProcW");
        IntPtr pGetWindowDC = GetProcAddress(hUser32, "GetWindowDC");
        IntPtr pReleaseDC = GetProcAddress(hUser32, "ReleaseDC");
        IntPtr pGetWindowRect = GetProcAddress(hUser32, "GetWindowRect");
        IntPtr pSetDIBitsToDevice = GetProcAddress(hGdi32, "SetDIBitsToDevice");
        IntPtr pSetWindowLongPtrW = GetProcAddress(hUser32, "SetWindowLongPtrW");
        if (pSetWindowLongPtrW == IntPtr.Zero) pSetWindowLongPtrW = GetProcAddress(hUser32, "SetWindowLongW");

        Console.WriteLine($"CallWindowProcW:   0x{pCallWindowProcW.ToInt64():X}");
        Console.WriteLine($"GetWindowDC:       0x{pGetWindowDC.ToInt64():X}");
        Console.WriteLine($"ReleaseDC:         0x{pReleaseDC.ToInt64():X}");
        Console.WriteLine($"GetWindowRect:     0x{pGetWindowRect.ToInt64():X}");
        Console.WriteLine($"SetDIBitsToDevice: 0x{pSetDIBitsToDevice.ToInt64():X}");
        Console.WriteLine($"SetWindowLongPtrW: 0x{pSetWindowLongPtrW.ToInt64():X}");

        IntPtr hWndDoc = new IntPtr(0x100DD0);

        // Allocate 64KB in SLDWORKS
        IntPtr pRemote = VirtualAllocEx(hProc, IntPtr.Zero, (UIntPtr)0x10000, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
        Console.WriteLine($"Allocated remote memory: 0x{pRemote.ToInt64():X}");

        IntPtr pData = new IntPtr(pRemote.ToInt64() + 0x0000);
        IntPtr pThunk = new IntPtr(pRemote.ToInt64() + 0x9000);
        IntPtr pInstaller = new IntPtr(pRemote.ToInt64() + 0x9100);
        IntPtr pCode = new IntPtr(pRemote.ToInt64() + 0x9200);

        // 1. Data Buffer (0x0000):
        // 0x00: fn_CallWindowProcW (8)
        // 0x08: fn_GetWindowDC (8)
        // 0x10: fn_ReleaseDC (8)
        // 0x18: fn_GetWindowRect (8)
        // 0x20: fn_SetDIBitsToDevice (8)
        // 0x28: fn_SetWindowLongPtrW (8)
        // 0x30: hWnd (8)
        // 0x38: origWndProc (8)
        // 0x40: hoverBtn (4)
        // 0x44: pressedBtn (4)
        // 0x48: pixels[128*64] (32768)
        byte[] dataBuf = new byte[0x8200];
        Buffer.BlockCopy(BitConverter.GetBytes(pCallWindowProcW.ToInt64()), 0, dataBuf, 0x00, 8);
        Buffer.BlockCopy(BitConverter.GetBytes(pGetWindowDC.ToInt64()), 0, dataBuf, 0x08, 8);
        Buffer.BlockCopy(BitConverter.GetBytes(pReleaseDC.ToInt64()), 0, dataBuf, 0x10, 8);
        Buffer.BlockCopy(BitConverter.GetBytes(pGetWindowRect.ToInt64()), 0, dataBuf, 0x18, 8);
        Buffer.BlockCopy(BitConverter.GetBytes(pSetDIBitsToDevice.ToInt64()), 0, dataBuf, 0x20, 8);
        Buffer.BlockCopy(BitConverter.GetBytes(pSetWindowLongPtrW.ToInt64()), 0, dataBuf, 0x28, 8);
        Buffer.BlockCopy(BitConverter.GetBytes(hWndDoc.ToInt64()), 0, dataBuf, 0x30, 8);

        // 2. Thunk Stub (45 bytes at 0x9000):
        byte[] thunkBytes = new byte[] {
            0x48, 0x83, 0xEC, 0x38,                         // sub rsp, 0x38
            0x4C, 0x89, 0x4C, 0x24, 0x20,                   // mov [rsp+0x20], r9 (lParam)
            0x4D, 0x89, 0xC1,                               // mov r9, r8         (wParam)
            0x49, 0x89, 0xD0,                               // mov r8, rdx        (uMsg)
            0x48, 0x89, 0xCA,                               // mov rdx, rcx       (hWnd)
            0x48, 0xB9, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // mov rcx, pData
            0x48, 0xB8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // mov rax, pCode
            0xFF, 0xD0,                                     // call rax
            0x48, 0x83, 0xC4, 0x38,                         // add rsp, 0x38
            0xC3                                            // ret
        };
        Buffer.BlockCopy(BitConverter.GetBytes(pData.ToInt64()), 0, thunkBytes, 18, 8);
        Buffer.BlockCopy(BitConverter.GetBytes(pCode.ToInt64()), 0, thunkBytes, 28, 8);

        // 3. Installer Stub (40 bytes at 0x9100):
        // rcx = pData
        byte[] instBytes = new byte[] {
            0x48, 0x83, 0xEC, 0x28,                         // sub rsp, 0x28
            0x48, 0x89, 0xCB,                               // mov rbx, rcx
            0x48, 0x8B, 0x4B, 0x30,                         // mov rcx, [rbx + 0x30] (hWnd)
            0xBA, 0xFC, 0xFF, 0xFF, 0xFF,                   // mov edx, -4 (GWLP_WNDPROC)
            0x49, 0xB8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // mov r8, pThunk
            0x48, 0x8B, 0x43, 0x28,                         // mov rax, [rbx + 0x28] (pSetWindowLongPtrW)
            0xFF, 0xD0,                                     // call rax
            0x48, 0x89, 0x43, 0x38,                         // mov [rbx + 0x38], rax (data->origWndProc)
            0x48, 0x83, 0xC4, 0x28,                         // add rsp, 0x28
            0xC3                                            // ret
        };
        Buffer.BlockCopy(BitConverter.GetBytes(pThunk.ToInt64()), 0, instBytes, 16, 8);

        // 4. Code Blob from file
        string binPath = @"Z:\Volumes\Data\Workspace\WineSW\scratch\sw_aero_subclass.bin";
        byte[] codeBytes = File.ReadAllBytes(binPath);
        Console.WriteLine($"Loaded code blob: {codeBytes.Length} bytes");

        // Write memory
        int written;
        WriteProcessMemory(hProc, pData, dataBuf, dataBuf.Length, out written);
        WriteProcessMemory(hProc, pThunk, thunkBytes, thunkBytes.Length, out written);
        WriteProcessMemory(hProc, pInstaller, instBytes, instBytes.Length, out written);
        WriteProcessMemory(hProc, pCode, codeBytes, codeBytes.Length, out written);

        Console.WriteLine("Memory blocks written. Running installer thread...");

        uint tid;
        IntPtr hThread = CreateRemoteThread(hProc, IntPtr.Zero, UIntPtr.Zero, pInstaller, pData, 0, out tid);
        if (hThread == IntPtr.Zero) {
            Console.WriteLine("CreateRemoteThread failed!");
            return;
        }

        WaitForSingleObject(hThread, 5000);
        IntPtr exitCode;
        GetExitCodeThread(hThread, out exitCode);
        Console.WriteLine($"Installer finished, thread exit code: 0x{exitCode.ToInt64():X}");
        CloseHandle(hThread);

        // Read back data->origWndProc
        byte[] readBack = new byte[8];
        int readBytes;
        ReadProcessMemory(hProc, new IntPtr(pData.ToInt64() + 0x38), readBack, 8, out readBytes);
        long origProc = BitConverter.ToInt64(readBack, 0);
        Console.WriteLine($"Captured origWndProc: 0x{origProc:X}");

        // Redraw window frame
        RedrawWindow(hWndDoc, IntPtr.Zero, IntPtr.Zero, RDW_FRAME | RDW_INVALIDATE | RDW_UPDATENOW);
        Console.WriteLine("RedrawWindow triggered!");

        CloseHandle(hProc);
    }
}
