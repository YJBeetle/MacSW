"""Run the bridge's actual C code with a captured native-launch boundary."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
PATCH = PROJECT / 'patches/wine-crossover/0016-shell-native-file-manager.patch'


def bridge_header():
    section = PATCH.read_text().split('+++ b/include/wine/native_file_manager.h\n', 1)[1]
    section = section.split('diff --git ', 1)[0]
    return '\n'.join(line[1:] for line in section.splitlines() if line.startswith('+')) + '\n'


class NativeFileManagerTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('cc'), 'C compiler required')
    def test_native_launch_arguments_mapping_and_fallback(self):
        with tempfile.TemporaryDirectory(prefix='macsw-native-finder-') as directory:
            root = Path(directory)
            (root / 'winternl.h').write_text('/* Stubbed process boundary for the host-side unit test. */\n')
            (root / 'bridge.h').write_text(bridge_header())
            (root / 'probe.c').write_text(r'''
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
typedef wchar_t WCHAR;
typedef unsigned long DWORD;
typedef int BOOL;
#define TRUE 1
#define FALSE 0
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define INVALID_FILE_ATTRIBUTES ((DWORD)-1)
#define FILE_ATTRIBUTE_DIRECTORY 16
static int enabled, spawn_status, launches, allocations, releases, select_mode;
static DWORD attributes;
static const char *mapped;
static DWORD GetEnvironmentVariableW(const WCHAR *name, WCHAR *out, DWORD size) {
    assert(!wcscmp(name, L"MACSW_NATIVE_FILE_MANAGER") && size == 2);
    if (enabled == 1) { out[0] = L'1'; out[1] = 0; return 1; }
    return enabled == 2 ? 12 : 0;
}
static DWORD GetFileAttributesW(const WCHAR *path) {
    assert(!wcscmp(path, L"Q:\\中文 folder\\model.SLDPRT"));
    return attributes;
}
static char *wine_get_unix_file_name(const WCHAR *path) {
    (void)path;
    if (!mapped) return NULL;
    ++allocations;
    return strdup(mapped);
}
static void *GetProcessHeap(void) { return NULL; }
static void HeapFree(void *heap, DWORD flags, void *ptr) {
    (void)heap; (void)flags; ++releases; free(ptr);
}
static int __wine_unix_spawnvp(char **args, BOOL wait) {
    assert(wait == FALSE && !strcmp(args[0], "/usr/bin/open"));
    if (select_mode) {
        assert(!strcmp(args[1], "-R") && !strcmp(args[2], "--"));
        assert(!strcmp(args[3], mapped) && args[4] == NULL);
    } else {
        assert(!strcmp(args[1], "-a") && !strcmp(args[2], "Finder"));
        assert(!strcmp(args[3], "--") && !strcmp(args[4], mapped) && args[5] == NULL);
    }
    ++launches;
    return spawn_status;
}
#include "bridge.h"
int main(void) {
    const WCHAR *path = L"Q:\\中文 folder\\model.SLDPRT";
    mapped = "/Volumes/Disk/中文 folder/$('literal'); a,b.SLDPRT";
    attributes = FILE_ATTRIBUTE_DIRECTORY;
    assert(!wine_open_native_file_manager(path, FALSE) && launches == 0);
    enabled = 2;
    assert(!wine_open_native_file_manager(path, FALSE) && launches == 0);
    enabled = 1;
    assert(!wine_open_native_file_manager(NULL, FALSE));
    assert(!wine_open_native_file_manager(L"", FALSE));
    assert(wine_open_native_file_manager(path, FALSE) && launches == 1);
    attributes = 0;
    assert(!wine_open_native_file_manager(path, FALSE) && launches == 1);
    select_mode = 1;
    assert(wine_open_native_file_manager(path, TRUE) && launches == 2);
    spawn_status = 1;
    assert(!wine_open_native_file_manager(path, TRUE) && launches == 3);
    attributes = INVALID_FILE_ATTRIBUTES;
    assert(!wine_open_native_file_manager(path, TRUE) && launches == 3);
    attributes = 0;
    mapped = NULL;
    assert(!wine_open_native_file_manager(path, TRUE) && launches == 3);
    mapped = "relative/untrusted/path";
    assert(!wine_open_native_file_manager(path, TRUE) && launches == 3);
    assert(allocations == releases);
    return 0;
}
''')
            subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(root),
                            str(root / 'probe.c'), '-o', str(root / 'probe')], check=True)
            subprocess.run([str(root / 'probe')], check=True, timeout=10)


if __name__ == '__main__':
    unittest.main()
