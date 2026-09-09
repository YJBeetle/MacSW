/*
 * sw_aero_hook.c - Native 64-bit Aero Caption Button Hook for SolidWorks 2025
 * Intercepts DrawFrameControl(DFC_CAPTION) and renders pixel-perfect Windows 7 Aero
 * glossy buttons matching the CommandManager navigation buttons [ <| ] [ |> ].
 */

typedef void* HDC;
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

typedef int (__attribute__((ms_abi)) *fn_DrawFrameControl_t)(HDC, LPRECT, unsigned int, unsigned int);
typedef int (__attribute__((ms_abi)) *fn_SetDIBitsToDevice_t)(HDC, int, int, int, int, int, int, int, int, const void*, const BITMAPINFO*, unsigned int);

typedef struct _AERO_HOOK_CONTEXT {
    // Function Pointers
    fn_DrawFrameControl_t fn_DrawFrameControl_Orig;
    fn_SetDIBitsToDevice_t fn_SetDIBitsToDevice;

    // Runtime Metrics & Stats
    unsigned int total_calls;
    unsigned int caption_calls;
    unsigned int last_type;
    unsigned int last_state;
    int last_rect[4];

    // Pixel Buffer (heap-allocated in ctx)
    unsigned int pixels[128 * 64];
} AERO_HOOK_CONTEXT;

// Helper: blend two RGB values (0 <= t <= 255)
static inline unsigned int blend_rgb(unsigned int c1, unsigned int c2, int t) {
    int r1 = (c1 >> 16) & 0xFF, g1 = (c1 >> 8) & 0xFF, b1 = c1 & 0xFF;
    int r2 = (c2 >> 16) & 0xFF, g2 = (c2 >> 8) & 0xFF, b2 = c2 & 0xFF;
    int r = r1 + ((r2 - r1) * t) / 255;
    int g = g1 + ((g2 - g1) * t) / 255;
    int b = b1 + ((b2 - b1) * t) / 255;
    return (r << 16) | (g << 8) | b;
}

int __attribute__((ms_abi)) Aero_DrawFrameControl(
    AERO_HOOK_CONTEXT* ctx,
    HDC hdc,
    LPRECT lprc,
    unsigned int uType,
    unsigned int uState)
{
    ctx->total_calls++;

    // uType == 1 is DFC_CAPTION
    if (uType != 1 || !lprc || !hdc) {
        return ctx->fn_DrawFrameControl_Orig(hdc, lprc, uType, uState);
    }

    ctx->caption_calls++;
    ctx->last_type = uType;
    ctx->last_state = uState;
    ctx->last_rect[0] = lprc->left;
    ctx->last_rect[1] = lprc->top;
    ctx->last_rect[2] = lprc->right;
    ctx->last_rect[3] = lprc->bottom;

    int w = lprc->right - lprc->left;
    int h = lprc->bottom - lprc->top;
    if (w <= 0 || h <= 0 || w > 128 || h > 64) {
        return ctx->fn_DrawFrameControl_Orig(hdc, lprc, uType, uState);
    }

    unsigned int btn_type = uState & 0xFF; // 0=CLOSE, 1=MIN, 2=MAX, 3=RESTORE
    int is_pushed = (uState & 0x0200) ? 1 : 0;
    int is_hot = (uState & 0x1000) ? 1 : 0;
    int is_inactive = (uState & 0x0100) ? 1 : 0;

    unsigned int* pixels = ctx->pixels;
    int total_pixels = w * h;

    int is_close = (btn_type == 0);

    // Color definitions from Windows 7 Aero reference
    unsigned int clr_border, clr_hi_top;
    unsigned int grad_top_start, grad_top_end;
    unsigned int grad_bot_start, grad_bot_end;

    if (is_close) {
        if (is_pushed) {
            clr_border = 0x500808;
            clr_hi_top = 0x801010;
            grad_top_start = 0x901515; grad_top_end = 0xA02020;
            grad_bot_start = 0xB52828; grad_bot_end = 0x801010;
        } else if (is_hot) {
            clr_border = 0x6A1010;
            clr_hi_top = 0xFFA090;
            grad_top_start = 0xF55040; grad_top_end = 0xEA3525;
            grad_bot_start = 0xDE2015; grad_bot_end = 0xD01510;
        } else {
            // Normal Close Button
            clr_border = 0x513242;     // #513242
            clr_hi_top = 0xD0AAA7;     // #D0AAA7
            grad_top_start = 0xF1B6AB; // #F1B6AB
            grad_top_end = 0xE9A699;   // #E9A699
            grad_bot_start = 0xD17C6C; // #D17C6C
            grad_bot_end = 0xB26357;   // #B26357
        }
    } else {
        // Min / Restore / Max Button
        if (is_pushed) {
            clr_border = 0x3D5A75;
            clr_hi_top = 0x85A4C0;
            grad_top_start = 0x96B8DE; grad_top_end = 0xA2C2E6;
            grad_bot_start = 0xB5D0F0; grad_bot_end = 0x8FB4DA;
        } else if (is_hot) {
            clr_border = 0x4A7095;
            clr_hi_top = 0xE2F0FD;
            grad_top_start = 0xD8ECFE; grad_top_end = 0xC8E2FA;
            grad_bot_start = 0xB0D4F5; grad_bot_end = 0xC2E2FC;
        } else {
            // Normal Blue Button
            clr_border = 0x677C96;     // #677C96
            clr_hi_top = 0xC5CFDD;     // #C5CFDD
            grad_top_start = 0xC5DFFA; // #C5DFFA
            grad_top_end = 0xBFD3E6;   // #BFD3E6
            grad_bot_start = 0xB2CCE7; // #B2CCE7
            grad_bot_end = 0xD4E4F4;   // #D4E4F4
        }
    }

    int split_y = (h * 45) / 100;

    // Fill background & borders
    for (int y = 0; y < h; y++) {
        unsigned int row_bg;
        if (y <= split_y) {
            int t = (split_y > 0) ? (y * 255) / split_y : 0;
            row_bg = blend_rgb(grad_top_start, grad_top_end, t);
        } else {
            int bot_h = h - split_y - 1;
            int t = (bot_h > 0) ? ((y - split_y - 1) * 255) / bot_h : 0;
            row_bg = blend_rgb(grad_bot_start, grad_bot_end, t);
        }

        for (int x = 0; x < w; x++) {
            // Corner rounding (2px radius)
            if ((x == 0 && y == 0) || (x == w - 1 && y == 0) ||
                (x == 0 && y == h - 1) || (x == w - 1 && y == h - 1)) {
                pixels[y * w + x] = blend_rgb(0xA0B8D0, clr_border, 120);
                continue;
            }

            // Outer border (1px)
            if (x == 0 || x == w - 1 || y == 0 || y == h - 1) {
                pixels[y * w + x] = clr_border;
                continue;
            }

            // Inner top highlight
            if (y == 1 && x > 0 && x < w - 1) {
                pixels[y * w + x] = clr_hi_top;
                continue;
            }

            // Inner side highlight
            if ((x == 1 || x == w - 2) && y > 1 && y < h - 1) {
                pixels[y * w + x] = blend_rgb(row_bg, 0xFFFFFF, 70);
                continue;
            }

            pixels[y * w + x] = row_bg;
        }
    }

    // Overlay Glyphs
    int cx = w / 2;
    int cy = h / 2;
    if (is_pushed) {
        cx += 1;
        cy += 1;
    }

    if (btn_type == 0) {
        // Close: White 'X' with subtle drop shadow
        unsigned int clr_glyph = 0xFFFFFF;
        unsigned int clr_shadow = 0x401010;

        for (int d = -4; d <= 4; d++) {
            // Shadow (1px down)
            int sx1 = cx + d, sy1 = cy + d + 1;
            int sx2 = cx - d, sy2 = cy + d + 1;
            if (sx1 >= 1 && sx1 < w - 1 && sy1 >= 1 && sy1 < h - 1) pixels[sy1 * w + sx1] = clr_shadow;
            if (sx2 >= 1 && sx2 < w - 1 && sy2 >= 1 && sy2 < h - 1) pixels[sy2 * w + sx2] = clr_shadow;

            // Main stroke (double pixel width for smooth body)
            int mx1 = cx + d, my1 = cy + d;
            int mx2 = cx - d, my2 = cy + d;
            if (mx1 >= 1 && mx1 < w - 1 && my1 >= 1 && my1 < h - 1) {
                pixels[my1 * w + mx1] = clr_glyph;
                if (mx1 + 1 < w - 1) pixels[my1 * w + mx1 + 1] = blend_rgb(pixels[my1 * w + mx1 + 1], clr_glyph, 180);
            }
            if (mx2 >= 1 && mx2 < w - 1 && my2 >= 1 && my2 < h - 1) {
                pixels[my2 * w + mx2] = clr_glyph;
                if (mx2 + 1 < w - 1) pixels[my2 * w + mx2 + 1] = blend_rgb(pixels[my2 * w + mx2 + 1], clr_glyph, 180);
            }
        }
    } else if (btn_type == 1) {
        // Min: Dark slate line with white bottom glow
        unsigned int clr_glyph = 0x454D5B;
        unsigned int clr_glow = 0xFFFFFF;

        int bar_y = cy + 2;
        int bar_x1 = cx - 4, bar_x2 = cx + 4;
        // White glow
        for (int x = bar_x1; x <= bar_x2; x++) {
            if (x >= 1 && x < w - 1 && bar_y + 2 < h - 1) {
                pixels[(bar_y + 2) * w + x] = blend_rgb(pixels[(bar_y + 2) * w + x], clr_glow, 160);
            }
        }
        // Main bar (2px thick)
        for (int y = bar_y; y <= bar_y + 1; y++) {
            for (int x = bar_x1; x <= bar_x2; x++) {
                if (x >= 1 && x < w - 1 && y >= 1 && y < h - 1) {
                    pixels[y * w + x] = clr_glyph;
                }
            }
        }
    } else {
        // Restore / Max (btn_type 2 or 3): Overlapping or single rectangular frames
        unsigned int clr_glyph = 0x454D5B;
        unsigned int clr_glow = 0xFFFFFF;

        if (btn_type == 3) {
            // Restore: Two overlapping boxes
            // Back box (offset top-right by 2px)
            int bx1 = cx - 2, by1 = cy - 4, bx2 = cx + 4, by2 = cy + 2;
            for (int x = bx1; x <= bx2; x++) {
                if (x >= 1 && x < w - 1 && by1 >= 1 && by1 < h - 1) pixels[by1 * w + x] = clr_glyph;
                if (x >= 1 && x < w - 1 && by1 + 1 < h - 1) pixels[(by1 + 1) * w + x] = clr_glyph; // thick top bar
            }
            for (int y = by1; y <= by2; y++) {
                if (bx2 >= 1 && bx2 < w - 1 && y >= 1 && y < h - 1) pixels[y * w + bx2] = clr_glyph;
            }

            // Front box
            int fx1 = cx - 4, fy1 = cy - 2, fx2 = cx + 2, fy2 = cy + 4;
            // White glow around front box
            for (int x = fx1; x <= fx2 + 1; x++) {
                if (x >= 1 && x < w - 1 && fy2 + 1 < h - 1) pixels[(fy2 + 1) * w + x] = blend_rgb(pixels[(fy2 + 1) * w + x], clr_glow, 160);
            }
            // Front box frame
            for (int x = fx1; x <= fx2; x++) {
                if (x >= 1 && x < w - 1 && fy1 >= 1 && fy1 < h - 1) pixels[fy1 * w + x] = clr_glyph;
                if (x >= 1 && x < w - 1 && fy1 + 1 < h - 1) pixels[(fy1 + 1) * w + x] = clr_glyph; // thick top bar
                if (x >= 1 && x < w - 1 && fy2 >= 1 && fy2 < h - 1) pixels[fy2 * w + x] = clr_glyph;
            }
            for (int y = fy1; y <= fy2; y++) {
                if (fx1 >= 1 && fx1 < w - 1 && y >= 1 && y < h - 1) pixels[y * w + fx1] = clr_glyph;
                if (fx2 >= 1 && fx2 < w - 1 && y >= 1 && y < h - 1) pixels[y * w + fx2] = clr_glyph;
            }
        } else {
            // Max: Single prominent box (8x8)
            int x1 = cx - 4, y1 = cy - 4, x2 = cx + 4, y2 = cy + 4;
            // Glow
            for (int x = x1; x <= x2; x++) {
                if (x >= 1 && x < w - 1 && y2 + 1 < h - 1) pixels[(y2 + 1) * w + x] = blend_rgb(pixels[(y2 + 1) * w + x], clr_glow, 160);
            }
            // Box
            for (int x = x1; x <= x2; x++) {
                if (x >= 1 && x < w - 1 && y1 >= 1 && y1 < h - 1) pixels[y1 * w + x] = clr_glyph;
                if (x >= 1 && x < w - 1 && y1 + 1 < h - 1) pixels[(y1 + 1) * w + x] = clr_glyph; // thick top bar
                if (x >= 1 && x < w - 1 && y2 >= 1 && y2 < h - 1) pixels[y2 * w + x] = clr_glyph;
            }
            for (int y = y1; y <= y2; y++) {
                if (x1 >= 1 && x1 < w - 1 && y >= 1 && y < h - 1) pixels[y * w + x1] = clr_glyph;
                if (x2 >= 1 && x2 < w - 1 && y >= 1 && y < h - 1) pixels[y * w + x2] = clr_glyph;
            }
        }
    }

    // Transfer pixels directly to target device context
    BITMAPINFO bmi;
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h; // negative = top-down DIB
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = 0; // BI_RGB
    bmi.bmiHeader.biSizeImage = 0;
    bmi.bmiHeader.biXPelsPerMeter = 0;
    bmi.bmiHeader.biYPelsPerMeter = 0;
    bmi.bmiHeader.biClrUsed = 0;
    bmi.bmiHeader.biClrImportant = 0;

    ctx->fn_SetDIBitsToDevice(
        hdc,
        lprc->left,
        lprc->top,
        w,
        h,
        0,
        0,
        0,
        h,
        pixels,
        &bmi,
        0 // DIB_RGB_COLORS
    );

    return 1; // TRUE
}
