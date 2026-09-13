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
#endif
        }
    }
}''')
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
    updates[path] = text
    # Altered SDL UIKit backend: Madeira owns the window and parent controller.
    # SDL retains its own controller/Metal view, attached as a normal child.
    path = root / 'lib/sdl2/src/video/uikit/SDL_uikitview.m'
    text = path.read_text()
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
    for path, text in updates.items():
        path.write_text(text)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    prepare(parser.parse_args().source)
