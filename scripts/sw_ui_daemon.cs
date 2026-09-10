using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Collections.Generic;

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
    static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern IntPtr SetParent(IntPtr hWndChild, IntPtr hWndNewParent);

    [DllImport("user32.dll")]
    static extern IntPtr GetDesktopWindow();

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

    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    static extern int GetSystemMetrics(int nIndex);

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
    const uint WS_POPUP = 0x80000000;
    const uint WS_CHILD = 0x40000000;
    const int WS_EX_COMPOSITED = 0x02000000;
    const int WS_CLIPSIBLINGS = 0x04000000;
    const int WS_EX_TOOLWINDOW = 0x00000080;
    const int WS_EX_TOPMOST = 0x00000008;

    static readonly IntPtr HWND_TOPMOST = (IntPtr)(-1);
    const uint SWP_NOSIZE = 0x0001;
    const uint SWP_NOMOVE = 0x0002;
    const uint SWP_NOZORDER = 0x0004;
    const uint SWP_NOACTIVATE = 0x0010;
    const uint SWP_FRAMECHANGED = 0x0020;
    const uint SWP_SHOWWINDOW = 0x0040;
    const uint SWP_HIDEWINDOW = 0x0080;
    const int SW_HIDE = 0;

    const uint RDW_INVALIDATE = 0x0001;
    const uint RDW_ERASE = 0x0004;
    const uint RDW_ALLCHILDREN = 0x0080;
    const uint RDW_UPDATENOW = 0x0100;
    const uint RDW_FRAME = 0x0400;
    const uint WM_SETFONT = 0x0030;

    // Standard width of the left FeatureManager docking panel
    const int DESIRED_PANEL_WIDTH = 310;

    static IntPtr hFontSegoe = IntPtr.Zero;

    static HashSet<IntPtr> _processedDialogs = new HashSet<IntPtr>();

    // Fix Dialogs & CommandLink Buttons font (root cause: old Tahoma theme font has no CJK)
    static void FixDialogsAndButtons(IntPtr topHwnd) {
        if (_processedDialogs.Contains(topHwnd)) return;
        _processedDialogs.Add(topHwnd);

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

    static bool IsLoginManagerDialog(IntPtr hDlg) {
        bool isLogin = false;
        EnumChildWindows(hDlg, delegate(IntPtr child, IntPtr l) {
            StringBuilder txt = new StringBuilder(512);
            GetWindowText(child, txt, 512);
            string s = txt.ToString();
            if (s.Contains("Login Manager") || s.Contains("SOLIDWORKS Login Manager")) {
                isLogin = true;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return isLogin;
    }

    // Path 1: Elevate floating panels & popups to independent Cocoa floating windows (NSFloatingWindowLevel)
    static void ElevateFloatingAndPopups(uint swPid, List<IntPtr> swDocWindows) {
        IntPtr desk = GetDesktopWindow();
        List<IntPtr> wins = new List<IntPtr>();

        EnumWindows(delegate(IntPtr hWnd, IntPtr l) {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid == swPid) {
                wins.Add(hWnd);
            }
            return true;
        }, IntPtr.Zero);

        foreach (IntPtr h in wins) {
            if (swDocWindows != null && swDocWindows.Contains(h)) continue;

            StringBuilder clsSb = new StringBuilder(256);
            GetClassName(h, clsSb, 256);
            string cls = clsSb.ToString();

            // CRITICAL: NEVER touch menus, dropdowns, combo popups or tooltips!
            // Touching these windows causes active dropdown menus to turn blank/white!
            if (cls == "#32768" || cls.Contains("Menu") || cls.Contains("Popup") || cls.Contains("ComboLBox") || cls.Contains("tooltips_class32")) {
                continue;
            }

            StringBuilder titleSb = new StringBuilder(256);
            GetWindowText(h, titleSb, 256);
            string title = titleSb.ToString();

            int exstyle = GetWindowLong(h, GWL_EXSTYLE);
            RECT r;
            GetWindowRect(h, out r);
            int w = r.Right - r.Left;
            int hg = r.Bottom - r.Top;
            bool vis = IsWindowVisible(h);

            bool isDialog = (cls == "#32770");
            bool isMini = cls.Contains("MiniWnd") || cls.Contains("MiniFrame") || cls.Contains("CMiniDock") || title.Contains("Toolbar") || cls.Contains("SysFloatToolBar");

            if (isDialog) {
                // Intercept and suppress Login Manager dialog if it ever appears
                bool isLoginManager = false;
                EnumChildWindows(h, delegate(IntPtr child, IntPtr l) {
                    StringBuilder txt = new StringBuilder(512);
                    GetWindowText(child, txt, 512);
                    string s = txt.ToString();
                    if (s.Contains("Login Manager") || s.Contains("SOLIDWORKS Login Manager")) {
                        isLoginManager = true;
                    }
                    return true;
                }, IntPtr.Zero);

                if (isLoginManager) {
                    SetWindowPos(h, IntPtr.Zero, -10000, -10000, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOZORDER | SWP_HIDEWINDOW);
                    ShowWindow(h, SW_HIDE);
                    continue;
                }

                FixDialogsAndButtons(h);
                if ((exstyle & WS_EX_TOPMOST) == 0) {
                    SetWindowLong(h, GWL_EXSTYLE, exstyle | WS_EX_TOPMOST);
                    SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_SHOWWINDOW);
                }
            } else if (isMini) {
                // Elevate ONLY recognized floating toolbars / docking panes (NEVER arbitrary popups or menus)
                if ((exstyle & WS_EX_TOPMOST) == 0 || (exstyle & WS_EX_TOOLWINDOW) == 0) {
                    SetWindowLong(h, GWL_EXSTYLE, exstyle | WS_EX_TOOLWINDOW | WS_EX_TOPMOST);
                    IntPtr parent = GetParent(h);
                    if (parent != desk && parent != IntPtr.Zero) {
                        SetParent(h, desk);
                    }
                    SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_SHOWWINDOW);
                }

                // Rescue lost or out-of-screen floating panels (multi-monitor aware)
                int vx = GetSystemMetrics(76); // SM_XVIRTUALSCREEN
                int vy = GetSystemMetrics(77); // SM_YVIRTUALSCREEN
                int vcx = GetSystemMetrics(78); // SM_CXVIRTUALSCREEN
                int vcy = GetSystemMetrics(79); // SM_CYVIRTUALSCREEN
                if (vcx <= 0) vcx = 3008;
                if (vcy <= 0) vcy = 2000;

                bool isOutOfBounds = (r.Right < vx + 20 || r.Left > (vx + vcx - 20) || r.Bottom < vy + 20 || r.Top > (vy + vcy - 20));
                if (vis && (isOutOfBounds || w < 20 || hg < 20)) {
                    SetWindowPos(h, HWND_TOPMOST, vx + 700, vy + 200, 360, 480, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
                }
            }
        }
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

            // 3. Elevate Floating Tool Windows / Palettes inside child tree
            if (c.Contains("MiniFrame") || c.Contains("XTPDockingPaneMiniWnd") || t.Contains("Floating")) {
                if ((exstyle & WS_EX_TOOLWINDOW) == 0 || (exstyle & WS_EX_TOPMOST) == 0) {
                    SetWindowLong(child, GWL_EXSTYLE, exstyle | WS_EX_TOOLWINDOW | WS_EX_TOPMOST);
                    SetWindowPos(child, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED | SWP_NOACTIVATE);
                }
            }

            // 4. Fix Viewport / Tree Container / Docked PropertyManager layout
            bool isTreeContainer = (t == "Tree Container Wnd" || t.Contains("Tree Container") || (c.Contains("Tree") && c.Contains("Container")));
            if (isTreeContainer) {
                // Ensure WS_CLIPSIBLINGS on tree container
                int childStyle = GetWindowLong(child, GWL_STYLE);
                if ((childStyle & WS_CLIPSIBLINGS) == 0) {
                    SetWindowLong(child, GWL_STYLE, childStyle | WS_CLIPSIBLINGS);
                }

                IntPtr mdiDoc = GetParent(child);
                if (mdiDoc != IntPtr.Zero) {
                    RECT rDocClient, rTree;
                    GetClientRect(mdiDoc, out rDocClient);
                    GetWindowRect(child, out rTree);

                    int curTreeW = rTree.Right - rTree.Left;
                    // Expand Tree Container if it's too narrow (< 300px) or collapsed
                    if (curTreeW < DESIRED_PANEL_WIDTH) {
                        POINT ptTreeTL = new POINT { X = rTree.Left, Y = rTree.Top };
                        ScreenToClient(mdiDoc, ref ptTreeTL);
                        SetWindowPos(child, IntPtr.Zero, Math.Max(ptTreeTL.X, 0), Math.Max(ptTreeTL.Y, 0), DESIRED_PANEL_WIDTH, Math.Max(rTree.Bottom - rTree.Top, rDocClient.Bottom), SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);
                        GetWindowRect(child, out rTree);
                        RedrawWindow(child, IntPtr.Zero, IntPtr.Zero, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW);
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

                            if (st == "DVEDockedContainer" || (sc.Contains("AfxFrameOrView") && st.Contains("Container"))) {
                                // Check if it has any visible children (actively displaying PropertyManager / Sketch Editor)
                                bool hasActiveChildren = false;
                                EnumChildWindows(sibling, delegate(IntPtr cChild, IntPtr lp3) {
                                    if (IsWindowVisible(cChild)) {
                                        RECT rc;
                                        GetWindowRect(cChild, out rc);
                                        if ((rc.Right - rc.Left) > 20 && (rc.Bottom - rc.Top) > 20) {
                                            hasActiveChildren = true;
                                            return false;
                                        }
                                    }
                                    return true;
                                }, IntPtr.Zero);

                                if (hasActiveChildren) {
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
                        }
                        return true;
                    }, IntPtr.Zero);

                    // Pass B: Adjust 3D Viewport MDI Frame to avoid covering any docked panels
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

                            // 3D Viewport MDI Frame holds the CAMetalLayer CAD rendering canvas.
                            // Robust detection across all MFC version variations (AfxMDIFrame140u, AfxMDIFrame, etc.)
                            bool isViewportFrame = sc.StartsWith("AfxMDIFrame") ||
                                                   (sc.StartsWith("AfxFrameOrView") && !st.Contains("Container") && !st.Contains("Dock") && !st.Contains("Tree"));

                            if (isViewportFrame && sibW > 100 && sibH > 100) {
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
            uint swPid = 0;
            List<IntPtr> swDocWindows = new List<IntPtr>();

            EnumWindows(delegate(IntPtr top, IntPtr l) {
                StringBuilder t = new StringBuilder(256);
                GetWindowText(top, t, 256);
                string titleStr = t.ToString();

                StringBuilder c = new StringBuilder(256);
                GetClassName(top, c, 256);
                string clsStr = c.ToString();

                if (clsStr == "#32770") {
                    if (IsLoginManagerDialog(top)) {
                        SetWindowPos(top, IntPtr.Zero, -10000, -10000, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOZORDER | SWP_HIDEWINDOW);
                        ShowWindow(top, SW_HIDE);
                        return true;
                    }
                    // Global safety: catch any dialogs, fix fonts and elevate to topmost
                    FixDialogsAndButtons(top);
                    int exstyle = GetWindowLong(top, GWL_EXSTYLE);
                    if ((exstyle & WS_EX_TOPMOST) == 0) {
                        SetWindowLong(top, GWL_EXSTYLE, exstyle | WS_EX_TOPMOST);
                        SetWindowPos(top, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_SHOWWINDOW);
                    }
                } else if (titleStr.IndexOf("SOLIDWORKS", StringComparison.OrdinalIgnoreCase) >= 0 || clsStr.StartsWith("Afx:") || clsStr.Contains("MainFrame")) {
                    swDocWindows.Add(top);
                    if (swPid == 0) {
                        GetWindowThreadProcessId(top, out swPid);
                    }
                }
                return true; // NEVER return false! Process all windows!
            }, IntPtr.Zero);

            foreach (IntPtr w in swDocWindows) {
                FixDocLayoutAndThemes(w);
            }

            if (swPid != 0) {
                ElevateFloatingAndPopups(swPid, swDocWindows);
                // 用户明确指示：当前现代扁平浅灰无边框标题栏非常美观，无需强行启用 AeroHook
            }

            if (watch) {
                Thread.Sleep(200);
            }
        } while (watch);
    }
}
