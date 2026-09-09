using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace WineSW.Daemon {
    public class AeroCaptionOverlay : Form {
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

        static readonly IntPtr HWND_TOPMOST = (IntPtr)(-1);
        const uint SWP_NOACTIVATE = 0x0010;
        const uint SWP_SHOWWINDOW = 0x0040;
        const uint SWP_HIDEWINDOW = 0x0080;

        const uint WM_SYSCOMMAND = 0x0112;
        const int SC_MINIMIZE = 0xF020;
        const int SC_MAXIMIZE = 0xF030;
        const int SC_RESTORE  = 0xF120;
        const int SC_CLOSE    = 0xF060;

        private IntPtr _targetDoc = IntPtr.Zero;
        private int _hoverBtn = 0;   // 1=min, 2=max, 3=close
        private int _pressedBtn = 0; // 1=min, 2=max, 3=close

        // Geometry: Min (22px), Max (22px), Close (26px), gap 2px
        // Total width: 22 + 2 + 22 + 2 + 26 = 74px, Height: 22px
        private Rectangle _rMin   = new Rectangle(1, 1, 22, 21);
        private Rectangle _rMax   = new Rectangle(25, 1, 22, 21);
        private Rectangle _rClose = new Rectangle(49, 1, 26, 21);

        public AeroCaptionOverlay() {
            this.FormBorderStyle = FormBorderStyle.None;
            this.ShowInTaskbar = false;
            this.StartPosition = FormStartPosition.Manual;
            this.Width = 76;
            this.Height = 23;
            this.DoubleBuffered = true;
            this.BackColor = Color.FromArgb(43, 136, 255); // SolidWorks caption blue
            this.TopMost = true;
        }

        protected override CreateParams CreateParams {
            get {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
                cp.ExStyle |= 0x00000008; // WS_EX_TOPMOST
                return cp;
            }
        }

        protected override bool ShowWithoutActivation {
            get { return true; }
        }

        public void UpdateTarget(IntPtr hDoc) {
            _targetDoc = hDoc;
            if (_targetDoc == IntPtr.Zero || !IsWindowVisible(_targetDoc)) {
                if (this.Visible) this.Hide();
                return;
            }

            RECT r;
            if (GetWindowRect(_targetDoc, out r)) {
                int w = r.Right - r.Left;
                // Target position: right border is at r.Right - 4
                // Overlay right edge at r.Right - 4
                int targetX = r.Right - 4 - this.Width;
                int targetY = r.Top + 4;

                SetWindowPos(this.Handle, HWND_TOPMOST, targetX, targetY, this.Width, this.Height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
                if (!this.Visible) this.Show();
            }
        }

        protected override void OnMouseMove(MouseEventArgs e) {
            base.OnMouseMove(e);
            int newHover = 0;
            if (_rMin.Contains(e.Location)) newHover = 1;
            else if (_rMax.Contains(e.Location)) newHover = 2;
            else if (_rClose.Contains(e.Location)) newHover = 3;

            if (newHover != _hoverBtn) {
                _hoverBtn = newHover;
                this.Invalidate();
            }
        }

        protected override void OnMouseLeave(EventArgs e) {
            base.OnMouseLeave(e);
            _hoverBtn = 0;
            _pressedBtn = 0;
            this.Invalidate();
        }

        protected override void OnMouseDown(MouseEventArgs e) {
            base.OnMouseDown(e);
            if (e.Button == MouseButtons.Left) {
                _pressedBtn = _hoverBtn;
                this.Invalidate();
            }
        }

        protected override void OnMouseUp(MouseEventArgs e) {
            base.OnMouseUp(e);
            if (e.Button == MouseButtons.Left) {
                int clicked = (_hoverBtn == _pressedBtn) ? _pressedBtn : 0;
                _pressedBtn = 0;
                this.Invalidate();

                if (clicked != 0 && _targetDoc != IntPtr.Zero) {
                    if (clicked == 1) {
                        PostMessage(_targetDoc, WM_SYSCOMMAND, (IntPtr)SC_MINIMIZE, IntPtr.Zero);
                    } else if (clicked == 2) {
                        bool isMax = IsZoomed(_targetDoc);
                        PostMessage(_targetDoc, WM_SYSCOMMAND, (IntPtr)(isMax ? SC_RESTORE : SC_MAXIMIZE), IntPtr.Zero);
                    } else if (clicked == 3) {
                        PostMessage(_targetDoc, WM_SYSCOMMAND, (IntPtr)SC_CLOSE, IntPtr.Zero);
                    }
                }
            }
        }

        protected override void OnPaint(PaintEventArgs e) {
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;

            // Clear with caption blue
            using (Brush bBg = new SolidBrush(this.BackColor)) {
                g.FillRectangle(bBg, this.ClientRectangle);
            }

            bool isMaximized = (_targetDoc != IntPtr.Zero && IsZoomed(_targetDoc));

            DrawButton(g, _rMin, false, _hoverBtn == 1, _pressedBtn == 1, 1);
            DrawButton(g, _rMax, false, _hoverBtn == 2, _pressedBtn == 2, isMaximized ? 4 : 2);
            DrawButton(g, _rClose, true, _hoverBtn == 3, _pressedBtn == 3, 3);
        }

        private void DrawButton(Graphics g, Rectangle rect, bool isClose, bool isHover, bool isPressed, int type) {
            // Colors matching real Windows 7 Aero reference
            Color borderColor = isClose ? Color.FromArgb(81, 50, 66) : Color.FromArgb(103, 124, 150);
            Color topStart, topEnd, botStart, botEnd;

            if (isClose) {
                if (isPressed) {
                    borderColor = Color.FromArgb(128, 8, 8);
                    topStart = Color.FromArgb(186, 77, 61);
                    topEnd   = Color.FromArgb(209, 99, 83);
                    botStart = Color.FromArgb(217, 112, 96);
                    botEnd   = Color.FromArgb(240, 154, 138);
                } else if (isHover) {
                    borderColor = Color.FromArgb(106, 21, 21);
                    topStart = Color.FromArgb(255, 168, 152);
                    topEnd   = Color.FromArgb(240, 120, 104);
                    botStart = Color.FromArgb(232, 88, 72);
                    botEnd   = Color.FromArgb(200, 40, 24);
                } else {
                    topStart = Color.FromArgb(241, 182, 171);
                    topEnd   = Color.FromArgb(233, 166, 153);
                    botStart = Color.FromArgb(209, 124, 108);
                    botEnd   = Color.FromArgb(178, 99, 87);
                }
            } else {
                if (isPressed) {
                    borderColor = Color.FromArgb(61, 90, 117);
                    topStart = Color.FromArgb(156, 184, 208);
                    topEnd   = Color.FromArgb(181, 206, 226);
                    botStart = Color.FromArgb(194, 215, 234);
                    botEnd   = Color.FromArgb(220, 234, 246);
                } else if (isHover) {
                    borderColor = Color.FromArgb(72, 107, 140);
                    topStart = Color.FromArgb(226, 240, 253);
                    topEnd   = Color.FromArgb(207, 228, 246);
                    botStart = Color.FromArgb(182, 215, 242);
                    botEnd   = Color.FromArgb(216, 236, 250);
                } else {
                    topStart = Color.FromArgb(197, 223, 250);
                    topEnd   = Color.FromArgb(191, 211, 230);
                    botStart = Color.FromArgb(178, 204, 231);
                    botEnd   = Color.FromArgb(212, 228, 244);
                }
            }

            // Draw rounded button (radius 2)
            GraphicsPath path = new GraphicsPath();
            int r = 3;
            path.AddArc(rect.X, rect.Y, r, r, 180, 90);
            path.AddArc(rect.Right - r, rect.Y, r, r, 270, 90);
            path.AddArc(rect.Right - r, rect.Bottom - r, r, r, 0, 90);
            path.AddArc(rect.X, rect.Bottom - r, r, r, 90, 90);
            path.CloseFigure();

            // Split gradient
            int splitH = (int)(rect.Height * 0.45f);
            Rectangle topHalf = new Rectangle(rect.X, rect.Y, rect.Width, splitH);
            Rectangle botHalf = new Rectangle(rect.X, rect.Y + splitH, rect.Width, rect.Height - splitH);

            using (LinearGradientBrush brTop = new LinearGradientBrush(topHalf, topStart, topEnd, LinearGradientMode.Vertical)) {
                g.FillRectangle(brTop, topHalf);
            }
            using (LinearGradientBrush brBot = new LinearGradientBrush(botHalf, botStart, botEnd, LinearGradientMode.Vertical)) {
                g.FillRectangle(brBot, botHalf);
            }

            // 1px Inner top/left highlight
            using (Pen pHi = new Pen(Color.FromArgb(170, 255, 255, 255), 1)) {
                g.DrawLine(pHi, rect.X + 1, rect.Y + 1, rect.Right - 2, rect.Y + 1);
                g.DrawLine(pHi, rect.X + 1, rect.Y + 1, rect.X + 1, rect.Bottom - 2);
            }

            // Outer border
            using (Pen pBorder = new Pen(borderColor, 1)) {
                g.DrawPath(pBorder, path);
            }

            // Vector Glyphs
            int cx = rect.X + rect.Width / 2;
            int cy = rect.Y + rect.Height / 2;
            if (isPressed) { cx++; cy++; }

            if (type == 1) {
                // Minimize
                using (Brush bDrop = new SolidBrush(Color.FromArgb(200, 255, 255, 255))) {
                    g.FillRectangle(bDrop, cx - 4, cy + 3, 8, 2);
                }
                using (Brush bGlyph = new SolidBrush(Color.FromArgb(69, 77, 91))) {
                    g.FillRectangle(bGlyph, cx - 4, cy + 2, 8, 2);
                }
            } else if (type == 2) {
                // Maximize (single 8x8 square)
                using (Pen pDrop = new Pen(Color.FromArgb(200, 255, 255, 255), 1)) {
                    g.DrawRectangle(pDrop, cx - 4, cy - 3, 8, 8);
                }
                using (Pen pGlyph = new Pen(Color.FromArgb(69, 77, 91), 1)) {
                    g.DrawRectangle(pGlyph, cx - 4, cy - 4, 8, 8);
                }
            } else if (type == 4) {
                // Restore (nested squares)
                using (Pen pDrop = new Pen(Color.FromArgb(200, 255, 255, 255), 1)) {
                    g.DrawRectangle(pDrop, cx - 2, cy - 5, 6, 6);
                    g.DrawRectangle(pDrop, cx - 5, cy - 2, 6, 6);
                }
                using (Pen pGlyph = new Pen(Color.FromArgb(69, 77, 91), 1)) {
                    g.DrawRectangle(pGlyph, cx - 2, cy - 6, 6, 6);
                    g.DrawRectangle(pGlyph, cx - 5, cy - 3, 6, 6);
                }
            } else if (type == 3) {
                // Close (45 deg white cross)
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
}
