#define UNICODE
#define _UNICODE
#include <windows.h>
#include <stdint.h>
#include <stdio.h>

static volatile LONG counter;
static DWORD WINAPI worker(void *ignored) {
    (void)ignored;
    for (int i = 0; i < 1000; ++i) InterlockedIncrement(&counter);
    return 0;
}

int main(void) {
    puts("probe: entered x86 Windows main"); fflush(stdout);
    if (sizeof(void *) != 4) return 10;
    SYSTEM_INFO info;
    GetSystemInfo(&info);
    if (info.dwPageSize != 4096) return 11;
    unsigned char *memory = VirtualAlloc(NULL, 8192, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!memory || (uintptr_t)memory > UINT32_MAX - 8192) return 12;
    memory[4095] = 0x5a;
    memory[4096] = 0xa5;
    if (memory[4095] != 0x5a || memory[4096] != 0xa5) return 13;
    DWORD old;
    if (!VirtualProtect(memory, 4096, PAGE_READONLY, &old)) return 14;
    if (!VirtualFree(memory, 0, MEM_RELEASE)) return 15;
    puts("probe: guest virtual memory passed"); fflush(stdout);
    HANDLE threads[2];
    for (int i = 0; i < 2; ++i) {
        threads[i] = CreateThread(NULL, 0, worker, NULL, 0, NULL);
        if (!threads[i]) return 16;
    }
    if (WaitForMultipleObjects(2, threads, TRUE, 30000) != WAIT_OBJECT_0) return 17;
    for (int i = 0; i < 2; ++i) CloseHandle(threads[i]);
    if (counter != 2000) return 18;
    puts("probe: guest threads passed"); fflush(stdout);

    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Madeira\\RuntimeProbe32", 0,
                      NULL, 0, KEY_SET_VALUE, NULL, &key, NULL) != ERROR_SUCCESS) return 19;
    DWORD value = 32;
    if (RegSetValueExW(key, L"Architecture", 0, REG_DWORD, (const BYTE *)&value, sizeof(value)) != ERROR_SUCCESS) return 20;
    RegCloseKey(key);
    puts("probe: registry passed"); fflush(stdout);

    HANDLE file = CreateFileW(L"D:\\32 bit result.txt", GENERIC_WRITE, 0, NULL,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        printf("probe: CreateFileW failed, Win32 error %lu, drive type %u\n",
               GetLastError(), GetDriveTypeW(L"D:\\")); fflush(stdout);
        return 21;
    }
    const char result[] = "native-x86-wine-memory-threads-registry-file-ok\n";
    DWORD written;
    if (!WriteFile(file, result, sizeof(result) - 1, &written, NULL) || written != sizeof(result) - 1) {
        printf("probe: WriteFile failed, Win32 error %lu\n", GetLastError()); fflush(stdout);
        CloseHandle(file);
        return 22;
    }
    CloseHandle(file);
    puts("probe: persistent file written"); fflush(stdout);
    return 0;
}
