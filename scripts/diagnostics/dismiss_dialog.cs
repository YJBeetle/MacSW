using System;
using System.Runtime.InteropServices;
using System.Text;

class DismissDialog {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    const uint BM_CLICK = 0x00F5;
    const uint WM_CLOSE = 0x0010;

    static void Main() {
        EnumWindows(delegate(IntPtr top, IntPtr l) {
            StringBuilder cls = new StringBuilder(256);
            GetClassName(top, cls, 256);
            StringBuilder title = new StringBuilder(256);
            GetWindowText(top, title, 256);
            if (cls.ToString() == "#32770") {
                Console.WriteLine("Found dialog: " + title.ToString());
                bool clicked = false;
                EnumChildWindows(top, delegate(IntPtr child, IntPtr l2) {
                    StringBuilder btnText = new StringBuilder(256);
                    GetWindowText(child, btnText, 256);
                    if (btnText.ToString().Contains("确定") || btnText.ToString().Contains("OK")) {
                        Console.WriteLine("Clicking button: " + btnText.ToString());
                        SendMessage(child, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
                        clicked = true;
                        return false;
                    }
                    return true;
                }, IntPtr.Zero);

                if (!clicked) {
                    SendMessage(top, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                }
            }
            return true;
        }, IntPtr.Zero);
    }
}
