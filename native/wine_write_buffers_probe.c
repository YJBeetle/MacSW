/* Progress regression for concurrent process-wide barriers under Rosetta.
 * The watchdog exits the entire process on deadlock, including blocked threads.
 * This probe never starts SOLIDWORKS or opens user documents. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

#define MAX_THREADS 16
#define ITERATIONS 500
#define DEADLINE_MS 30000

typedef LONG (WINAPI *flush_fn)(void);
static flush_fn flush_buffers;
static HANDLE start_event;
static LONG completed;

static DWORD WINAPI worker(void *arg)
{
    unsigned int i;
    (void)arg;
    if (WaitForSingleObject(start_event, INFINITE) != WAIT_OBJECT_0) return 1;
    for (i = 0; i < ITERATIONS; ++i)
    {
        if (flush_buffers() < 0) return 2;
        InterlockedIncrement(&completed);
    }
    return 0;
}

int main(int argc, char **argv)
{
    HANDLE threads[MAX_THREADS];
    DWORD result, exit_code;
    unsigned int i, count;
    LARGE_INTEGER frequency, begin, end;
    char *tail;

    if (argc != 2) return 64;
    count = strtoul(argv[1], &tail, 10);
    if (*tail || count < 1 || count > MAX_THREADS) return 64;
    flush_buffers = (flush_fn)(void *)GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtFlushProcessWriteBuffers");
    if (!flush_buffers) return 3;
    start_event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!start_event) return 4;
    for (i = 0; i < count; ++i)
    {
        threads[i] = CreateThread(NULL, 0, worker, NULL, 0, NULL);
        if (!threads[i]) ExitProcess(5);
    }
    QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&begin);
    if (!SetEvent(start_event)) ExitProcess(6);
    result = WaitForMultipleObjects(count, threads, TRUE, DEADLINE_MS);
    QueryPerformanceCounter(&end);
    printf("threads=%u wait=%lu completed=%ld expected=%u seconds=%.3f\n", count,
           (unsigned long)result, completed, count * ITERATIONS,
           (double)(end.QuadPart - begin.QuadPart) / frequency.QuadPart);
    fflush(stdout);
    if (result != WAIT_OBJECT_0) ExitProcess(2);
    for (i = 0; i < count; ++i)
    {
        if (!GetExitCodeThread(threads[i], &exit_code) || exit_code) ExitProcess(7);
        CloseHandle(threads[i]);
    }
    CloseHandle(start_event);
    if (completed != (LONG)(count * ITERATIONS)) return 8;
    puts("WINE_WRITE_BUFFERS_PASS");
    return 0;
}
