/* Real Wine ABI probe. The native helper may be interactive or a captured stub. */
#define COBJMACROS
#include <windows.h>
#include <commdlg.h>
#include <shobjidl.h>
#include <stdio.h>
#include <wchar.h>

static UINT dialog_show_events;
static BOOL cancel_fallback;
static void CALLBACK dialog_event(HWINEVENTHOOK hook, DWORD event, HWND hwnd, LONG object,
                                  LONG child, DWORD thread, DWORD time)
{
    WCHAR title[128];
    (void)hook; (void)event; (void)thread; (void)time;
    if (object != OBJID_WINDOW || child != CHILDID_SELF || GetAncestor(hwnd, GA_ROOT) != hwnd) return;
    GetWindowTextW(hwnd, title, ARRAYSIZE(title));
    if (!wcscmp(title, L"MacSW 原生面板验证"))
    {
        ++dialog_show_events;
        if (cancel_fallback) PostMessageW(hwnd, WM_COMMAND, IDCANCEL, (LPARAM)GetDlgItem(hwnd, IDCANCEL));
    }
}

static BOOL CALLBACK clip_radio(HWND hwnd, LPARAM unused)
{
    WCHAR name[32];
    int id = GetDlgCtrlID(hwnd);
    (void)unused;
    GetClassNameW(hwnd, name, ARRAYSIZE(name));
    if ((id == 11 || id == 12) && !wcscmp(name, L"Button"))
        SetWindowPos(hwnd, NULL, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
    return TRUE;
}

static BOOL CALLBACK clip_dialog(HWND hwnd, LPARAM unused)
{
    WCHAR title[128];
    (void)unused;
    EnumChildWindows(hwnd, clip_radio, 0);
    GetWindowTextW(hwnd, title, ARRAYSIZE(title));
    if (!wcscmp(title, L"MacSW 原生面板验证") && !GetDlgItem(hwnd, 60001))
    {
        HWND first = CreateWindowW(L"Button", L"原始模式", WS_CHILD | WS_VISIBLE | WS_GROUP | BS_AUTORADIOBUTTON,
            0, 0, 0, 0, hwnd, (HMENU)60001, GetModuleHandleW(NULL), NULL);
        CreateWindowW(L"Button", L"副本模式", WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON,
            0, 0, 0, 0, hwnd, (HMENU)60002, GetModuleHandleW(NULL), NULL);
        CreateWindowW(L"Button", L"独立选项", WS_CHILD | WS_VISIBLE | WS_GROUP | BS_AUTORADIOBUTTON,
            0, 0, 0, 0, hwnd, (HMENU)60003, GetModuleHandleW(NULL), NULL);
        SendMessageW(first, BM_SETCHECK, BST_CHECKED, 0);
        SendMessageW(GetDlgItem(hwnd, 60003), BM_SETCHECK, BST_CHECKED, 0);
    }
    return TRUE;
}

static void CALLBACK clip_timer(HWND hwnd, UINT message, UINT_PTR timer, DWORD time)
{
    (void)hwnd; (void)message; (void)time;
    EnumThreadWindows(GetCurrentThreadId(), clip_dialog, 0);
    KillTimer(NULL, timer);
}

static void print_path(const WCHAR *path)
{
    char text[65536];
    WideCharToMultiByte(CP_UTF8, 0, path, -1, text, sizeof(text), NULL, NULL);
    printf("path=%s\n", text);
}

int wmain(int argc, WCHAR **argv)
{
    static const WCHAR filter[] = L"SOLIDWORKS (*.SLDPRT)\0*.SLDPRT\0STEP (*.step;*.stp)\0*.step;*.stp\0All files\0*.*\0\0";
    WCHAR file[32768] = L"原生面板验证.SLDPRT";
    BOOL save = argc > 1 && wcsstr(argv[1], L"save");
    BOOL com = argc > 1 && wcsstr(argv[1], L"com");
    BOOL multi = argc > 1 && wcsstr(argv[1], L"multi");
    BOOL ok;
    setvbuf(stdout, NULL, _IONBF, 0);
    cancel_fallback = argc > 1 && wcsstr(argv[1], L"fallback");
    if (CoInitializeEx(NULL, COINIT_APARTMENTTHREADED) != S_OK) return 2;
    if (com)
    {
        static const COMDLG_FILTERSPEC types[] = {{L"SOLIDWORKS", L"*.SLDPRT"}, {L"STEP", L"*.step;*.stp"}, {L"All files", L"*.*"}};
        IFileDialog *dialog;
        IShellItem *item;
        WCHAR *path;
        UINT index = 0;
        HWINEVENTHOOK visibility = SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, NULL, dialog_event,
            GetCurrentProcessId(), GetCurrentThreadId(), WINEVENT_OUTOFCONTEXT);
        HRESULT hr = CoCreateInstance(save ? &CLSID_FileSaveDialog : &CLSID_FileOpenDialog, NULL,
            CLSCTX_INPROC_SERVER, &IID_IFileDialog, (void **)&dialog);
        if (FAILED(hr)) { printf("create=%08lx\n", hr); return 3; }
        IFileDialog_SetFileTypes(dialog, 3, types);
        IFileDialog_SetFileTypeIndex(dialog, 1);
        IFileDialog_SetFileName(dialog, file);
        /* SOLIDWORKS updates the filter using SetFileName("*.STEP") before
         * displaying Save As. The native panel must retain the document name. */
        if (argc > 1 && wcsstr(argv[1], L"wildcard")) IFileDialog_SetFileName(dialog, L"*.STEP");
        IFileDialog_SetTitle(dialog, L"MacSW 原生面板验证");
        if (argc > 1 && wcsstr(argv[1], L"controls"))
        {
            IFileDialogCustomize *custom;
            if (FAILED(IFileDialog_QueryInterface(dialog, &IID_IFileDialogCustomize, (void **)&custom))) return 4;
            IFileDialogCustomize_AddRadioButtonList(custom, 101);
            IFileDialogCustomize_AddControlItem(custom, 101, 11, L"保存原件");
            IFileDialogCustomize_AddControlItem(custom, 101, 12, L"保存副本");
            IFileDialogCustomize_SetSelectedControlItem(custom, 101, 11);
            IFileDialogCustomize_AddCheckButton(custom, 102, L"包含参考", FALSE);
            IFileDialogCustomize_Release(custom);
            /* SW's Wine controls can be clipped to zero size. Selection must
             * still reach its original handler without simulated mouse input. */
            SetTimer(NULL, 0, 1, clip_timer);
        }
        if (argc > 1 && wcsstr(argv[1], L"dropdown"))
        {
            IFileDialogCustomize *custom;
            IFileDialog_QueryInterface(dialog, &IID_IFileDialogCustomize, (void **)&custom);
            IFileDialog_SetOptions(dialog, FOS_STRICTFILETYPES | FOS_NOCHANGEDIR | FOS_ALLOWMULTISELECT | FOS_FILEMUSTEXIST);
            IFileDialogCustomize_EnableOpenDropDown(custom, 3457575);
            IFileDialogCustomize_AddControlItem(custom, 3457575, 99, L"不可用");
            IFileDialogCustomize_SetControlItemState(custom, 3457575, 99, CDCS_VISIBLE);
            IFileDialogCustomize_AddControlItem(custom, 3457575, 98, L"隐藏");
            IFileDialogCustomize_SetControlItemState(custom, 3457575, 98, CDCS_ENABLED);
            IFileDialogCustomize_AddControlItem(custom, 3457575, 454453, L"打开");
            IFileDialogCustomize_AddControlItem(custom, 3457575, 454454, L"以只读打开");
            IFileDialogCustomize_Release(custom);
        }
        puts("phase=show");
        hr = IFileDialog_Show(dialog, NULL);
        printf("hr=%08lx\n", hr);
        if (SUCCEEDED(hr) && SUCCEEDED(IFileDialog_GetResult(dialog, &item)))
        {
            if (SUCCEEDED(IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &path))) { print_path(path); CoTaskMemFree(path); }
            IShellItem_Release(item);
        }
        IFileDialog_GetFileTypeIndex(dialog, &index);
        printf("index=%u\n", index);
        if (argc > 1 && wcsstr(argv[1], L"controls"))
        {
            IFileDialogCustomize *custom;
            DWORD selected = 0;
            BOOL checked = FALSE;
            IFileDialog_QueryInterface(dialog, &IID_IFileDialogCustomize, (void **)&custom);
            IFileDialogCustomize_GetSelectedControlItem(custom, 101, &selected);
            IFileDialogCustomize_GetCheckButtonState(custom, 102, &checked);
            printf("selected=%lu checked=%d\n", selected, checked);
            IFileDialogCustomize_Release(custom);
        }
        if (argc > 1 && wcsstr(argv[1], L"dropdown"))
        {
            IFileDialogCustomize *custom;
            DWORD selected = 0;
            IFileDialog_QueryInterface(dialog, &IID_IFileDialogCustomize, (void **)&custom);
            HRESULT selection_hr = IFileDialogCustomize_GetSelectedControlItem(custom, 3457575, &selected);
            printf("open_selection=%lu selection_hr=%08lx\n", selected, selection_hr);
            IFileDialogCustomize_Release(custom);
        }
        IFileDialog_Release(dialog);
        if (visibility) UnhookWinEvent(visibility);
        printf("dialog_show_events=%u\n", dialog_show_events);
    }
    else
    {
        OPENFILENAMEW ofn = {0};
        WCHAR *p;
        ofn.lStructSize = sizeof(ofn);
        ofn.lpstrFile = file; ofn.nMaxFile = argc > 1 && wcsstr(argv[1], L"small") ? 4 : ARRAYSIZE(file);
        ofn.lpstrFilter = filter; ofn.nFilterIndex = 1; ofn.lpstrDefExt = L"SLDPRT";
        ofn.lpstrTitle = L"MacSW 原生面板验证";
        ofn.Flags = OFN_EXPLORER | OFN_HIDEREADONLY | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR |
            (save ? OFN_OVERWRITEPROMPT : OFN_FILEMUSTEXIST) | (multi ? OFN_ALLOWMULTISELECT : 0);
        if (argc > 2) ofn.lpstrInitialDir = argv[2];
        ok = save ? GetSaveFileNameW(&ofn) : GetOpenFileNameW(&ofn);
        printf("ok=%d error=%lu index=%lu offset=%u extension=%u\n", ok, CommDlgExtendedError(), ofn.nFilterIndex, ofn.nFileOffset, ofn.nFileExtension);
        if (ok) for (p = file; *p; p += wcslen(p) + 1) { print_path(p); if (!multi) break; }
    }
    CoUninitialize();
    return 0;
}
