#define UNICODE
#define _UNICODE
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdint.h>
#include <stdio.h>

static int received_tab;
static int received_capture;

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_APP + 1) return 0x1234;
    if (message == WM_KEYDOWN && w == VK_TAB) received_tab = 1;
    if (message == WM_KEYDOWN && w == VK_RETURN) received_capture = 1;
    return DefWindowProcW(window, message, w, l);
}

int main(void) {
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
        HANDLE ready = CreateFileW(L"D:\\graphics ready.txt", GENERIC_WRITE, 0, NULL,
                                  CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (ready == INVALID_HANDLE_VALUE) return 47;
        CloseHandle(ready);
        int captured = 0;
        for (int attempt = 0; attempt < 600; ++attempt) {
            MSG message;
            while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
            if (received_tab && received_capture) {
                captured = 1;
                break;
            }
            IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, 0xff12ab34, 1.0f, 0);
            IDirect3DDevice9_Present(device, NULL, NULL, NULL, NULL);
            Sleep(100);
        }
        if (!captured) {
            fprintf(stderr, "Presentation/input verification timed out; received Tab: %d, capture: %d\n",
                    received_tab, received_capture);
            return 48;
        }
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
