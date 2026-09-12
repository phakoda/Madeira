#!/usr/bin/env python3
"""Package the compiled interpreter and its pinned guest files for Xcode."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('build', 'source', 'mesa', 'wine', 'graphics', 'app'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get('CI') != 'true' or os.environ.get('GITHUB_ACTIONS') != 'true':
        raise RuntimeError('Native packaging is restricted to GitHub Actions')
    manifest = json.loads(Path(__file__).with_name('runtime.json').read_text())
    if digest(args.wine) != manifest['wine']['sha256']:
        raise RuntimeError('Wine filesystem does not match the pinned runtime')
    archives = [args.build / 'libmadeira-wine32-engine.a', args.build / 'libbw_softfloat.a',
                args.build / 'sdl2/libSDL2.a', args.mesa / 'libOSMesa.a']
    for archive in archives:
        if not archive.is_file():
            raise RuntimeError(f'Missing runtime archive: {archive}')
    args.app.mkdir(parents=True, exist_ok=True)
    library = args.app / 'libmadeira_wine32.a'
    temporary = library.with_suffix('.partial.a')
    subprocess.run(['xcrun', 'libtool', '-static', '-o', temporary, *archives], check=True)
    temporary.replace(library)
    mesa_build = json.loads((args.mesa / 'build.json').read_text())
    sdk = mesa_build['sdk']
    flags = ['-target', mesa_build['target'], '-isysroot', subprocess.check_output(
        ['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip()]
    smoke_object = args.build / 'packaged-runtime-smoke.o'
    subprocess.run(['xcrun', '--sdk', sdk, 'clang', *flags, '-c',
        Path(__file__).with_name('ios_link_smoke.c'), '-o', smoke_object], check=True)
    frameworks = ['Foundation', 'UIKit', 'QuartzCore', 'Metal', 'CoreVideo', 'GameController',
                  'AudioToolbox', 'AVFoundation', 'CoreAudio', 'CoreBluetooth', 'CoreGraphics', 'CoreMotion']
    subprocess.run(['xcrun', '--sdk', sdk, 'clang++', *flags, smoke_object, library,
        '-lz', '-liconv', *[part for name in frameworks for part in ('-framework', name)],
        '-o', args.build / 'packaged-runtime-smoke'], check=True)
    resources = args.app / 'Wine32'
    resources.mkdir(exist_ok=True)
    shutil.copy2(args.wine, resources / 'wine11.zip')
    shutil.copy2(args.graphics, resources / 'madeira-graphics.zip')
    shutil.copy2(args.source / 'license.txt', resources / 'BOXEDWINE-LICENSE.txt')
    shutil.copy2(args.source / 'lib/sdl2/COPYING.txt', resources / 'SDL-LICENSE.txt')
    shutil.copy2(args.source / 'lib/softfloat/COPYING.txt', resources / 'SOFTFLOAT-LICENSE.txt')
    shutil.copy2(args.source / 'lib/simde/COPYING', resources / 'SIMDE-LICENSE.txt')
    shutil.copy2(args.mesa / 'MESA-LICENSE.rst', resources / 'MESA-LICENSE.rst')
    (resources / 'runtime.json').write_text(json.dumps({'upstream': manifest,
        'guest_graphics_sha256': digest(args.graphics), 'archive_sha256': digest(library),
        'memory': 'sparse software translation', 'cpu': 'x86 interpreter',
        'graphics': 'OSMesa softpipe'}, indent=2) + '\n')
    print(f'Packaged {library} and {resources}')


if __name__ == '__main__':
    main()
