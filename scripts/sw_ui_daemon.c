#include <windows.h>
#include <wchar.h>

#define MAX_SW_WINDOWS 256
#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))

struct window_list
{
    HWND items[MAX_SW_WINDOWS];
    unsigned int count;
};

struct scan_context
{
    DWORD pid;
    struct window_list windows;
    struct window_list document_windows;
};

static BOOL contains_ci(const WCHAR *text, const WCHAR *value)
{
    size_t text_length = wcslen(text), value_length = wcslen(value), i;

    if (!value_length) return TRUE;
    if (value_length > text_length) return FALSE;
    for (i = 0; i <= text_length - value_length; ++i)
        if (CompareStringOrdinal(text + i, (int)value_length, value, (int)value_length, TRUE) == CSTR_EQUAL)
            return TRUE;
    return FALSE;
}

static BOOL starts_with_ci(const WCHAR *text, const WCHAR *value)
{
    size_t text_length = wcslen(text), value_length = wcslen(value);

    return text_length >= value_length &&
           CompareStringOrdinal(text, (int)value_length, value, (int)value_length, TRUE) == CSTR_EQUAL;
}

static void get_window_strings(HWND window, WCHAR *class_name, WCHAR *title)
{
    class_name[0] = 0;
    title[0] = 0;
    GetClassNameW(window, class_name, 256);
    GetWindowTextW(window, title, 512);
}

static BOOL CALLBACK find_solidworks_process(HWND window, LPARAM parameter)
{
    DWORD *pid = (DWORD *)parameter;
    WCHAR class_name[256], title[512];

    get_window_strings(window, class_name, title);
    if (contains_ci(title, L"SOLIDWORKS") || starts_with_ci(class_name, L"Afx:"))
        GetWindowThreadProcessId(window, pid);
    return !*pid;
}

static BOOL is_document_window(HWND window)
{
    WCHAR class_name[256], title[512];

    get_window_strings(window, class_name, title);
    if (!wcscmp(class_name, L"#32770")) return FALSE;
    return contains_ci(title, L"SOLIDWORKS") || starts_with_ci(class_name, L"Afx:") ||
           contains_ci(class_name, L"MainFrame");
}

static BOOL CALLBACK collect_process_windows(HWND window, LPARAM parameter)
{
    struct scan_context *context = (struct scan_context *)parameter;
    DWORD pid = 0;

    GetWindowThreadProcessId(window, &pid);
    if (pid != context->pid) return TRUE;
    if (context->windows.count < MAX_SW_WINDOWS)
        context->windows.items[context->windows.count++] = window;
    if (is_document_window(window) && context->document_windows.count < MAX_SW_WINDOWS)
        context->document_windows.items[context->document_windows.count++] = window;
    return TRUE;
}

static BOOL window_list_contains(const struct window_list *list, HWND window)
{
    unsigned int i;

    for (i = 0; i < list->count; ++i)
        if (list->items[i] == window) return TRUE;
    return FALSE;
}

static BOOL is_ignored_popup(const WCHAR *class_name)
{
    return !wcscmp(class_name, L"#32768") || contains_ci(class_name, L"Menu") ||
           contains_ci(class_name, L"Popup") || contains_ci(class_name, L"ComboLBox") ||
           contains_ci(class_name, L"tooltips_class32");
}

static BOOL is_floating_tool(const WCHAR *class_name, const WCHAR *title)
{
    return contains_ci(class_name, L"MiniWnd") || contains_ci(class_name, L"MiniFrame") ||
           contains_ci(class_name, L"CMiniDock") || contains_ci(class_name, L"SysFloatToolBar") ||
           contains_ci(class_name, L"XTPDockingPaneMiniWnd") || contains_ci(title, L"Toolbar") ||
           contains_ci(title, L"Floating");
}

static void elevate_dialog(HWND window)
{
    LONG_PTR ex_style;

    ex_style = GetWindowLongPtrW(window, GWL_EXSTYLE);
    if (!(ex_style & WS_EX_TOPMOST))
    {
        SetWindowLongPtrW(window, GWL_EXSTYLE, ex_style | WS_EX_TOPMOST);
        SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }
}

static void elevate_floating_window(HWND window)
{
    LONG_PTR ex_style = GetWindowLongPtrW(window, GWL_EXSTYLE);
    HWND desktop = GetDesktopWindow(), parent = GetParent(window);
    RECT rect;
    int width, height, x, y, virtual_width, virtual_height;

    if (!(ex_style & WS_EX_TOOLWINDOW) || !(ex_style & WS_EX_TOPMOST))
    {
        SetWindowLongPtrW(window, GWL_EXSTYLE, ex_style | WS_EX_TOOLWINDOW | WS_EX_TOPMOST);
        if (parent && parent != desktop) SetParent(window, desktop);
        SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }

    if (!IsWindowVisible(window) || !GetWindowRect(window, &rect)) return;
    width = rect.right - rect.left;
    height = rect.bottom - rect.top;
    x = GetSystemMetrics(SM_XVIRTUALSCREEN);
    y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    virtual_width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    virtual_height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if (virtual_width <= 0) virtual_width = 3008;
    if (virtual_height <= 0) virtual_height = 2000;
    if (rect.right < x + 20 || rect.left > x + virtual_width - 20 || rect.bottom < y + 20 ||
        rect.top > y + virtual_height - 20 || width < 20 || height < 20)
        SetWindowPos(window, HWND_TOPMOST, x + 700, y + 200, 360, 480,
                     SWP_FRAMECHANGED | SWP_SHOWWINDOW);
}

static BOOL CALLBACK elevate_child_floating_tool(HWND window, LPARAM unused)
{
    WCHAR class_name[256], title[512];
    LONG_PTR ex_style;

    (void)unused;
    get_window_strings(window, class_name, title);
    ex_style = GetWindowLongPtrW(window, GWL_EXSTYLE);
    if (is_floating_tool(class_name, title) &&
        (!(ex_style & WS_EX_TOOLWINDOW) || !(ex_style & WS_EX_TOPMOST)))
    {
        SetWindowLongPtrW(window, GWL_EXSTYLE, ex_style | WS_EX_TOOLWINDOW | WS_EX_TOPMOST);
        SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED | SWP_NOACTIVATE);
    }
    return TRUE;
}

static void scan_solidworks_windows(void)
{
    struct scan_context context = {0};
    unsigned int i;

    EnumWindows(find_solidworks_process, (LPARAM)&context.pid);
    if (!context.pid) return;
    EnumWindows(collect_process_windows, (LPARAM)&context);

    for (i = 0; i < context.document_windows.count; ++i)
        EnumChildWindows(context.document_windows.items[i], elevate_child_floating_tool, 0);

    for (i = 0; i < context.windows.count; ++i)
    {
        HWND window = context.windows.items[i];
        WCHAR class_name[256], title[512];

        if (window_list_contains(&context.document_windows, window)) continue;
        get_window_strings(window, class_name, title);
        if (is_ignored_popup(class_name)) continue;
        if (!wcscmp(class_name, L"#32770")) elevate_dialog(window);
        else if (is_floating_tool(class_name, title)) elevate_floating_window(window);
    }
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR command_line, int show_command)
{
    (void)instance;
    (void)previous;
    (void)command_line;
    (void)show_command;
    for (;;)
    {
        scan_solidworks_windows();
        Sleep(200);
    }

    return 0;
}
