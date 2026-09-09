
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

class TestRenderAeroOverlay {
    [DllImport("user32.dll")] static extern IntPtr GetWindowDC(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    static void DrawAeroButton(Graphics g, Rectangle rect, bool isClose, bool isHover, bool isPressed, string type) {
        g.SmoothingMode = SmoothingMode.AntiAlias;

        // Outer border & gradient colors
        Color borderColor = isClose ? Color.FromArgb(81, 50, 66) : Color.FromArgb(103, 124, 150);
        Color topStart = isClose ? Color.FromArgb(241, 182, 171) : Color.FromArgb(197, 223, 250);
        Color topEnd = isClose ? Color.FromArgb(233, 166, 153) : Color.FromArgb(191, 211, 230);
        Color botStart = isClose ? Color.FromArgb(209, 124, 108) : Color.FromArgb(178, 204, 231);
        Color botEnd = isClose ? Color.FromArgb(178, 99, 87) : Color.FromArgb(212, 228, 244);

        if (isClose && isHover) {
            topStart = Color.FromArgb(250, 150, 140);
            botEnd = Color.FromArgb(210, 60, 50);
        }

        // Draw rounded box (2px radius)
        GraphicsPath path = new GraphicsPath();
        int r = 3;
        path.AddArc(rect.X, rect.Y, r, r, 180, 90);
        path.AddArc(rect.Right - r, rect.Y, r, r, 270, 90);
        path.AddArc(rect.Right - r, rect.Bottom - r, r, r, 0, 90);
        path.AddArc(rect.X, rect.Bottom - r, r, r, 90, 90);
        path.CloseFigure();

        // Fill background with split gradient (top 45%, bot 55%)
        Rectangle topHalf = new Rectangle(rect.X, rect.Y, rect.Width, (int)(rect.Height * 0.45f));
        Rectangle botHalf = new Rectangle(rect.X, rect.Y + topHalf.Height, rect.Width, rect.Height - topHalf.Height);

        using (LinearGradientBrush brTop = new LinearGradientBrush(topHalf, topStart, topEnd, LinearGradientMode.Vertical)) {
            g.FillRectangle(brTop, topHalf);
        }
        using (LinearGradientBrush brBot = new LinearGradientBrush(botHalf, botStart, botEnd, LinearGradientMode.Vertical)) {
            g.FillRectangle(brBot, botHalf);
        }

        // Inner highlight
        using (Pen penHi = new Pen(Color.FromArgb(160, 255, 255, 255), 1)) {
            g.DrawLine(penHi, rect.X + 1, rect.Y + 1, rect.Right - 2, rect.Y + 1);
            g.DrawLine(penHi, rect.X + 1, rect.Y + 1, rect.X + 1, rect.Bottom - 2);
        }

        // Outer stroke
        using (Pen penBorder = new Pen(borderColor, 1)) {
            g.DrawPath(penBorder, path);
        }

        // Draw glyphs
        int cx = rect.X + rect.Width / 2;
        int cy = rect.Y + rect.Height / 2;

        if (type == "min") {
            // Horizontal bar: 8x2px slate with white drop glow
            using (Brush bDrop = new SolidBrush(Color.FromArgb(200, 255, 255, 255))) {
                g.FillRectangle(bDrop, cx - 4, cy + 3, 8, 2);
            }
            using (Brush bGlyph = new SolidBrush(Color.FromArgb(69, 77, 91))) {
                g.FillRectangle(bGlyph, cx - 4, cy + 2, 8, 2);
            }
        } else if (type == "max") {
            // Nested or single square
            using (Pen pDrop = new Pen(Color.FromArgb(200, 255, 255, 255), 1)) {
                g.DrawRectangle(pDrop, cx - 4, cy - 3, 8, 8);
            }
            using (Pen pGlyph = new Pen(Color.FromArgb(69, 77, 91), 1)) {
                g.DrawRectangle(pGlyph, cx - 4, cy - 4, 8, 8);
            }
        } else if (type == "close") {
            // 45 deg crisp cross
            using (Pen pDrop = new Pen(Color.FromArgb(120, 64, 16, 16), 1.6f)) {
                g.DrawLine(pDrop, cx - 4, cy - 3, cx + 4, cy + 5);
                g.DrawLine(pDrop, cx + 4, cy - 3, cx - 4, cy + 5);
            }
            using (Pen pGlyph = new Pen(Color.White, 1.6f)) {
                g.DrawLine(pGlyph, cx - 4, cy - 4, cx + 4, cy + 4);
                g.DrawLine(pGlyph, cx + 4, cy - 4, cx - 4, cy + 4);
            }
        }
    }

    static void Main() {
        IntPtr hDoc = new IntPtr(0x100DD0);
        RECT r;
        GetWindowRect(hDoc, out r);
        int w = r.Right - r.Left;

        IntPtr hdc = GetWindowDC(hDoc);
        if (hdc == IntPtr.Zero) return;

        using (Graphics g = Graphics.FromHdc(hdc)) {
            // First clear the area where the 3 buttons sit with the caption background
            // Wine default caption blue: Color.FromArgb(43, 136, 255)
            // Wine buttons: Rel X from 2313 to 2373 (w - 65 to w - 5)
            // Let us cover from w - 85 to w - 4, Y = 4 to 28
            Rectangle coverRect = new Rectangle(w - 85, 4, 81, 24);
            using (Brush bBg = new SolidBrush(Color.FromArgb(43, 136, 255))) {
                g.FillRectangle(bBg, coverRect);
            }

            Rectangle rMin = new Rectangle(w - 78, 5, 22, 22);
            Rectangle rMax = new Rectangle(w - 53, 5, 22, 22);
            Rectangle rClose = new Rectangle(w - 28, 5, 24, 22);

            DrawAeroButton(g, rMin, false, false, false, "min");
            DrawAeroButton(g, rMax, false, false, false, "max");
            DrawAeroButton(g, rClose, true, false, false, "close");
        }
        ReleaseDC(hDoc, hdc);
        Console.WriteLine("Rendered Aero buttons!");
    }
}
