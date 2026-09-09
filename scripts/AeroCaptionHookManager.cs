using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace WineSW.Daemon {
    public static class AeroCaptionHookManager {
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(int dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr lpAddress, UIntPtr dwSize, uint flAllocationType, uint flProtect);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int nSize, out int lpNumberOfBytesWritten);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool ReadProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, int nSize, out int lpNumberOfBytesRead);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool VirtualProtectEx(IntPtr hProcess, IntPtr lpAddress, UIntPtr dwSize, uint flNewProtect, out uint lpflOldProtect);

        [DllImport("kernel32.dll", CharSet = CharSet.Ansi, SetLastError = true)]
        static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr GetModuleHandle(string lpModuleName);

        [DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr hObject);

        const int PROCESS_ALL_ACCESS = 0x1F0FFF;
        const uint MEM_COMMIT = 0x1000;
        const uint MEM_RESERVE = 0x2000;
        const uint PAGE_EXECUTE_READWRITE = 0x40;

        private static uint _lastHookedPid = 0;
        private static IntPtr _pStub = IntPtr.Zero;
        private static IntPtr _pCtx = IntPtr.Zero;

        public static bool EnsureHooked(uint targetPid) {
            if (targetPid == 0) return false;

            IntPtr hUser32 = GetModuleHandle("user32.dll");
            IntPtr hGdi32 = GetModuleHandle("gdi32.dll");
            if (hUser32 == IntPtr.Zero || hGdi32 == IntPtr.Zero) return false;

            IntPtr pDrawFrameControl = GetProcAddress(hUser32, "DrawFrameControl");
            IntPtr pSetDIBitsToDevice = GetProcAddress(hGdi32, "SetDIBitsToDevice");
            if (pDrawFrameControl == IntPtr.Zero || pSetDIBitsToDevice == IntPtr.Zero) return false;

            IntPtr hProc = OpenProcess(PROCESS_ALL_ACCESS, false, targetPid);
            if (hProc == IntPtr.Zero) return false;

            try {
                // Check if already hooked
                if (_lastHookedPid == targetPid && _pStub != IntPtr.Zero) {
                    byte[] curPrologue = new byte[19];
                    int bytesRead;
                    if (ReadProcessMemory(hProc, pDrawFrameControl, curPrologue, curPrologue.Length, out bytesRead) && bytesRead == 19) {
                        // Check for FF 25 00 00 00 00 followed by _pStub
                        if (curPrologue[0] == 0xFF && curPrologue[1] == 0x25 &&
                            curPrologue[2] == 0x00 && curPrologue[3] == 0x00 &&
                            curPrologue[4] == 0x00 && curPrologue[5] == 0x00) {
                            long targetPtr = BitConverter.ToInt64(curPrologue, 6);
                            if (targetPtr == _pStub.ToInt64()) {
                                return true; // Already hooked and intact
                            }
                        }
                    }
                }

                Console.WriteLine($"[AeroHook] Installing Aero Caption Hook in PID {targetPid}...");

                // Allocate 64KB in target process
                UIntPtr allocSize = (UIntPtr)0x10000;
                IntPtr pRemote = VirtualAllocEx(hProc, IntPtr.Zero, allocSize, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
                if (pRemote == IntPtr.Zero) {
                    Console.WriteLine("[AeroHook] VirtualAllocEx failed in target process.");
                    return false;
                }

                long offCtx = 0x0000;
                long offStub = 0x9000;
                long offTramp = 0x9100;
                long offCode = 0x9200;

                _pCtx = new IntPtr(pRemote.ToInt64() + offCtx);
                _pStub = new IntPtr(pRemote.ToInt64() + offStub);
                IntPtr pTramp = new IntPtr(pRemote.ToInt64() + offTramp);
                IntPtr pCode = new IntPtr(pRemote.ToInt64() + offCode);

                // 1. Context Buffer (36KB)
                byte[] ctxBuf = new byte[0x8800];
                Buffer.BlockCopy(BitConverter.GetBytes(pTramp.ToInt64()), 0, ctxBuf, 0x00, 8);
                Buffer.BlockCopy(BitConverter.GetBytes(pSetDIBitsToDevice.ToInt64()), 0, ctxBuf, 0x08, 8);

                // 2. Hook Stub (45 bytes):
                // sub rsp, 0x28
                // mov [rsp+32], r9
                // mov r9, r8
                // mov r8, rdx
                // mov rdx, rcx
                // mov rcx, pCtx
                // mov rax, pCode
                // call rax
                // add rsp, 0x28
                // ret
                byte[] stubBytes = new byte[] {
                    0x48, 0x83, 0xEC, 0x28,
                    0x4C, 0x89, 0x4C, 0x24, 0x20,
                    0x4D, 0x89, 0xC1,
                    0x49, 0x89, 0xD0,
                    0x48, 0x89, 0xCA,
                    0x48, 0xB9, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x48, 0xB8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0xFF, 0xD0,
                    0x48, 0x83, 0xC4, 0x28,
                    0xC3
                };
                Buffer.BlockCopy(BitConverter.GetBytes(_pCtx.ToInt64()), 0, stubBytes, 18, 8);
                Buffer.BlockCopy(BitConverter.GetBytes(pCode.ToInt64()), 0, stubBytes, 28, 8);

                // 3. Trampoline (32 bytes):
                // Original prologue: 41 57 41 56 41 55 41 54 55 57 56 53 48 81 EC 28 01 00 00
                // Jmp to pDrawFrameControl + 19
                byte[] trampBytes = new byte[] {
                    0x41, 0x57,
                    0x41, 0x56,
                    0x41, 0x55,
                    0x41, 0x54,
                    0x55,
                    0x57,
                    0x56,
                    0x53,
                    0x48, 0x81, 0xEC, 0x28, 0x01, 0x00, 0x00,
                    0x49, 0xBB, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x41, 0xFF, 0xE3
                };
                long trampTarget = pDrawFrameControl.ToInt64() + 19;
                Buffer.BlockCopy(BitConverter.GetBytes(trampTarget), 0, trampBytes, 21, 8);

                // 4. Code Blob
                byte[] codeBlob = AeroHookBlob.Code;

                // Write memory blocks
                int written;
                WriteProcessMemory(hProc, _pCtx, ctxBuf, ctxBuf.Length, out written);
                WriteProcessMemory(hProc, _pStub, stubBytes, stubBytes.Length, out written);
                WriteProcessMemory(hProc, pTramp, trampBytes, trampBytes.Length, out written);
                WriteProcessMemory(hProc, pCode, codeBlob, codeBlob.Length, out written);

                // 5. Apply Trampoline Jump to DrawFrameControl:
                byte[] jmpPatch = new byte[] {
                    0xFF, 0x25, 0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                    0x90, 0x90, 0x90, 0x90, 0x90
                };
                Buffer.BlockCopy(BitConverter.GetBytes(_pStub.ToInt64()), 0, jmpPatch, 6, 8);

                uint oldProtect;
                VirtualProtectEx(hProc, pDrawFrameControl, (UIntPtr)jmpPatch.Length, PAGE_EXECUTE_READWRITE, out oldProtect);
                bool hookOk = WriteProcessMemory(hProc, pDrawFrameControl, jmpPatch, jmpPatch.Length, out written);
                VirtualProtectEx(hProc, pDrawFrameControl, (UIntPtr)jmpPatch.Length, oldProtect, out oldProtect);

                if (hookOk) {
                    _lastHookedPid = targetPid;
                    Console.WriteLine($"[AeroHook] Successfully installed Aero caption hook in PID {targetPid}!");
                    return true;
                } else {
                    Console.WriteLine("[AeroHook] Failed to write hook patch to DrawFrameControl.");
                    return false;
                }
            } finally {
                CloseHandle(hProc);
            }
        }
    }
}
