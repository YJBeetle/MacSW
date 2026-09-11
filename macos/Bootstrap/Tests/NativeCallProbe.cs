using System;
using System.Runtime.InteropServices;

// Compare x86/x64 and default/interpreter execution without UI or database access.
class NativeCallProbe
{
    [DllImport("kernel32.dll")]
    static extern uint GetCurrentProcessId();

    [DllImport("kernel32.dll", EntryPoint = "CreateActCtxW")]
    static extern IntPtr CreateActCtx(IntPtr context);

    [DllImport("kernelbase.dll", EntryPoint = "CreateActCtxW")]
    static extern IntPtr CreateActCtxBase(IntPtr context);

    static void Main(string[] args)
    {
        Console.WriteLine("MAIN pointer=" + IntPtr.Size);
        Console.Out.Flush();
        Console.WriteLine("PID=" + GetCurrentProcessId());
        Console.WriteLine("PINVOKE OK");
        // Invalid input intentionally tests the API boundary without creating an activation context.
        IntPtr result = args.Length > 0 && args[0] == "kernelbase"
            ? CreateActCtxBase(IntPtr.Zero) : CreateActCtx(IntPtr.Zero);
        Console.WriteLine("CreateActCtx(NULL)=" + result);
    }
}
