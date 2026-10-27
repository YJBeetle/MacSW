/* Optional UI diagnostic. Use a disposable prefix with the patched modules. */
#ifndef UNICODE
#define UNICODE
#endif
#define _UNICODE
#define COBJMACROS
#include <windows.h>
#include <shlobj.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

int wmain(int argc, WCHAR **argv)
{
    ITEMIDLIST *item = NULL, *parent = NULL;
    const ITEMIDLIST *child;
    HRESULT hr;
    int status = 1;

    if (argc != 3)
    {
        fprintf(stderr, "usage: wine_file_manager_probe.exe api|child|absolute|folder|select PATH\n");
        return 2;
    }
    if (!wcscmp(argv[1], L"folder") || !wcscmp(argv[1], L"select"))
    {
        WCHAR executable[MAX_PATH], *command;
        STARTUPINFOW startup = {0};
        PROCESS_INFORMATION process;
        DWORD code;
        size_t length = wcslen(argv[2]) + MAX_PATH + 32;

        GetSystemDirectoryW(executable, MAX_PATH);
        wcscat(executable, L"\\explorer.exe");
        command = malloc(length * sizeof(WCHAR));
        if (!command) return 1;
        swprintf(command, length, L"\"%ls\" %ls\"%ls\"", executable,
                 !wcscmp(argv[1], L"select") ? L"/select," : L"", argv[2]);
        startup.cb = sizeof(startup);
        if (CreateProcessW(executable, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process))
        {
            if (WaitForSingleObject(process.hProcess, 15000) == WAIT_OBJECT_0 &&
                GetExitCodeProcess(process.hProcess, &code) && !code)
                status = 0;
            else
                TerminateProcess(process.hProcess, 1);
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
        }
        free(command);
    }
    else
    {
        hr = CoInitialize(NULL);
        if (FAILED(hr)) return 1;
        hr = SHParseDisplayName(argv[2], NULL, &item, 0, NULL);
        if (SUCCEEDED(hr))
        {
            if (!wcscmp(argv[1], L"api"))
                hr = SHOpenFolderAndSelectItems(item, 0, NULL, 0);
            else if (!wcscmp(argv[1], L"child") || !wcscmp(argv[1], L"absolute"))
            {
                parent = ILClone(item);
                if (!parent) hr = E_OUTOFMEMORY;
                else
                {
                    ILRemoveLastID(parent);
                    child = !wcscmp(argv[1], L"child") ? ILFindLastID(item) : item;
                    hr = SHOpenFolderAndSelectItems(parent, 1, &child, 0);
                }
            }
            else hr = E_INVALIDARG;
            status = FAILED(hr);
        }
        printf("HRESULT=%08lx\n", (unsigned long)hr);
        ILFree(parent);
        CoTaskMemFree(item);
        CoUninitialize();
    }
    printf("FINDER_BRIDGE_%s\n", status ? "FAIL" : "PASS");
    return status;
}
