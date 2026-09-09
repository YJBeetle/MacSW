
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

class TestPatchProbe {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int nSize, out int lpNumberOfBytesRead);
    [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int nSize, out int lpNumberOfBytesWritten);
    [DllImport("kernel32.dll")] static extern bool VirtualProtectEx(IntPtr hProcess, IntPtr lpAddress, UIntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr hObject);

    static void Main() {
        Process[] procs = Process.GetProcessesByName("SLDWORKS");
        if (procs.Length == 0) return;
        IntPtr hProc = OpenProcess(0x1F0FFF, false, procs[0].Id);
        IntPtr func = new IntPtr(0x2095ae000 + 0x21c70);

        byte[] orig = new byte[16];
        int read;
        bool readOk = ReadProcessMemory(hProc, func, orig, orig.Length, out read);
        Console.WriteLine($"Read: {readOk}, bytes={BitConverter.ToString(orig)}");

        uint oldProt;
        bool vpOk = VirtualProtectEx(hProc, func, (UIntPtr)orig.Length, 0x40 /* PAGE_EXECUTE_READWRITE */, out oldProt);
        Console.WriteLine($"VirtualProtectEx: {vpOk}, oldProt=0x{oldProt:X}");

        int written;
        bool writeOk = WriteProcessMemory(hProc, func, orig, orig.Length, out written);
        Console.WriteLine($"WriteProcessMemory (same bytes): {writeOk}, written={written}");

        uint dummy;
        VirtualProtectEx(hProc, func, (UIntPtr)orig.Length, oldProt, out dummy);
        CloseHandle(hProc);
    }
}
