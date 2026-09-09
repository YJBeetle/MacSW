
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

class TestQueryMem {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int nSize, out int lpNumberOfBytesRead);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr hObject);

    static void Main() {
        Process[] procs = Process.GetProcessesByName("SLDWORKS");
        if (procs.Length == 0) return;
        IntPtr hProc = OpenProcess(0x1F0FFF, false, procs[0].Id);
        IntPtr func = new IntPtr(0x2095ae000 + 0x21c70);
        byte[] buf = new byte[20];
        int read;
        bool ok = ReadProcessMemory(hProc, func, buf, buf.Length, out read);
        Console.WriteLine($"Read func 0x{func.ToInt64():X}: ok={ok}, read={read}");
        if (ok) {
            Console.WriteLine("Bytes: " + BitConverter.ToString(buf));
        }
        CloseHandle(hProc);
    }
}
