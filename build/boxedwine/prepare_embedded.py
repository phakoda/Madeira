#!/usr/bin/env python3
"""Adapt pinned upstream lifecycle for a host-owned event loop, without building."""
import argparse
from pathlib import Path


def replace(text, old, new):
    if (new and text.count(new) == 1) or (not new and old not in text):
        return text
    if text.count(old) != 1:
        raise RuntimeError(f'Pinned source no longer matches: {old[:100]!r}')
    return text.replace(old, new, 1)


def prepare(root):
    updates = {}
    path = root / 'source/sdl/startupArgs.h'
    text = path.read_text()
    text = replace(text, 'class StartUpArgs {', 'class FsZip;\n\nclass StartUpArgs {')
    text = replace(text, '    bool apply();', '''    bool apply();
    // Madeira retains the filesystem until finish(), across host event ticks.
    bool begin();
    void finish();''')
    text = replace(text, '    bool workingDirSet = false;', '''    bool sessionInitialized = false;
#ifdef BOXEDWINE_ZLIB
    std::vector<std::shared_ptr<FsZip>> openZips;
#endif
    bool workingDirSet = false;''')
    updates[path] = text
    path = root / 'source/sdl/startupArgs.cpp'
    text = path.read_text()
    text = replace(text, 'bool StartUpArgs::apply() {\n    KSystem::init(this->disableLinearMemory);', '''bool StartUpArgs::apply() {
    const bool started = begin();
    const bool result = started && doMainLoop();
    finish();
    return result;
}

bool StartUpArgs::begin() {
    sessionInitialized = true;
    KSystem::init(this->disableLinearMemory);''')
    text = replace(text, '    std::vector<std::shared_ptr<FsZip>> openZips;\n', '')
    text = replace(text, '''        if (result) {
            if (!doMainLoop()) {
                return false; // doMainLoop should have handled any cleanup, like SDL_Quit if necessary
            }
        }
    }
#ifdef GENERATE_SOURCE''', '''        return result;
    }
    return false;
}

void StartUpArgs::finish() {
    if (!sessionInitialized) return;
    sessionInitialized = false;
#ifdef GENERATE_SOURCE''')
    text = replace(text, '''    openZips.clear();
#endif    
    return true;
}

bool StartUpArgs::loadDefaultResource''', '''    openZips.clear();
#endif
}

bool StartUpArgs::loadDefaultResource''')
    updates[path] = text
    path = root / 'platform/sdl/knativesystem.cpp'
    text = path.read_text()
    text = replace(text, '#ifndef __TEST\nint boxedmain', '#if !defined(__TEST) && !defined(MADEIRA_EMBEDDED)\nint boxedmain')
    text = replace(text, '''void KNativeSystem::exit(const char* msg, U32 code) {
    SDL_ShowSimpleMessageBox''', '''void KNativeSystem::exit(const char* msg, U32 code) {
#ifdef MADEIRA_EMBEDDED
    extern void madeiraWine32Fatal(const char*);
    madeiraWine32Fatal(msg);
#else
    SDL_ShowSimpleMessageBox''')
    text = replace(text, '    _exit(code);\n}', '    _exit(code);\n#endif\n}')
    updates[path] = text
    path = root / 'source/util/log.cpp'
    text = path.read_text()
    text = replace(text, '    if (KSystem::videoOption == VIDEO_NORMAL) {', '''#ifdef MADEIRA_EMBEDDED
    extern void madeiraWine32Fatal(const char*);
    madeiraWine32Fatal(msg.c_str());
#else
    if (KSystem::videoOption == VIDEO_NORMAL) {''')
    text = replace(text, '    exit(1);\n}', '    exit(1);\n#endif\n}')
    updates[path] = text
    # Validate all replacements before writing. Each replacement recognizes its
    # completed form so an interrupted preparation can be safely retried.
    for path, text in updates.items():
        path.write_text(text)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    prepare(parser.parse_args().source)
