
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

class TestSubclassRemote {
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

    static void Main() {
        Process[] procs = Process.GetProcessesByName("SLDWORKS");
        if (procs.Length == 0) return;
        IntPtr hProc = OpenProcess(0x1F0FFF, false, procs[0].Id);

        IntPtr hUser32 = GetModuleHandle("user32.dll");
        IntPtr pSetWindowLongPtr = GetProcAddress(hUser32, "SetWindowLongPtrW");
        if (pSetWindowLongPtr == IntPtr.Zero) pSetWindowLongPtr = GetProcAddress(hUser32, "SetWindowLongW");
        Console.WriteLine($"pSetWindowLongPtr: 0x{pSetWindowLongPtr.ToInt64():X}");

        IntPtr hWndDoc = new IntPtr(0x100DD0);
        IntPtr dummyNewProc = (IntPtr)0xFDAB97B0; // Set to same proc for test

        // Assembly:
        // sub rsp, 0x28
        // mov rcx, hWndDoc (48 B9 ...)
        // mov edx, -4      (BA FC FF FF FF)
        // mov r8, dummyNewProc (49 B8 ...)
        // mov rax, pSetWindowLongPtr (48 B8 ...)
        // call rax        (FF D0)
        // add rsp, 0x28    (48 83 C4 28)
        // ret             (C3)
        byte[] stub = new byte[] {
            0x48, 0x83, 0xEC, 0x28,
            0x48, 0xB9, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xBA, 0xFC, 0xFF, 0xFF, 0xFF,
            0x49, 0xB8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x48, 0xB8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0xFF, 0xD0,
            0x48, 0x83, 0xC4, 0x28,
            0xC3
        };
        Buffer.BlockCopy(BitConverter.GetBytes(hWndDoc.ToInt64()), 0, stub, 6, 8);
        Buffer.BlockCopy(BitConverter.GetBytes(dummyNewProc.ToInt64()), 0, stub, 21, 8);
        Buffer.BlockCopy(BitConverter.GetBytes(pSetWindowLongPtr.ToInt64()), 0, stub, 31, 8);

        IntPtr pMem = VirtualAllocEx(hProc, IntPtr.Zero, (UIntPtr)0x1000, 0x3000, 0x40);
        int written;
        WriteProcessMemory(hProc, pMem, stub, stub.Length, out written);

        uint tid;
        IntPtr hThread = CreateRemoteThread(hProc, IntPtr.Zero, UIntPtr.Zero, pMem, IntPtr.Zero, 0, out tid);
        WaitForSingleObject(hThread, 5000);
        IntPtr exitCode;
        GetExitCodeThread(hThread, out exitCode);
        Console.WriteLine($"SetWindowLongPtr(GWLP_WNDPROC) returned oldProc: 0x{exitCode.ToInt64():X}");

        CloseHandle(hThread);
        CloseHandle(hProc);
    }
}
