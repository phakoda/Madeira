#!/usr/bin/env python3
"""Check the real archive cannot bind to FEX's incompatible SoftFloat ABI."""
import argparse
from pathlib import Path
import re
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform == 'darwin':
        output = subprocess.check_output(['xcrun', 'nm', '-gjU', args.archive], text=True)
        symbols = {line.removeprefix('_') for line in output.splitlines()}
    else:
        output = subprocess.check_output(['nm', '-g', '--defined-only', '--format=posix', args.archive], text=True)
        symbols = {line.split()[0] for line in output.splitlines() if line.split()}
    # BoxedWine builds the x87 subset, so f32_add is declared upstream but is
    # deliberately absent from this archive. Check operations it actually uses.
    required = {'madeira_bw_extF80_to_f64', 'madeira_bw_softfloat_roundingMode', 'madeira_bw_extF80_add'}
    if not required <= symbols:
        raise RuntimeError(f'Missing isolated SoftFloat exports: {sorted(required - symbols)}')
    families = re.compile(r'^(?:softfloat_|f(?:16|32|64|128)M?_|extF80M?_|(?:i|ui)(?:32|64)_to_)')
    exposed = sorted(symbol for symbol in symbols if families.match(symbol))
    if exposed:
        raise RuntimeError(f'SoftFloat exports could collide with FEX: {exposed}')
    print('Verified separate BoxedWine SoftFloat exports in the compiled archive')


if __name__ == '__main__':
    main()
