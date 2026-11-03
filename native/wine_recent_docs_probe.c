#define COBJMACROS
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <stdio.h>
#include <wchar.h>

static int check_link(const WCHAR *file, const WCHAR *target)
{
    IShellLinkW *link = NULL;
    IPersistFile *persist = NULL;
    WCHAR path[MAX_PATH];
    HRESULT hr = CoCreateInstance(&CLSID_ShellLink,NULL,CLSCTX_INPROC_SERVER,&IID_IShellLinkW,(void **)&link);
    if (FAILED(hr)) return 0;
    hr = IShellLinkW_QueryInterface(link,&IID_IPersistFile,(void **)&persist);
    if (SUCCEEDED(hr)) hr = IPersistFile_Load(persist,file,STGM_READ);
    if (SUCCEEDED(hr)) hr = IShellLinkW_GetPath(link,path,MAX_PATH,NULL,SLGP_RAWPATH);
    int ok = SUCCEEDED(hr) && !wcsicmp(path,target);
    if (persist) IPersistFile_Release(persist);
    IShellLinkW_Release(link);
    return ok;
}
int wmain(int argc, WCHAR **argv)
{
    WCHAR recent[MAX_PATH], dir[MAX_PATH], target[MAX_PATH], file[MAX_PATH];
    WIN32_FIND_DATAW data;
    HANDLE find, h;
    int matched = 0;
    if (argc != 3 || FAILED(CoInitialize(NULL))) return 2;
    setvbuf(stdout,NULL,_IONBF,0);
    if (FAILED(SHGetFolderPathW(NULL,CSIDL_RECENT|CSIDL_FLAG_CREATE,NULL,SHGFP_TYPE_CURRENT,recent))) return 3;
    if (!wcscmp(argv[1],L"recent")) wcscpy(dir,recent);
    else { _snwprintf(dir,MAX_PATH,L"%ls-other",recent); CreateDirectoryW(dir,NULL); }
    _snwprintf(target,MAX_PATH,L"%ls\\\x6a21\x578b %ls.SLDPRT",dir,argv[2]);
    h=CreateFileW(target,GENERIC_WRITE,0,NULL,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    if(h==INVALID_HANDLE_VALUE)return 4;
    DWORD written; WriteFile(h,"probe",5,&written,NULL); CloseHandle(h);
    if (!wcscmp(argv[1],L"recent")) {
        SHAddToRecentDocs(SHARD_PATHW,target);
        _snwprintf(file,MAX_PATH,L"%ls\\*.lnk",recent);
        find=FindFirstFileW(file,&data);
        if(find!=INVALID_HANDLE_VALUE) {
            do { _snwprintf(file,MAX_PATH,L"%ls\\%ls",recent,data.cFileName); matched |= check_link(file,target); }
            while(FindNextFileW(find,&data)); FindClose(find);
        }
        HKEY key; DWORD values=0;
        if(RegOpenKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\RecentDocs",0,KEY_QUERY_VALUE,&key)!=ERROR_SUCCESS)return 5;
        RegQueryInfoKeyW(key,NULL,NULL,NULL,NULL,NULL,NULL,&values,NULL,NULL,NULL,NULL); RegCloseKey(key);
        if (!values) return 6;
        printf("recent_link_target=%s mru_values=%lu\n",matched?"PASS":"FAIL",values);
    } else {
        IShellLinkW *link=NULL; IPersistFile *persist=NULL;
        HRESULT hr=CoCreateInstance(&CLSID_ShellLink,NULL,CLSCTX_INPROC_SERVER,&IID_IShellLinkW,(void **)&link);
        if(FAILED(hr))return 7;
        hr=IShellLinkW_SetPath(link,target);
        if(SUCCEEDED(hr)) hr=IShellLinkW_QueryInterface(link,&IID_IPersistFile,(void **)&persist);
        _snwprintf(file,MAX_PATH,L"%ls\\control-%ls.lnk",dir,argv[2]);
        if(SUCCEEDED(hr))hr=IPersistFile_Save(persist,file,TRUE);
        if(persist)IPersistFile_Release(persist);
        IShellLinkW_Release(link);
        matched=SUCCEEDED(hr)&&check_link(file,target);
        printf("sibling_link_target=%s\n",matched?"PASS":"FAIL");
    }
    CoUninitialize();
    return matched?0:8;
}
