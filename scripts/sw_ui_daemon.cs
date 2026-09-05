using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

class SwUiDaemon {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll")]
    static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll")]
    static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);

    [DllImport("user32.dll")]
    static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);

    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);

    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFontW(
        int nHeight, int nWidth, int nEscapement, int nOrientation, int fnWeight,
        uint fdwItalic, uint fdwUnderline, uint fdwStrikeOut, uint fdwCharSet,
        uint fdwOutputPrecision, uint fdwClipPrecision, uint fdwQuality,
        uint fdwPitchAndFamily, string lpszFace);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X, Y; }

    const int GWL_STYLE = -16;
    const int GWL_EXSTYLE = -20;
    const int WS_EX_COMPOSITED = 0x02000000;
    const int WS_CLIPSIBLINGS = 0x04000000;
    const int WS_EX_TOOLWINDOW = 0x00000080;
    const int WS_EX_TOPMOST = 0x00000008;
    const uint SWP_NOZORDER = 0x0004;
    const uint SWP_NOACTIVATE = 0x0010;
    const uint RDW_INVALIDATE = 0x0001;
    const uint RDW_ERASE = 0x0004;
    const uint RDW_ALLCHILDREN = 0x0080;
    const uint RDW_UPDATENOW = 0x0100;
    const uint RDW_FRAME = 0x0400;
    const uint WM_SETFONT = 0x0030;

    // Standard width of the left FeatureManager docking panel
    const int DESIRED_PANEL_WIDTH = 310;

    static IntPtr hFontSegoe = IntPtr.Zero;

    // Fix Dialogs & CommandLink Buttons font (root cause: old Tahoma theme font has no CJK)
    static void FixDialogsAndButtons(IntPtr topHwnd) {
        EnumChildWindows(topHwnd, delegate(IntPtr child, IntPtr l) {
            StringBuilder cls = new StringBuilder(256);
            GetClassName(child, cls, 256);
            if (cls.ToString() == "Button") {
                int style = GetWindowLong(child, GWL_STYLE);
                int btnType = style & 0xF;
                // BS_COMMANDLINK (0xE) or BS_DEFCOMMANDLINK (0xF)
                if (btnType == 0x0000000E || btnType == 0x0000000F) {
                    if (hFontSegoe == IntPtr.Zero) {
                        hFontSegoe = CreateFontW(-14, 0, 0, 0, 600, 0, 0, 0, 1, 0, 0, 5, 0, "Segoe UI Semibold");
                    }
                    SetWindowTheme(child, " ", " ");
                    SendMessage(child, WM_SETFONT, hFontSegoe, (IntPtr)1);
                }
            }
            return true;
        }, IntPtr.Zero);
    }

    static void FixDocLayoutAndThemes(IntPtr swHwnd) {
        EnumChildWindows(swHwnd, delegate(IntPtr child, IntPtr l) {
            // 1. Strip WS_EX_COMPOSITED and ensure WS_CLIPSIBLINGS
            int exstyle = GetWindowLong(child, GWL_EXSTYLE);
            if ((exstyle & WS_EX_COMPOSITED) != 0) {
                SetWindowLong(child, GWL_EXSTYLE, exstyle & ~WS_EX_COMPOSITED);
                RedrawWindow(child, IntPtr.Zero, IntPtr.Zero, RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_UPDATENOW);
            }

            StringBuilder cls = new StringBuilder(256);
            GetClassName(child, cls, 256);
            StringBuilder title = new StringBuilder(256);
            GetWindowText(child, title, 256);
            string c = cls.ToString();
            string t = title.ToString();

            // 2. Reset Uxtheme on TreeView and TabControl
            if (c == "SysTreeView32" || c == "SysTabControl32") {
                SetWindowTheme(child, " ", " ");
            }

            // 3. Elevate Floating Tool Windows / Palettes (Path 1: Native Z-order over Metal)
            if (c.Contains("MiniFrame") || c.Contains("XTPDockingPaneMiniWnd") || t.Contains("Floating")) {
                if ((exstyle & WS_EX_TOOLWINDOW) == 0 || (exstyle & WS_EX_TOPMOST) == 0) {
                    SetWindowLong(child, GWL_EXSTYLE, exstyle | WS_EX_TOOLWINDOW | WS_EX_TOPMOST);
                    SetWindowPos(child, (IntPtr)(-1) /* HWND_TOPMOST */, 0, 0, 0, 0, 0x0001 | 0x0002 | SWP_NOACTIVATE);
                }
            }

            // 4. Fix Viewport / Tree Container / Docked PropertyManager layout
            if (t == "Tree Container Wnd") {
                IntPtr mdiDoc = GetParent(child);
                if (mdiDoc != IntPtr.Zero) {
                    RECT rDocClient, rTree;
                    GetClientRect(mdiDoc, out rDocClient);
                    GetWindowRect(child, out rTree);

                    int curTreeW = rTree.Right - rTree.Left;
                    // Expand Tree Container if it's too narrow (< 300px) to show all 5 tabs
                    if (curTreeW < DESIRED_PANEL_WIDTH) {
                        POINT ptTreeTL = new POINT { X = rTree.Left, Y = rTree.Top };
                        ScreenToClient(mdiDoc, ref ptTreeTL);
                        SetWindowPos(child, IntPtr.Zero, ptTreeTL.X, ptTreeTL.Y, DESIRED_PANEL_WIDTH, rTree.Bottom - rTree.Top, SWP_NOZORDER | SWP_NOACTIVATE);
                        GetWindowRect(child, out rTree);
                    }

                    int treeRight = rTree.Right;
                    POINT ptTreeRight = new POINT { X = treeRight, Y = rTree.Top };
                    ScreenToClient(mdiDoc, ref ptTreeRight);

                    // Determine right edge of all docked panels on the left side
                    int maxDockRight = Math.Max(ptTreeRight.X, DESIRED_PANEL_WIDTH);

                    // Pass A: Find any visible companion docked container (e.g. DVEDockedContainer / PropertyManager)
                    EnumChildWindows(mdiDoc, delegate(IntPtr sibling, IntPtr l2) {
                        if (GetParent(sibling) == mdiDoc && sibling != child && IsWindowVisible(sibling)) {
                            StringBuilder sibCls = new StringBuilder(256);
                            GetClassName(sibling, sibCls, 256);
                            StringBuilder sibTitle = new StringBuilder(256);
                            GetWindowText(sibling, sibTitle, 256);
                            string sc = sibCls.ToString();
                            string st = sibTitle.ToString();

                            if (st == "DVEDockedContainer" || (sc == "AfxFrameOrView140u" && st.Contains("Container"))) {
                                RECT rSib;
                                GetWindowRect(sibling, out rSib);
                                POINT ptSibTopRight = new POINT { X = rSib.Right, Y = rSib.Top };
                                ScreenToClient(mdiDoc, ref ptSibTopRight);

                                // If docked on the left half of the MDI window, expand maxDockRight
                                if (ptSibTopRight.X > maxDockRight && ptSibTopRight.X < rDocClient.Right - 200) {
                                    maxDockRight = ptSibTopRight.X;
                                }
                            }
                        }
                        return true;
                    }, IntPtr.Zero);

                    // Pass B: Adjust 3D Viewport MDI Frame (AfxMDIFrame140u) to avoid covering any docked panels
                    EnumChildWindows(mdiDoc, delegate(IntPtr sibling, IntPtr l2) {
                        if (GetParent(sibling) == mdiDoc && sibling != child) {
                            StringBuilder sibCls = new StringBuilder(256);
                            GetClassName(sibling, sibCls, 256);
                            string sc = sibCls.ToString();

                            RECT rSib;
                            GetWindowRect(sibling, out rSib);
                            int sibW = rSib.Right - rSib.Left;
                            int sibH = rSib.Bottom - rSib.Top;

                            POINT ptSibTopLeft = new POINT { X = rSib.Left, Y = rSib.Top };
                            ScreenToClient(mdiDoc, ref ptSibTopLeft);

                            // 3D Viewport MDI Frame (AfxMDIFrame140u) holds the CAMetalLayer CAD rendering canvas.
                            // It MUST start at or to the right of maxDockRight so CAMetalLayer never overlaps
                            // either the FeatureTree or the docked PropertyManager.
                            if (sc == "AfxMDIFrame140u" && sibW > 100 && sibH > 100) {
                                int newX = maxDockRight;
                                int newY = Math.Max(ptSibTopLeft.Y, 0);
                                int newW = rDocClient.Right - newX;
                                int newH = rDocClient.Bottom - newY;

                                if (newW > 100 && newH > 100 && (Math.Abs(ptSibTopLeft.X - newX) > 2 || Math.Abs(sibW - newW) > 5)) {
                                    int sibStyle = GetWindowLong(sibling, GWL_STYLE);
                                    if ((sibStyle & WS_CLIPSIBLINGS) == 0) {
                                        SetWindowLong(sibling, GWL_STYLE, sibStyle | WS_CLIPSIBLINGS);
                                    }

                                    SetWindowPos(sibling, IntPtr.Zero, newX, newY, newW, newH, SWP_NOZORDER | SWP_NOACTIVATE);
                                    RedrawWindow(child, IntPtr.Zero, IntPtr.Zero, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW);
                                    RedrawWindow(sibling, IntPtr.Zero, IntPtr.Zero, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW);
                                }
                            }
                        }
                        return true;
                    }, IntPtr.Zero);
                }
            }
            return true;
        }, IntPtr.Zero);
    }

    static void Main(string[] args) {
        bool watch = (args.Length > 0 && (args[0] == "--watch" || args[0] == "-w"));
        Console.WriteLine(watch ? "[SwUiDaemon] Watch mode active (200ms)..." : "[SwUiDaemon] Single scan...");

        do {
            EnumWindows(delegate(IntPtr top, IntPtr l) {
                StringBuilder t = new StringBuilder(256);
                GetWindowText(top, t, 256);
                string titleStr = t.ToString();
                StringBuilder c = new StringBuilder(256);
                GetClassName(top, c, 256);
                string clsStr = c.ToString();

                if (titleStr.Contains("SOLIDWORKS")) {
                    FixDocLayoutAndThemes(top);
                    FixDialogsAndButtons(top);
                } else if (clsStr == "#32770") {
                    // Fix standard dialogs
                    FixDialogsAndButtons(top);
                }
                return true;
            }, IntPtr.Zero);

            if (watch) {
                Thread.Sleep(200);
            }
        } while (watch);
    }
}
