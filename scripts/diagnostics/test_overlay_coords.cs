
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;

class TestOverlayCoords {
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void Main() {
        IntPtr hDoc = IntPtr.Zero;
        EnumWindows((top, l) => {
            StringBuilder t = new StringBuilder(256);
            GetWindowText(top, t, 256);
            if (t.ToString().Contains("SOLIDWORKS")) {
                EnumChildWindows(top, (c, lc) => {
                    if (!IsWindowVisible(c)) return true;
                    int style = GetWindowLong(c, -16);
                    if ((style & 0x00C00000) == 0x00C00000) {
                        hDoc = c;
                        return false;
                    }
                    return true;
                }, IntPtr.Zero);
            }
            return true;
        }, IntPtr.Zero);

        RECT r;
        GetWindowRect(hDoc, out r);
        int w = 69;
        int sx = r.Right - 4 - w;
        int sy = r.Top + 4;
        Console.WriteLine($"Doc Rect: ({r.Left},{r.Top},{r.Right},{r.Bottom}), Overlay pos: ({sx}, {sy})");
    }
}
