/*
 * sw_aero_subclass.c - High Performance In-Process Aero Caption Button Renderer
 * for SolidWorks 2025 Child Windows on CrossOver/Wine.
 */

typedef void* HWND;
typedef void* HDC;
typedef void* HGDIOBJ;
typedef long long LONG_PTR;
typedef unsigned long long UINT_PTR;
typedef unsigned int UINT;
typedef unsigned long long WPARAM;
typedef long long LPARAM;
typedef long long LRESULT;

typedef struct {
    int left, top, right, bottom;
} RECT, *LPRECT;

typedef struct {
    unsigned int biSize;
    int biWidth;
    int biHeight;
    unsigned short biPlanes;
    unsigned short biBitCount;
    unsigned int biCompression;
    unsigned int biSizeImage;
    int biXPelsPerMeter;
    int biYPelsPerMeter;
    unsigned int biClrUsed;
    unsigned int biClrImportant;
} BITMAPINFOHEADER;

typedef struct {
    BITMAPINFOHEADER bmiHeader;
    unsigned int bmiColors[1];
} BITMAPINFO;

typedef LRESULT  (__attribute__((ms_abi)) *fn_CallWindowProcW_t)(LONG_PTR, HWND, UINT, WPARAM, LPARAM);
typedef HDC      (__attribute__((ms_abi)) *fn_GetWindowDC_t)(HWND);
typedef int      (__attribute__((ms_abi)) *fn_ReleaseDC_t)(HWND, HDC);
typedef int      (__attribute__((ms_abi)) *fn_GetWindowRect_t)(HWND, LPRECT);
typedef int      (__attribute__((ms_abi)) *fn_SetDIBitsToDevice_t)(HDC, int, int, int, int, int, int, int, int, const void*, const BITMAPINFO*, unsigned int);
typedef LONG_PTR (__attribute__((ms_abi)) *fn_SetWindowLongPtrW_t)(HWND, int, LONG_PTR);

typedef struct _SUBCLASS_DATA {
    // API Table (Filled by injector)
    fn_CallWindowProcW_t   fn_CallWindowProcW;
    fn_GetWindowDC_t       fn_GetWindowDC;
    fn_ReleaseDC_t         fn_ReleaseDC;
    fn_GetWindowRect_t     fn_GetWindowRect;
    fn_SetDIBitsToDevice_t fn_SetDIBitsToDevice;
    fn_SetWindowLongPtrW_t fn_SetWindowLongPtrW;

    // Window & State
    HWND     hWnd;
    LONG_PTR origWndProc;
    int      hoverBtn;   // 0=none, 1=min, 2=max, 3=close
    int      pressedBtn; // 0=none, 1=min, 2=max, 3=close

    // 32-bit DIB pixel buffer (128x64 pixels max per button)
    unsigned int pixels[128 * 64];
} SUBCLASS_DATA;

// Helper: blend two RGB values (0 <= t <= 255)
static inline unsigned int blend_rgb(unsigned int c1, unsigned int c2, int t) {
    int r1 = (c1 >> 16) & 0xFF, g1 = (c1 >> 8) & 0xFF, b1 = c1 & 0xFF;
    int r2 = (c2 >> 16) & 0xFF, g2 = (c2 >> 8) & 0xFF, b2 = c2 & 0xFF;
    int r = r1 + ((r2 - r1) * t) / 255;
    int g = g1 + ((g2 - g1) * t) / 255;
    int b = b1 + ((b2 - b1) * t) / 255;
    return (r << 16) | (g << 8) | b;
}

static void RenderSingleButton(
    SUBCLASS_DATA* data,
    HDC hdc,
    int dstX, int dstY, int w, int h,
    int btnId,   // 1=min, 2=max, 3=close
    int isHover,
    int isPressed)
{
    if (w <= 0 || h <= 0 || w > 128 || h > 64) return;

    unsigned int* pixels = data->pixels;
    int is_close = (btnId == 3);

    // Color definitions
    unsigned int clr_border, clr_hi_top;
    unsigned int grad_top_start, grad_top_end;
    unsigned int grad_bot_start, grad_bot_end;

    if (is_close) {
        if (isPressed) {
            clr_border = 0x800808;
            clr_hi_top = 0xB03030;
            grad_top_start = 0xBA4D3D;
            grad_top_end   = 0xD16353;
            grad_bot_start = 0xD97060;
            grad_bot_end   = 0xF09A8A;
        } else if (isHover) {
            clr_border = 0x6A1515;
            clr_hi_top = 0xFFA095;
            grad_top_start = 0xFFA898;
            grad_top_end   = 0xF07868;
            grad_bot_start = 0xE85848;
            grad_bot_end   = 0xC82818;
        } else {
            // Windows 7 Aero normal coral red close button
            clr_border = 0x513242;
            clr_hi_top = 0xD0AAA7;
            grad_top_start = 0xF1B6AB;
            grad_top_end   = 0xE9A699;
            grad_bot_start = 0xD17C6C;
            grad_bot_end   = 0xB26357;
        }
    } else {
        // Minimize / Restore / Maximize buttons (Aero Ice Blue)
        if (isPressed) {
            clr_border = 0x3D5A75;
            clr_hi_top = 0x85A0BA;
            grad_top_start = 0x9CB8D0;
            grad_top_end   = 0xB5CEE2;
            grad_bot_start = 0xC2D7EA;
            grad_bot_end   = 0xDCEAF6;
        } else if (isHover) {
            clr_border = 0x486B8C;
            clr_hi_top = 0xEAF4FF;
            grad_top_start = 0xE2F0FD;
            grad_top_end   = 0xCFE4F6;
            grad_bot_start = 0xB6D7F2;
            grad_bot_end   = 0xD8ECFA;
        } else {
            clr_border = 0x677C96;
            clr_hi_top = 0xC5CFDD;
            grad_top_start = 0xC5DFFA;
            grad_top_end   = 0xBFD3E6;
            grad_bot_start = 0xB2CCE7;
            grad_bot_end   = 0xD4E4F4;
        }
    }

    int split_y = (h * 45) / 100;
    if (split_y < 1) split_y = 1;
    int bot_h = h - split_y;

    // Fill pixels in top-down DIB order (row 0 is top of button)
    for (int y = 0; y < h; y++) {
        unsigned int bg_clr;
        if (y < split_y) {
            int t = (split_y > 1) ? (y * 255) / (split_y - 1) : 0;
            bg_clr = blend_rgb(grad_top_start, grad_top_end, t);
        } else {
            int t = (bot_h > 1) ? ((y - split_y) * 255) / (bot_h - 1) : 0;
            bg_clr = blend_rgb(grad_bot_start, grad_bot_end, t);
        }

        for (int x = 0; x < w; x++) {
            // Corners (2px radius)
            if ((x == 0 && y == 0) || (x == w - 1 && y == 0) ||
                (x == 0 && y == h - 1) || (x == w - 1 && y == h - 1)) {
                pixels[y * w + x] = 0x2B88FF; // Caption background blue
                continue;
            }

            // Outer 1px border
            if (x == 0 || x == w - 1 || y == 0 || y == h - 1) {
                pixels[y * w + x] = clr_border;
                continue;
            }

            // Inner 1px top highlight
            if (y == 1 && x > 1 && x < w - 2) {
                pixels[y * w + x] = blend_rgb(bg_clr, 0xFFFFFF, 180);
                continue;
            }
            // Inner 1px left highlight
            if (x == 1 && y > 1 && y < h - 2) {
                pixels[y * w + x] = blend_rgb(bg_clr, 0xFFFFFF, 120);
                continue;
            }

            pixels[y * w + x] = bg_clr;
        }
    }

    // Render Vector Icons
    int cx = w / 2;
    int cy = h / 2;
    if (isPressed) { cx++; cy++; }

    if (btnId == 1) {
        // Minimize: 8x2px slate bar with white drop shadow
        unsigned int slate = 0x454D5B;
        unsigned int white_glow = 0xF5FAFF;
        for (int x = cx - 4; x <= cx + 3; x++) {
            if (cy + 3 < h) pixels[(cy + 3) * w + x] = white_glow;
        }
        for (int dy = 1; dy <= 2; dy++) {
            for (int x = cx - 4; x <= cx + 3; x++) {
                if (cy + dy < h) pixels[(cy + dy) * w + x] = slate;
            }
        }
    }
    else if (btnId == 2) {
        // Maximize / Restore: 8x8px square
        unsigned int slate = 0x454D5B;
        unsigned int white_glow = 0xF5FAFF;
        int sx = cx - 4, ex = cx + 3;
        int sy = cy - 4, ey = cy + 3;

        for (int x = sx; x <= ex; x++) {
            if (ey + 1 < h) pixels[(ey + 1) * w + x] = white_glow;
        }
        for (int y = sy; y <= ey; y++) {
            for (int x = sx; x <= ex; x++) {
                if (x == sx || x == ex || y == sy || y == ey || y == sy + 1) {
                    if (y >= 0 && y < h && x >= 0 && x < w) {
                        pixels[y * w + x] = slate;
                    }
                }
            }
        }
    }
    else if (btnId == 3) {
        // Close: 45° crisp cross with white glow
        unsigned int white = 0xFFFFFF;
        unsigned int dark_shadow = 0x4A1212;

        for (int d = -4; d <= 4; d++) {
            int x1 = cx + d, y1 = cy + d;
            int x2 = cx + d, y2 = cy - d;

            if (y1 + 1 < h && x1 >= 0 && x1 < w) pixels[(y1 + 1) * w + x1] = dark_shadow;
            if (y2 + 1 < h && x2 >= 0 && x2 < w) pixels[(y2 + 1) * w + x2] = dark_shadow;

            if (y1 >= 0 && y1 < h && x1 >= 0 && x1 < w) pixels[y1 * w + x1] = white;
            if (y1 >= 0 && y1 < h && x1 + 1 < w) pixels[y1 * w + x1 + 1] = white;

            if (y2 >= 0 && y2 < h && x2 >= 0 && x2 < w) pixels[y2 * w + x2] = white;
            if (y2 >= 0 && y2 < h && x2 + 1 < w) pixels[y2 * w + x2 + 1] = white;
        }
    }

    // Prepare BITMAPINFO
    BITMAPINFO bmi;
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h; // Top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = 0; // BI_RGB
    bmi.bmiHeader.biSizeImage = w * h * 4;
    bmi.bmiHeader.biXPelsPerMeter = 0;
    bmi.bmiHeader.biYPelsPerMeter = 0;
    bmi.bmiHeader.biClrUsed = 0;
    bmi.bmiHeader.biClrImportant = 0;

    data->fn_SetDIBitsToDevice(
        hdc,
        dstX, dstY,
        w, h,
        0, 0,
        0, h,
        pixels,
        &bmi,
        0
    );
}

static void PaintAllButtons(SUBCLASS_DATA* data, HWND hWnd) {
    RECT r;
    if (!data->fn_GetWindowRect(hWnd, &r)) return;

    int w = r.right - r.left;
    HDC hdc = data->fn_GetWindowDC(hWnd);
    if (!hdc) return;

    // Geometry matching HitTest measurements:
    // Close: [w - 29, 4, w - 4, 28] (W=25, H=24)
    // Max:   [w - 47, 4, w - 29, 28] (W=18, H=24)
    // Min:   [w - 65, 4, w - 47, 28] (W=18, H=24)
    int btnH = 24;
    int btnY = 4;

    int closeW = 25;
    int closeX = w - 4 - closeW; // w - 29

    int maxW = 18;
    int maxX = closeX - maxW;   // w - 47

    int minW = 18;
    int minX = maxX - minW;     // w - 65

    int hover = data->hoverBtn;
    int pressed = data->pressedBtn;

    // Render Min
    RenderSingleButton(data, hdc, minX, btnY, minW, btnH, 1, hover == 1, pressed == 1);
    // Render Max
    RenderSingleButton(data, hdc, maxX, btnY, maxW, btnH, 2, hover == 2, pressed == 2);
    // Render Close
    RenderSingleButton(data, hdc, closeX, btnY, closeW, btnH, 3, hover == 3, pressed == 3);

    data->fn_ReleaseDC(hWnd, hdc);
}

// Window Procedure implementation
LRESULT __attribute__((ms_abi)) AeroMdiWndProc(
    SUBCLASS_DATA* data,
    HWND hWnd,
    UINT uMsg,
    WPARAM wParam,
    LPARAM lParam)
{
    if (!data) return 0;

    // 1. Let original window proc do its normal work first
    LRESULT res = data->fn_CallWindowProcW(data->origWndProc, hWnd, uMsg, wParam, lParam);

    // 2. Intercept NC paint and activation
    if (uMsg == 0x0085 /* WM_NCPAINT */ || uMsg == 0x0086 /* WM_NCACTIVATE */) {
        PaintAllButtons(data, hWnd);
    }
    // 3. Hover state tracking
    else if (uMsg == 0x00A0 /* WM_NCMOUSEMOVE */) {
        int newHover = 0;
        if (wParam == 20 /* HTCLOSE */) newHover = 3;
        else if (wParam == 9 /* HTMAXBUTTON */) newHover = 2;
        else if (wParam == 8 /* HTMINBUTTON */) newHover = 1;

        if (newHover != data->hoverBtn) {
            data->hoverBtn = newHover;
            PaintAllButtons(data, hWnd);
        }
    }
    // 4. Pressed state tracking
    else if (uMsg == 0x00A1 /* WM_NCLBUTTONDOWN */) {
        int newPressed = 0;
        if (wParam == 20) newPressed = 3;
        else if (wParam == 9) newPressed = 2;
        else if (wParam == 8) newPressed = 1;

        if (newPressed != 0) {
            data->pressedBtn = newPressed;
            PaintAllButtons(data, hWnd);
        }
    }
    // 5. Release / Mouse leave
    else if (uMsg == 0x00A2 /* WM_NCLBUTTONUP */ || uMsg == 0x02A2 /* WM_NCMOUSELEAVE */) {
        if (data->pressedBtn != 0 || data->hoverBtn != 0) {
            data->pressedBtn = 0;
            data->hoverBtn = 0;
            PaintAllButtons(data, hWnd);
        }
    }

    return res;
}
