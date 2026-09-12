#!/usr/bin/env python3
"""Compile SDL's Metal source for the exact iOS SDK, only in CI."""
import argparse
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--sdk', choices=('iphoneos', 'iphonesimulator'), required=True)
    args = parser.parse_args()
    if os.environ.get('GITHUB_ACTIONS') != 'true':
        parser.error('Compile Metal shaders only in GitHub Actions')
    root = args.source / 'lib/sdl2/src/render/metal'
    # Follow SDL's build-metal-shaders.sh, including its Simulator SDK flag.
    subprocess.run(['xcrun', '-sdk', args.sdk, 'metal', '-c', '-std=ios-metal1.1',
        f'-m{args.sdk}-version-min=17.0', '-Wall', '-O3', '-o', 'madeira-sdl.air',
        'SDL_shaders_metal.metal'], cwd=root, check=True)
    subprocess.run(['xcrun', '-sdk', args.sdk, 'metal-ar', 'rc', 'madeira-sdl.metalar', 'madeira-sdl.air'], cwd=root, check=True)
    subprocess.run(['xcrun', '-sdk', args.sdk, 'metallib', '-o', 'madeira-sdl.metallib', 'madeira-sdl.metalar'], cwd=root, check=True)
    data = (root / 'madeira-sdl.metallib').read_bytes()
    if not data.startswith(b'MTLB'):
        raise RuntimeError('Metal compiler did not produce a library')
    # The pinned renderer includes this header on both iPhoneOS and Simulator.
    # Each CI job has a separate source directory and embeds its own SDK output.
    (root / 'SDL_shaders_metal_ios.h').write_text(
        '// Madeira: regenerated from SDL source for ' + args.sdk + '.\n'
        'const unsigned char sdl_metallib[] = {\n' +
        '\n'.join(','.join(f'0x{byte:02x}' for byte in data[i:i+16]) + ',' for i in range(0, len(data), 16)) +
        '\n};\nconst unsigned int sdl_metallib_len = ' + str(len(data)) + ';\n')


if __name__ == '__main__':
    main()
