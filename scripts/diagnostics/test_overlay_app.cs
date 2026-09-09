using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Text;

class TestOverlayApp {
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr hWnd);

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static readonly IntPtr HWND_TOPMOST = (IntPtr)(-1);
    const uint SWP_NOACTIVATE = 0x0010;
    const uint SWP_SHOWWINDOW = 0x0040;

    class OverlayForm : Form {
        IntPtr _hDoc;
        int _hoverBtn = 0;
        int _pressedBtn = 0;

        // Button boxes: Min, Max, Close
        Rectangle _rMin   = new Rectangle(1, 1, 20, 22);
        Rectangle _rMax   = new Rectangle(22, 1, 20, 22);
        Rectangle _rClose = new Rectangle(43, 1, 25, 22);

        public OverlayForm(IntPtr hDoc) {
            _hDoc = hDoc;
            this.FormBorderStyle = FormBorderStyle.None;
            this.ShowInTaskbar = false;
            this.StartPosition = FormStartPosition.Manual;
            this.Width = 69;
            this.Height = 24;
            this.DoubleBuffered = true;
            this.BackColor = Color.FromArgb(43, 136, 255);
            this.TopMost = true;

            RECT r;
            GetWindowRect(_hDoc, out r);
            int sx = r.Right - 4 - this.Width;
            int sy = r.Top + 4;
            this.Location = new Point(sx, sy);
        }

        protected override CreateParams CreateParams {
            get {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
                cp.ExStyle |= 0x00000008; // WS_EX_TOPMOST
                return cp;
            }
        }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override void OnMouseMove(MouseEventArgs e) {
            base.OnMouseMove(e);
            int h = 0;
            if (_rMin.Contains(e.Location)) h = 1;
            else if (_rMax.Contains(e.Location)) h = 2;
            else if (_rClose.Contains(e.Location)) h = 3;

            if (h != _hoverBtn) {
                _hoverBtn = h;
                Invalidate();
            }
        }

        protected override void OnMouseLeave(EventArgs e) {
            base.OnMouseLeave(e);
            _hoverBtn = 0;
            _pressedBtn = 0;
            Invalidate();
        }

        protected override void OnMouseDown(MouseEventArgs e) {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Left) {
                _pressedBtn = _hoverBtn;
                Invalidate();
            }
        }

        protected override void OnMouseUp(MouseEventArgs e) {
            base.OnMouseUp(e);
            if (e.Button == MouseButtons.Left) {
                int clicked = (_hoverBtn == _pressedBtn) ? _pressedBtn : 0;
                _pressedBtn = 0;
                Invalidate();

                if (clicked == 1) {
                    PostMessage(_hDoc, 0x0112, (IntPtr)0xF020 /* SC_MINIMIZE */, IntPtr.Zero);
                } else if (clicked == 2) {
                    bool isMax = IsZoomed(_hDoc);
                    PostMessage(_hDoc, 0x0112, (IntPtr)(isMax ? 0xF120 : 0xF030), IntPtr.Zero);
                } else if (clicked == 3) {
                    PostMessage(_hDoc, 0x0112, (IntPtr)0xF060 /* SC_CLOSE */, IntPtr.Zero);
                }
            }
        }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;

            using (Brush bBg = new SolidBrush(this.BackColor)) {
                g.FillRectangle(bBg, this.ClientRectangle);
            }

            bool isMax = IsZoomed(_hDoc);
            DrawAeroBtn(g, _rMin, false, _hoverBtn == 1, _pressedBtn == 1, 1);
            DrawAeroBtn(g, _rMax, false, _hoverBtn == 2, _pressedBtn == 2, isMax ? 4 : 2);
            DrawAeroBtn(g, _rClose, true, _hoverBtn == 3, _pressedBtn == 3, 3);
        }

        void DrawAeroBtn(Graphics g, Rectangle rect, bool isClose, bool isHover, bool isPressed, int type) {
            Color border = isClose ? (isPressed ? Color.FromArgb(128,8,8) : isHover ? Color.FromArgb(106,21,21) : Color.FromArgb(81,50,66))
                                   : (isPressed ? Color.FromArgb(61,90,117) : isHover ? Color.FromArgb(72,107,140) : Color.FromArgb(103,124,150));

            Color tStart, tEnd, bStart, bEnd;
            if (isClose) {
                if (isPressed) {
                    tStart = Color.FromArgb(186,77,61); tEnd = Color.FromArgb(209,99,83);
                    bStart = Color.FromArgb(217,112,96); bEnd = Color.FromArgb(240,154,138);
                } else if (isHover) {
                    tStart = Color.FromArgb(255,168,152); tEnd = Color.FromArgb(240,120,104);
                    bStart = Color.FromArgb(232,88,72); bEnd = Color.FromArgb(200,40,24);
                } else {
                    tStart = Color.FromArgb(241,182,171); tEnd = Color.FromArgb(233,166,153);
                    bStart = Color.FromArgb(209,124,108); bEnd = Color.FromArgb(178,99,87);
                }
            } else {
                if (isPressed) {
                    tStart = Color.FromArgb(156,184,208); tEnd = Color.FromArgb(181,206,226);
                    bStart = Color.FromArgb(194,215,234); bEnd = Color.FromArgb(220,234,246);
                } else if (isHover) {
                    tStart = Color.FromArgb(226,240,253); tEnd = Color.FromArgb(207,228,246);
                    bStart = Color.FromArgb(182,215,242); bEnd = Color.FromArgb(216,236,250);
                } else {
                    tStart = Color.FromArgb(197,223,250); tEnd = Color.FromArgb(191,211,230);
                    bStart = Color.FromArgb(178,204,231); bEnd = Color.FromArgb(212,228,244);
                }
            }

            GraphicsPath path = new GraphicsPath();
            int r = 3;
            path.AddArc(rect.X, rect.Y, r, r, 180, 90);
            path.AddArc(rect.Right - r, rect.Y, r, r, 270, 90);
            path.AddArc(rect.Right - r, rect.Bottom - r, r, r, 0, 90);
            path.AddArc(rect.X, rect.Bottom - r, r, r, 90, 90);
            path.CloseFigure();

            int splitH = (int)(rect.Height * 0.45f);
            Rectangle rTop = new Rectangle(rect.X, rect.Y, rect.Width, splitH);
            Rectangle rBot = new Rectangle(rect.X, rect.Y + splitH, rect.Width, rect.Height - splitH);

            using (LinearGradientBrush br = new LinearGradientBrush(rTop, tStart, tEnd, LinearGradientMode.Vertical)) {
                g.FillRectangle(br, rTop);
            }
            using (LinearGradientBrush br = new LinearGradientBrush(rBot, bStart, bEnd, LinearGradientMode.Vertical)) {
                g.FillRectangle(br, rBot);
            }

            using (Pen pHi = new Pen(Color.FromArgb(170, 255, 255, 255), 1)) {
                g.DrawLine(pHi, rect.X + 1, rect.Y + 1, rect.Right - 2, rect.Y + 1);
                g.DrawLine(pHi, rect.X + 1, rect.Y + 1, rect.X + 1, rect.Bottom - 2);
            }

            using (Pen pB = new Pen(border, 1)) {
                g.DrawPath(pB, path);
            }

            int cx = rect.X + rect.Width / 2;
            int cy = rect.Y + rect.Height / 2;
            if (isPressed) { cx++; cy++; }

            if (type == 1) { // Min
                using (Brush bDrop = new SolidBrush(Color.FromArgb(200, 255, 255, 255)))
                    g.FillRectangle(bDrop, cx - 4, cy + 3, 8, 2);
                using (Brush bGlyph = new SolidBrush(Color.FromArgb(69, 77, 91)))
                    g.FillRectangle(bGlyph, cx - 4, cy + 2, 8, 2);
            } else if (type == 2) { // Max
                using (Pen pDrop = new Pen(Color.FromArgb(200, 255, 255, 255), 1))
                    g.DrawRectangle(pDrop, cx - 4, cy - 3, 8, 8);
                using (Pen pGlyph = new Pen(Color.FromArgb(69, 77, 91), 1))
                    g.DrawRectangle(pGlyph, cx - 4, cy - 4, 8, 8);
            } else if (type == 4) { // Restore
                using (Pen pDrop = new Pen(Color.FromArgb(200, 255, 255, 255), 1)) {
                    g.DrawRectangle(pDrop, cx - 2, cy - 4, 6, 6);
                    g.DrawRectangle(pDrop, cx - 5, cy - 1, 6, 6);
                }
                using (Pen pGlyph = new Pen(Color.FromArgb(69, 77, 91), 1)) {
                    g.DrawRectangle(pGlyph, cx - 2, cy - 5, 6, 6);
                    g.DrawRectangle(pGlyph, cx - 5, cy - 2, 6, 6);
                }
            } else if (type == 3) { // Close
                using (Pen pDrop = new Pen(Color.FromArgb(120, 74, 18, 18), 1.8f)) {
                    g.DrawLine(pDrop, cx - 4, cy - 3, cx + 4, cy + 5);
                    g.DrawLine(pDrop, cx + 4, cy - 3, cx - 4, cy + 5);
                }
                using (Pen pGlyph = new Pen(Color.White, 1.8f)) {
                    g.DrawLine(pGlyph, cx - 4, cy - 4, cx + 4, cy + 4);
                    g.DrawLine(pGlyph, cx + 4, cy - 4, cx - 4, cy + 4);
                }
            }
        }
    }

    [STAThread]
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

        Console.WriteLine($"Found Doc: 0x{hDoc.ToInt64():X}");
        if (hDoc == IntPtr.Zero) return;

        OverlayForm form = new OverlayForm(hDoc);
        form.Show();

        // Run message loop with timer to close after 20s
        Timer timer = new Timer();
        timer.Interval = 20000;
        timer.Tick += (s, e) => {
            Application.Exit();
        };
        timer.Start();

        Console.WriteLine("Overlay shown! Running message loop for 20s...");
        Application.Run(form);
        Console.WriteLine("Overlay test ended.");
    }
}
