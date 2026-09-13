#!/usr/bin/env python3
"""Prepare the pinned interpreter's Apple platform and static OSMesa binding."""
import argparse
from pathlib import Path
from prepare_embedded import replace


def prepare(root):
    updates = {}
    path = root / 'lib/sdl2/CMakeLists.txt'
    # This SDL revision predates Metal on Simulator. Its old architecture test
    # silently removes the only enabled UIKit renderer on current SDKs.
    text = replace(path.read_text(),
        '#if TARGET_OS_SIMULATOR || (!TARGET_CPU_X86_64 && !TARGET_CPU_ARM64)',
        '#if !defined(__arm64__) && !defined(__aarch64__) && !defined(__x86_64__)')
    text = replace(text,
        '      set(CMAKE_REQUIRED_FLAGS "${CMAKE_REQUIRED_FLAGS} -x objective-c")\n      check_c_source_compiles("',
        '      include(CheckSourceCompiles)\n      check_source_compiles(OBJC "')
    updates[path] = text
    path = root / 'lib/sdl2/src/video/SDL_video.c'
    text = replace(path.read_text(),
        '#if (SDL_VIDEO_OPENGL && __MACOSX__) || __IPHONEOS__ || __ANDROID__ || __NACL__',
        '#if (SDL_VIDEO_OPENGL && __MACOSX__) || (__IPHONEOS__ && SDL_VIDEO_OPENGL_ES2) || __ANDROID__ || __NACL__')
    updates[path] = text
    path = root / 'platform/sdl/knativescreenSDL.cpp'
    text = replace(path.read_text(), '            klog_fmt("SDL_CreateWindow failed: %s", SDL_GetError());',
        '''#ifdef MADEIRA_IOS
            kpanic_fmt("SDL_CreateWindow failed: %s", SDL_GetError());
#else
            klog_fmt("SDL_CreateWindow failed: %s", SDL_GetError());
#endif''')
    text = replace(text, '''                renderer = SDL_CreateRenderer(window, -1, flags);
            }
        }
    }
}''', '''                renderer = SDL_CreateRenderer(window, -1, flags);
            }
#ifdef MADEIRA_IOS
            if (!renderer) kpanic_fmt("SDL renderer failed: %s", SDL_GetError());
            // SDL letterboxes the guest desktop in the actual UIKit viewport
            // and converts mouse/touch events back to these logical pixels.
            input->scaleX = input->scaleY = 100;
            input->scaleXOffset = input->scaleYOffset = 0;
            if (SDL_RenderSetLogicalSize(renderer, input->width, input->height) != 0)
                kpanic_fmt("SDL logical display failed: %s", SDL_GetError());
            madeiraWine32MouseRenderer(renderer, window);
#endif
        }
    }
}''')
    text = replace(text,
        '    input->setScreenSize(cx, cy);\n\n    // If full screen, then we just have to change the scale',
        '''    input->setScreenSize(cx, cy);
#ifdef MADEIRA_IOS
    if (renderer && SDL_RenderSetLogicalSize(renderer, cx, cy) != 0)
        kpanic_fmt("SDL logical display resize failed: %s", SDL_GetError());
    return; // UIKit owns the host view's size; guest resolution is independent.
#endif

    // If full screen, then we just have to change the scale''')
    text = replace(text, '#include <SDL.h>', '''#include <SDL.h>
#ifdef MADEIRA_IOS
#include "ios_mouse.h"
#endif''')
    text = replace(text, '        SDL_RenderPresent(renderer);', '''#ifdef MADEIRA_IOS
        madeiraWine32MouseDraw();
#endif
        SDL_RenderPresent(renderer);''')
    text = replace(text, '        SDL_DestroyRenderer(renderer);', '''#ifdef MADEIRA_IOS
        madeiraWine32MouseClearRenderer();
#endif
        SDL_DestroyRenderer(renderer);''')
    text = replace(text, '            SDL_WarpMouseInWindow(window, x, y);', '''#ifdef MADEIRA_IOS
            madeiraWine32MouseWarp(x, y);
#else
            SDL_WarpMouseInWindow(window, x, y);
#endif''')
    updates[path] = text
    path = root / 'platform/sdl/knativeinputSDL.cpp'
    text = replace(path.read_text(), '#include <SDL.h>', '''#include <SDL.h>
#ifdef MADEIRA_IOS
#include "ios_mouse.h"
#endif''')
    text = replace(text, '    SDL_GetMouseState(x, y);', '''#ifdef MADEIRA_IOS
    madeiraWine32MousePosition(x, y);
#else
    SDL_GetMouseState(x, y);
#endif''')
    text = replace(text, '        SDL_GetMouseState(&x, &y);', '''#ifdef MADEIRA_IOS
        madeiraWine32MousePosition(&x, &y);
#else
        SDL_GetMouseState(&x, &y);
#endif''')
    updates[path] = text
    path = root / 'platform/linux/platform.cpp'
    text = path.read_text()
    text = replace(text, '#ifndef __MACH__\nint getPixelFormats',
                   '#if !defined(__MACH__) || defined(MADEIRA_IOS)\nint getPixelFormats')
    # The interpreter never writes executable host code. Apple's device SDK
    # does not provide the GCC clear-cache helper used by the Linux platform.
    # Keep those calls only for upstream's other targets, and reject accidental
    # native-JIT configuration of this iOS adapter.
    text = replace(text, '#include "boxedwine.h"', '''#include "boxedwine.h"
#if defined(MADEIRA_IOS) && defined(BOXEDWINE_JIT)
#error Madeira iOS backend requires the interpreter
#endif''')
    for call in ('__builtin___clear_cache((char*)address, (char*)address+len);',
                 '__builtin___clear_cache((char*)address, (char*)address + len);',
                 '__builtin___clear_cache((char*)address, ((char*)address) + len);'):
        text = replace(text, '    ' + call,
            '#ifndef MADEIRA_IOS\n    ' + call + '\n#endif')
    updates[path] = text
    path = root / 'platform/linux/platformOpenGL.cpp'
    text = path.read_text()
    text = replace(text, '#if defined(__APPLE__)\n#include "../mac/macOpenGL.h"',
                   '#if defined(__APPLE__) && !defined(MADEIRA_IOS)\n#include "../mac/macOpenGL.h"')
    text = replace(text, '#if defined(__APPLE__)\n        macOpenGLGetPixelFormatInfo',
                   '#if defined(__APPLE__) && !defined(MADEIRA_IOS)\n        macOpenGLGetPixelFormatInfo')
    updates[path] = text
    path = root / 'source/opengl/osmesa/osmesa.cpp'
    text = path.read_text()
    text = replace(text, '#include <SDL_opengl.h>', '#include GLH')
    text = replace(text, 'bool OsMesaGL::isAvailable() {\n', '''bool OsMesaGL::isAvailable() {
#ifdef MADEIRA_IOS
    return true; // OSMesa is part of the final static application link.
#else
''')
    text = replace(text, '    return found;\n}', '    return found;\n#endif\n}')
    text = replace(text, 'static void initMesaOpenGL() {    \n', '''static void initMesaOpenGL() {
#ifdef MADEIRA_IOS
    pOSMesaGetProcAddress = OSMesaGetProcAddress;
    pOSMesaMakeCurrent = OSMesaMakeCurrent;
    pOSMesaCreateContextAttribs = OSMesaCreateContextAttribs;
    pOSMesaDestroyContext = OSMesaDestroyContext;
    pOSMesaPixelStore = OSMesaPixelStore;
#else
''')
    text = replace(text, '''    pOSMesaPixelStore = (fn_OSMesaPixelStore)SDL_LoadFunction(pDLL, "OSMesaPixelStore");

    pglFinish''', '''    pOSMesaPixelStore = (fn_OSMesaPixelStore)SDL_LoadFunction(pDLL, "OSMesaPixelStore");
#endif
    if (!pOSMesaGetProcAddress || !pOSMesaMakeCurrent || !pOSMesaCreateContextAttribs ||
        !pOSMesaDestroyContext || !pOSMesaPixelStore) {
        kpanic("OSMesa entry points are unavailable");
    }

    pglFinish''')
    updates[path] = text
    path = root / 'source/x11/xserver.cpp'
    text = replace(path.read_text(), '#else\n\tU32 count = KSystem::getPixelFormatCount();',
                   '#else\n    {\n\tU32 count = KSystem::getPixelFormatCount();')
    text = replace(text, '\t}\n#endif\n}\n\nCLXFBConfigPtr XServer::getFbConfig',
                   '\t}\n    }\n#endif\n}\n\nCLXFBConfigPtr XServer::getFbConfig')
    text = replace(text, '#include "boxedwine.h"', '''#include "boxedwine.h"
#ifdef MADEIRA_IOS
#include "ios_mouse.h"
#endif''')
    text = replace(text, 'void XServer::draw(bool drawNow) {', '''void XServer::draw(bool drawNow) {
#ifdef MADEIRA_IOS
    if (madeiraWine32MouseChanged()) isDisplayDirty = true;
#endif''')
    updates[path] = text
    path = root / 'source/x11/xrandr.cpp'
    text = replace(path.read_text(), '    U32 desktopCx = 0;', '''#ifdef MADEIRA_IOS
    // Guest modes are independent of the phone's physical display. Omitting
    // the configured mode makes XrrConfigCurrentConfiguration fall back to
    // index zero and Wine reports the wrong desktop size.
    const U32 candidates[][2] = {
        {KNativeSystem::getScreen()->screenWidth(), KNativeSystem::getScreen()->screenHeight()},
        {1920, 1080}, {1600, 900}, {1280, 720}, {1024, 768}, {800, 600}, {640, 480}
    };
    std::vector<std::pair<U32, U32>> modes;
    for (const auto& candidate : candidates) {
        bool duplicate = false;
        for (const auto& mode : modes) {
            if (mode.first == candidate[0] && mode.second == candidate[1]) duplicate = true;
        }
        if (!duplicate) modes.emplace_back(candidate[0], candidate[1]);
    }
    U32 address = thread->process->alloc(thread, sizeof(XRRScreenSize) * modes.size());
    data->xrrData->sizesAddress = address;
    data->xrrData->sizesCount = modes.size();
    for (const auto& mode : modes) {
        memory->writed(address, mode.first);
        memory->writed(address + 4, mode.second);
        memory->writed(address + 8, 0);
        memory->writed(address + 12, 0);
        address += sizeof(XRRScreenSize);
    }
    if (countAddress) memory->writed(countAddress, data->xrrData->sizesCount);
    return data->xrrData->sizesAddress;
#endif
    U32 desktopCx = 0;''')
    updates[path] = text
    # Altered SDL UIKit backend: Madeira owns the window and parent controller.
    # SDL retains its own controller/Metal view, attached as a normal child.
    path = root / 'lib/sdl2/src/video/uikit/SDL_uikitview.m'
    text = path.read_text()
    text = replace(text, '        self.autoresizesSubviews = YES;', '''        self.autoresizesSubviews = YES;
        // Madeira: report physical mouse/trackpad hover through SDL input.
        [self addGestureRecognizer:[[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(madeiraHover:)]];''')
    text = replace(text, '- (void)setSDLWindow:(SDL_Window *)window', '''- (void)madeiraHover:(UIHoverGestureRecognizer*)gesture
{
    if (gesture.state == UIGestureRecognizerStateBegan || gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint p = [gesture locationInView:self];
        if (self.bounds.size.width > 0 && self.bounds.size.height > 0) {
            extern void madeira_wine32_pointer(float, float, int, int);
            madeira_wine32_pointer(p.x / self.bounds.size.width, p.y / self.bounds.size.height, 0, -1);
        }
    }
}

- (void)setSDLWindow:(SDL_Window *)window''')
    old = '''        data.uiwindow.rootViewController = nil;
        data.uiwindow.rootViewController = data.viewcontroller;'''
    new = '''        // Madeira: attach SDL's view inside the host controller.
        extern void madeiraWine32SDLViewChanged(UIViewController*);
        madeiraWine32SDLViewChanged(data.viewcontroller);'''
    if text.count(old) == 2:
        text = text.replace(old, new)
    elif text.count(new) != 2:
        raise RuntimeError('Unexpected SDL UIKit view attachment implementation')
    updates[path] = text
    path = root / 'lib/sdl2/src/video/uikit/SDL_uikitwindow.m'
    text = path.read_text()
    # Upstream's old UIKit raise hook unconditionally restores an ES context.
    # A Metal-only device has no GL_MakeCurrent callback, so the first visible
    # Wine window otherwise calls through a null function pointer.
    text = replace(text,
        '    _this->GL_MakeCurrent(_this, _this->current_glwin, _this->current_glctx);',
        '''#if SDL_VIDEO_OPENGL_ES || SDL_VIDEO_OPENGL_ES2
    _this->GL_MakeCurrent(_this, _this->current_glwin, _this->current_glctx);
#endif''')
    text = replace(text, '        [data.uiwindow makeKeyAndVisible];', '''        // Madeira owns the visible UIWindow.
        extern void madeiraWine32SDLSetVisible(BOOL);
        madeiraWine32SDLSetVisible(YES);''')
    text = replace(text, '        data.uiwindow.hidden = YES;\n    }\n}', '''        extern void madeiraWine32SDLSetVisible(BOOL);
        madeiraWine32SDLSetVisible(NO);
    }
}''')
    text = text.replace('''            extern void madeiraWine32SDLWillDestroy(UIViewController*);
            madeiraWine32SDLWillDestroy(data.viewcontroller);
            [data.viewcontroller stopAnimation];''', '            [data.viewcontroller stopAnimation];')
    text = replace(text, '''            data.uiwindow.rootViewController = nil;
            data.uiwindow.hidden = YES;''', '''            extern void madeiraWine32SDLWillDestroy(UIViewController*);
            madeiraWine32SDLWillDestroy(data.viewcontroller);
            data.uiwindow.rootViewController = nil;
            data.uiwindow.hidden = YES;''')
    updates[path] = text
    path = root / 'lib/sdl2/src/video/uikit/SDL_uikitmetalview.m'
    text = replace(path.read_text(), 'data.uiwindow.rootViewController.view', 'data.viewcontroller.view')
    updates[path] = text
    path = root / 'lib/sdl2/src/video/uikit/SDL_uikitvideo.m'
    text = replace(path.read_text(), '''    CGRect frame = screen.bounds;

    /* Use the UIWindow bounds''', '''    // Madeira embeds SDL in a child controller. Keyboard and fullscreen
    // updates must keep using that host's bounds, including SwiftUI toolbars.
    if (data.viewcontroller.parentViewController) {
        return data.viewcontroller.parentViewController.view.bounds;
    }
    CGRect frame = screen.bounds;

    /* Use the UIWindow bounds''')
    updates[path] = text
    for path, text in updates.items():
        path.write_text(text)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    prepare(parser.parse_args().source)
