#!/usr/bin/env python3
"""Prepare the pinned interpreter's Apple platform and static OSMesa binding."""
import argparse
from pathlib import Path
from prepare_embedded import replace


def prepare(root):
    updates = {}
    path = root / 'platform/linux/platform.cpp'
    text = path.read_text()
    text = replace(text, '#ifndef __MACH__\nint getPixelFormats',
                   '#if !defined(__MACH__) || defined(MADEIRA_IOS)\nint getPixelFormats')
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
    for path, text in updates.items():
        path.write_text(text)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    prepare(parser.parse_args().source)
