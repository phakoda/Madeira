#define UNICODE
#define _UNICODE
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static int received_tab;
static int received_capture;
static int received_left, received_right;
static HCURSOR test_cursor;

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_APP + 1) return 0x1234;
    if (message == WM_KEYDOWN && w == VK_TAB) received_tab = 1;
    if (message == WM_KEYDOWN && w == VK_RETURN) received_capture = 1;
    if (message == WM_SETCURSOR && test_cursor) { SetCursor(test_cursor); return TRUE; }
    if (abs((short)LOWORD(l) - 32) <= 4 && abs((short)HIWORD(l) - 32) <= 4) {
        if (message == WM_LBUTTONDOWN) received_left = 1;
        if (message == WM_RBUTTONDOWN) received_right = 1;
    }
    return DefWindowProcW(window, message, w, l);
}

int main(void) {
    int display_failures = 0;
    WNDCLASSW klass = {0};
    klass.lpfnWndProc = window_proc;
    klass.hInstance = GetModuleHandleW(NULL);
    klass.lpszClassName = L"Madeira32GraphicsProbe";
    if (!RegisterClassW(&klass)) return 30;
    HWND window = CreateWindowW(klass.lpszClassName, L"Madeira 32-bit graphics",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE, 0, 0, 128, 128, NULL, NULL, klass.hInstance, NULL);
    if (!window || SendMessageW(window, WM_APP + 1, 0, 0) != 0x1234) return 31;
    SetForegroundWindow(window);
    SetFocus(window);
    WCHAR display_test[4];
    if (GetEnvironmentVariableW(L"MADEIRA_VERIFY_PRESENTATION", display_test, 4)) {
        int width = GetSystemMetrics(SM_CXSCREEN), height = GetSystemMetrics(SM_CYSCREEN);
        if (width != 1280 || height != 720) {
            fprintf(stderr, "Unexpected desktop resolution: %dx%d, expected 1280x720\n", width, height);
            display_failures |= 1;
        }
        POINT target = {32, 32}, actual = {-1, -1};
        ClientToScreen(window, &target);
        if (!SetCursorPos(target.x, target.y) || !GetCursorPos(&actual) ||
            abs(actual.x - target.x) > 4 || abs(actual.y - target.y) > 4) {
            fprintf(stderr, "Mouse position mismatch: requested %ld,%ld, got %ld,%ld\n",
                    target.x, target.y, actual.x, actual.y);
            display_failures |= 2;
        }
    }
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) return 32;
    D3DPRESENT_PARAMETERS params = {0};
    params.Windowed = TRUE;
    params.SwapEffect = D3DSWAPEFFECT_DISCARD;
    params.hDeviceWindow = window;
    params.BackBufferWidth = 64;
    params.BackBufferHeight = 64;
    params.BackBufferFormat = D3DFMT_UNKNOWN;
    IDirect3DDevice9 *device = NULL;
    HRESULT hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL,
        window, D3DCREATE_SOFTWARE_VERTEXPROCESSING, &params, &device);
    if (FAILED(hr)) return 33;
    IDirect3DSurface9 *target = NULL, *readback = NULL;
    hr = IDirect3DDevice9_CreateRenderTarget(device, 64, 64, D3DFMT_A8R8G8B8,
        D3DMULTISAMPLE_NONE, 0, FALSE, &target, NULL);
    if (FAILED(hr)) return 34;
    hr = IDirect3DDevice9_CreateOffscreenPlainSurface(device, 64, 64,
        D3DFMT_A8R8G8B8, D3DPOOL_SYSTEMMEM, &readback, NULL);
    if (FAILED(hr)) return 35;
    if (FAILED(IDirect3DDevice9_SetRenderTarget(device, 0, target))) return 36;
    if (FAILED(IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, 0xff12ab34, 1.0f, 0))) return 37;
    if (FAILED(IDirect3DDevice9_GetRenderTargetData(device, target, readback))) return 38;
    D3DLOCKED_RECT locked;
    if (FAILED(IDirect3DSurface9_LockRect(readback, &locked, NULL, D3DLOCK_READONLY))) return 39;
    for (int y = 0; y < 64; ++y) {
        const uint32_t *row = (const uint32_t *)((const unsigned char *)locked.pBits + y * locked.Pitch);
        for (int x = 0; x < 64; ++x) if (row[x] != 0xff12ab34) return 40;
    }
    IDirect3DSurface9_UnlockRect(readback);
    // Readback alone can pass while the host window is black. Present the same
    // color through Wine's window, then let the iOS runner inspect its screen.
    IDirect3DSurface9 *backbuffer = NULL;
    if (FAILED(IDirect3DDevice9_GetBackBuffer(device, 0, 0, D3DBACKBUFFER_TYPE_MONO, &backbuffer))) return 43;
    if (FAILED(IDirect3DDevice9_SetRenderTarget(device, 0, backbuffer))) return 44;
    IDirect3DSurface9_Release(backbuffer);
    if (FAILED(IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, 0xff12ab34, 1.0f, 0))) return 45;
    if (FAILED(IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL))) return 46;
    WCHAR verify[4];
    if (GetEnvironmentVariableW(L"MADEIRA_VERIFY_PRESENTATION", verify, 4)) {
        DWORD color[16 * 16];
        BYTE mask[16 * 2] = {0};
        for (int i = 0; i < 16 * 16; ++i) color[i] = 0xffff00ff;
        ICONINFO icon = {0};
        icon.hbmColor = CreateBitmap(16, 16, 1, 32, color);
        icon.hbmMask = CreateBitmap(16, 16, 1, 1, mask);
        test_cursor = CreateIconIndirect(&icon);
        DeleteObject(icon.hbmColor);
        DeleteObject(icon.hbmMask);
        if (!test_cursor) return 51;
        SetCursor(test_cursor);
        POINT point = {32, 32};
        ClientToScreen(window, &point);
        FILE* coordinates = fopen("D:\\mouse target.txt", "w");
        if (!coordinates) return 52;
        fprintf(coordinates, "%ld %ld %d %d", point.x, point.y,
                GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
        fclose(coordinates);
        HANDLE ready = CreateFileW(L"D:\\graphics ready.txt", GENERIC_WRITE, 0, NULL,
                                  CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (ready == INVALID_HANDLE_VALUE) return 47;
        CloseHandle(ready);
        int captured = 0, pointer_ready = 0;
        for (int attempt = 0; attempt < 600; ++attempt) {
            MSG message;
            while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
            if (received_left && received_right && !pointer_ready) {
                HANDLE input = CreateFileW(L"D:\\pointer ready.txt", GENERIC_WRITE, 0, NULL,
                                          CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
                if (input == INVALID_HANDLE_VALUE) return 54;
                CloseHandle(input);
                pointer_ready = 1;
            }
            if (received_tab && received_capture && received_left && received_right) {
                captured = 1;
                break;
            }
            IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, 0xff12ab34, 1.0f, 0);
            IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL);
            Sleep(100);
        }
        if (!captured) {
            fprintf(stderr, "Presentation/input verification timed out; Tab: %d, capture: %d, left: %d, right: %d\n",
                    received_tab, received_capture, received_left, received_right);
            return 48;
        }
        if (display_failures) return 53;
    }
    IDirect3DSurface9_Release(readback);
    IDirect3DSurface9_Release(target);
    IDirect3DDevice9_Release(device);
    IDirect3D9_Release(d3d);
    DestroyWindow(window);
    HANDLE file = CreateFileW(L"D:\\graphics result.txt", GENERIC_WRITE, 0, NULL,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 41;
    const char result[] = "native-x86-d3d9-render-target-pixels-ok\n";
    DWORD written;
    if (!WriteFile(file, result, sizeof(result) - 1, &written, NULL) || written != sizeof(result) - 1) return 42;
    CloseHandle(file);
    return 0;
}
