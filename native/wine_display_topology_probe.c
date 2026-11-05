/* Manual hotplug regression. Move the window to an external display,
 * maximize it, unplug/reconnect that display, then close the window.
 * Exit 0 requires a topology change and WM_DISPLAYCHANGE.
 */
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <stdio.h>

static unsigned int notifications, topology_changes;
static int previous_count;
static RECT previous_virtual;
static HWND probe_window;

static BOOL CALLBACK monitor(HMONITOR mon, HDC dc, LPRECT rect, LPARAM unused)
{
    (void)dc;
    (void)rect;
    (void)unused;
    MONITORINFOEXW info = { .cbSize = sizeof(info) };
    GetMonitorInfoW(mon, (MONITORINFO *)&info);
    printf("monitor=%lx rect=%ld,%ld,%ld,%ld work=%ld,%ld,%ld,%ld\n",
           info.dwFlags, info.rcMonitor.left, info.rcMonitor.top, info.rcMonitor.right, info.rcMonitor.bottom,
           info.rcWork.left, info.rcWork.top, info.rcWork.right, info.rcWork.bottom);
    return TRUE;
}

static void snapshot(const char *reason)
{
    printf("tick=%lu reason=%s primary=%dx%d virtual=%d,%d,%dx%d count=%d\n", GetTickCount(), reason,
           GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN),
           GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN),
           GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN),
           GetSystemMetrics(SM_CMONITORS));
    RECT current = {
        GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN), 0, 0
    };
    int count = GetSystemMetrics(SM_CMONITORS);
    current.right = current.left + GetSystemMetrics(SM_CXVIRTUALSCREEN);
    current.bottom = current.top + GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (previous_count && (previous_count != count || !EqualRect(&previous_virtual, &current)))
        topology_changes++;
    previous_count = count;
    previous_virtual = current;
    if (probe_window) {
        RECT window;
        GetWindowRect(probe_window, &window);
        printf("window=%ld,%ld,%ld,%ld maximized=%d\n",
               window.left, window.top, window.right, window.bottom, IsZoomed(probe_window));
    }
    EnumDisplayMonitors(NULL, NULL, monitor, 0);
    fflush(stdout);
}
static LRESULT CALLBACK proc(HWND hwnd, UINT msg, WPARAM w, LPARAM l)
{
    switch (msg) {
    case WM_CREATE:
        SetTimer(hwnd, 1, 5000, NULL);
        snapshot("create");
        break;
    case WM_TIMER:
        snapshot("timer");
        break;
    case WM_DISPLAYCHANGE:
        notifications++;
        snapshot("WM_DISPLAYCHANGE");
        break;
    case WM_SETTINGCHANGE:
        snapshot("WM_SETTINGCHANGE");
        break;
    case WM_DESTROY:
        printf("result topology_changes=%u notifications=%u\n", topology_changes, notifications);
        fflush(stdout);
        PostQuitMessage(topology_changes && notifications ? 0 : 1);
        break;
    }
    return DefWindowProcW(hwnd, msg, w, l);
}
int main(void)
{
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    WNDCLASSW cls = { .lpfnWndProc = proc, .hInstance = GetModuleHandleW(NULL), .lpszClassName = L"MacSWDisplayProbe" };
    RegisterClassW(&cls);
    HWND hwnd = CreateWindowW(cls.lpszClassName, L"MacSW 显示器热插拔诊断（可调整或最大化此窗口）",
                             WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 640, 320, NULL, NULL, cls.hInstance, NULL);
    if (!hwnd) return 2;
    probe_window = hwnd;
    MSG msg;
    int result;
    while ((result = GetMessageW(&msg, NULL, 0, 0)) > 0)
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if (result == -1) return 2;
    return (int)msg.wParam;
}
