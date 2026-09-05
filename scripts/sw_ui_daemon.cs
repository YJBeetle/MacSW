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

    [DllImport("uxtheme.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string pszSubIdList);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int X, Y; }

    const int GWL_STYLE = -16;
    const int GWL_EXSTYLE = -20;
    const int WS_EX_COMPOSITED = 0x02000000;
    const int WS_CLIPSIBLINGS = 0x04000000;
    const uint SWP_NOZORDER = 0x0004;
    const uint SWP_NOACTIVATE = 0x0010;
    const uint RDW_INVALIDATE = 0x0001;
    const uint RDW_ERASE = 0x0004;
    const uint RDW_ALLCHILDREN = 0x0080;
    const uint RDW_UPDATENOW = 0x0100;
    const uint RDW_FRAME = 0x0400;

    // Desired width of the left FeatureManager docking panel so all 5 tabs fit
    const int DESIRED_PANEL_WIDTH = 310;

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

            // 3. Fix Viewport / Tree Container layout and overlap
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

                    EnumChildWindows(mdiDoc, delegate(IntPtr sibling, IntPtr l2) {
                        if (GetParent(sibling) == mdiDoc && sibling != child) {
                            StringBuilder sibCls = new StringBuilder(256);
                            GetClassName(sibling, sibCls, 256);
                            StringBuilder sibTitle = new StringBuilder(256);
                            GetWindowText(sibling, sibTitle, 256);
                            string sc = sibCls.ToString();
                            string st = sibTitle.ToString();

                            RECT rSib;
                            GetWindowRect(sibling, out rSib);
                            int sibW = rSib.Right - rSib.Left;
                            int sibH = rSib.Bottom - rSib.Top;

                            POINT ptSibTopLeft = new POINT { X = rSib.Left, Y = rSib.Top };
                            ScreenToClient(mdiDoc, ref ptSibTopLeft);

                            // 3a. Docked Panels (e.g. DVEDockedContainer / PropertyManager):
                            // Leave them completely to SolidWorks' MFC docking manager so user can tab, drag, or dock them freely.
                            if (st == "DVEDockedContainer" || (sc == "AfxFrameOrView140u" && st.Contains("Container"))) {
                                return true;
                            }

                            // 3b. 3D Viewport MDI Frame (AfxMDIFrame140u):
                            // This holds the CAMetalLayer CAD rendering canvas.
                            // It MUST start to the right of the left panel (X = DESIRED_PANEL_WIDTH)
                            // so CAMetalLayer does not overlap the GDI tree / PropertyManager.
                            if (sc == "AfxMDIFrame140u" && sibW > 100 && sibH > 100) {
                                int newX = Math.Max(ptTreeRight.X, DESIRED_PANEL_WIDTH);
                                int newY = Math.Max(ptSibTopLeft.Y, 0);
                                int newW = rDocClient.Right - newX;
                                int newH = rDocClient.Bottom - newY;

                                if (newW > 100 && newH > 100 && (Math.Abs(ptSibTopLeft.X - newX) > 2 || Math.Abs(sibW - newW) > 5)) {
                                    // Ensure WS_CLIPSIBLINGS
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
                if (t.ToString().Contains("SOLIDWORKS")) {
                    FixDocLayoutAndThemes(top);
                }
                return true;
            }, IntPtr.Zero);

            if (watch) {
                Thread.Sleep(200);
            }
        } while (watch);
    }
}
