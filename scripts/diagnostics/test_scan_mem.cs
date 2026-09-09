
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

class TestScanMem {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, int dwProcessId);
    [DllImport("kernel32.dll")] static extern int VirtualQueryEx(IntPtr hProcess, IntPtr lpAddress, out MEMORY_BASIC_INFORMATION lpBuffer, uint dwLength);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr hObject);

    [StructLayout(LayoutKind.Sequential)]
    struct MEMORY_BASIC_INFORMATION {
        public IntPtr BaseAddress;
        public IntPtr AllocationBase;
        public uint AllocationProtect;
        public IntPtr RegionSize;
        public uint State;
        public uint Protect;
        public uint Type;
    }

    static void Main() {
        Process[] procs = Process.GetProcessesByName("SLDWORKS");
        IntPtr hProc = OpenProcess(0x1F0FFF, false, procs[0].Id);
        MEMORY_BASIC_INFORMATION mbi;
        int ret = VirtualQueryEx(hProc, new IntPtr(0x2095ae000L), out mbi, (uint)Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION)));
        Console.WriteLine($"VQ ret={ret}: Base=0x{mbi.BaseAddress.ToInt64():X}, Alloc=0x{mbi.AllocationBase.ToInt64():X}, Size=0x{mbi.RegionSize.ToInt64():X}, State=0x{mbi.State:X}, Protect=0x{mbi.Protect:X}, Type=0x{mbi.Type:X}");
        CloseHandle(hProc);
    }
}
